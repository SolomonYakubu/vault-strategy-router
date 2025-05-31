const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("VaultStrategyRouter - Professional", function () {
    async function deployProfessionalFixture() {
        const [deployer, admin, keeper, strategyManager, user1, user2] = await ethers.getSigners();

        const MockStBTC = await ethers.getContractFactory("MockStBTC");
        const asset = await MockStBTC.deploy("Pro Asset", "pASSET", admin.address);
        await asset.waitForDeployment();

        const VaultStrategyRouter = await ethers.getContractFactory("VaultStrategyRouter");
        const router = await VaultStrategyRouter.deploy(await asset.getAddress(), admin.address, keeper.address);
        await router.waitForDeployment();

        const STRATEGY_MANAGER_ROLE = await router.STRATEGY_MANAGER_ROLE();
        await router.connect(admin).grantRole(STRATEGY_MANAGER_ROLE, strategyManager.address);

        const BabylonStrategy = await ethers.getContractFactory("BabylonStrategy");
        const babylonStrategy = await BabylonStrategy.deploy(await asset.getAddress(), strategyManager.address);
        await babylonStrategy.waitForDeployment();

        const BounceBitStrategy = await ethers.getContractFactory("BounceBitStrategy");
        const bounceBitStrategy = await BounceBitStrategy.deploy(await asset.getAddress(), strategyManager.address);
        await bounceBitStrategy.waitForDeployment();

        await babylonStrategy.connect(strategyManager).setRouter(await router.getAddress());
        await bounceBitStrategy.connect(strategyManager).setRouter(await router.getAddress());

        await router.connect(strategyManager).addStrategy(await babylonStrategy.getAddress());
        await router.connect(strategyManager).addStrategy(await bounceBitStrategy.getAddress());

        // Remove MINTER_ROLE logic, use the pre-minted tokens from MockStBTC
        await asset.connect(admin).transfer(user1.address, ethers.parseEther("1000"));
        await asset.connect(admin).transfer(user2.address, ethers.parseEther("1000"));

        await babylonStrategy.connect(strategyManager).setPerformanceMetric(450); // 4.5%
        await bounceBitStrategy.connect(strategyManager).setPerformanceMetric(600); // 6.0%
        await router.connect(keeper).runKeeperTasks();

        return { router, asset, babylonStrategy, bounceBitStrategy, admin, keeper, strategyManager, user1, user2, deployer };
    }

    describe("Access Control", function () {
        it("Should only allow ADMIN_ROLE to pause/unpause", async function () {
            const { router, user1, admin } = await deployProfessionalFixture();
            await expect(router.connect(user1).pause()).to.be.revertedWithCustomError(router, "AccessControlUnauthorizedAccount");
            await expect(router.connect(admin).pause()).to.not.be.reverted;

            await expect(router.connect(user1).unpause()).to.be.revertedWithCustomError(router, "AccessControlUnauthorizedAccount");
            await expect(router.connect(admin).unpause()).to.not.be.reverted;
        });

        it("Should only allow STRATEGY_MANAGER_ROLE to add strategies", async function(){
            const { router, user1, strategyManager, asset } = await deployProfessionalFixture();
            const BabylonStrategy = await ethers.getContractFactory("BabylonStrategy");
            const tempStrategy = await BabylonStrategy.deploy(await asset.getAddress(), strategyManager.address);
            await tempStrategy.connect(strategyManager).setRouter(await router.getAddress());

            await expect(router.connect(user1).addStrategy(await tempStrategy.getAddress()))
                .to.be.revertedWithCustomError(router, "AccessControlUnauthorizedAccount");
            await expect(router.connect(strategyManager).addStrategy(await tempStrategy.getAddress()))
                .to.emit(router, "StrategyAdded");
        });
    });

    describe("Deposit/Withdraw", function() {
        it("Should revert deposit of 0 amount", async function() {
            const { router, user1 } = await deployProfessionalFixture();
            await expect(router.connect(user1).deposit(0))
                .to.be.revertedWithCustomError(router, "AmountMustBePositive");
        });

        it("Should allow deposit and emit event", async function() {
            const { router, asset, user1 } = await deployProfessionalFixture();
            await asset.connect(user1).approve(router.getAddress(), ethers.parseEther("100"));
            await expect(router.connect(user1).deposit(ethers.parseEther("100")))
                .to.emit(router, "Deposited");
        });

        it("Should revert withdraw of 0 shares", async function() {
            const { router, user1 } = await deployProfessionalFixture();
            await expect(router.connect(user1).withdraw(0))
                .to.be.revertedWithCustomError(router, "AmountMustBePositive");
        });

        it("Should revert withdraw of more shares than owned", async function() {
            const { router, user1 } = await deployProfessionalFixture();
            await expect(router.connect(user1).withdraw(1000))
                .to.be.revertedWithCustomError(router, "InsufficientShares");
        });

        it("Should allow deposit and withdraw, emitting events", async function() {
            const { router, asset, user1 } = await deployProfessionalFixture();
            await asset.connect(user1).approve(router.getAddress(), ethers.parseEther("10"));
            await router.connect(user1).deposit(ethers.parseEther("10"));
            await expect(router.connect(user1).withdraw(ethers.parseEther("10")))
                .to.emit(router, "Withdrawn");
        });
    });

    describe("Rebalancing", function() {
        it("Should not rebalance if no strategy outperforms by threshold", async function() {
            const { router, keeper, strategyManager, babylonStrategy, bounceBitStrategy, asset, user1 } = await deployProfessionalFixture();
            // Set both APYs to be close
            await babylonStrategy.connect(strategyManager).setPerformanceMetric(600);
            await bounceBitStrategy.connect(strategyManager).setPerformanceMetric(601);
            // Deposit to Babylon (lowest APY)
            await asset.connect(user1).approve(router.getAddress(), ethers.parseEther("10"));
            await router.connect(user1).deposit(ethers.parseEther("10"));
            // Advance time by 8 days
            await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            await expect(router.connect(keeper).runKeeperTasks())
                .to.not.emit(router, "Rebalanced");
        });
        it("Should rebalance if a strategy outperforms by threshold", async function() {
            const { router, keeper, strategyManager, babylonStrategy, bounceBitStrategy, asset, user1 } = await deployProfessionalFixture();
            // Deactivate BounceBit for initial deposit
            const bounceBitAddr = await bounceBitStrategy.getAddress();
            await router.connect(strategyManager).removeStrategy(bounceBitAddr);
            // Set Babylon APY low
            await babylonStrategy.connect(strategyManager).setPerformanceMetric(100);
            await asset.connect(user1).approve(router.getAddress(), ethers.parseEther("10"));
            await router.connect(user1).deposit(ethers.parseEther("10"));
            // Do NOT run runKeeperTasks here!
            // Reactivate BounceBit and update APYs
            await router.connect(strategyManager).activateStrategy(bounceBitAddr);
            await babylonStrategy.connect(strategyManager).setPerformanceMetric(100);
            await bounceBitStrategy.connect(strategyManager).setPerformanceMetric(600);
            // Advance time by 8 days
            await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            // Now run keeper to update APY cache and trigger rebalance
            await expect(router.connect(keeper).runKeeperTasks())
                .to.emit(router, "Rebalanced");
        });
    });

    describe("Emergency & Pause", function() {
        it("Should allow ADMIN_ROLE to emergency withdraw and pause", async function() {
            const { router, admin } = await deployProfessionalFixture();
            await expect(router.connect(admin).emergencyWithdrawFromAllStrategies())
                .to.emit(router, "EmergencyWithdrawAll");
            expect(await router.paused()).to.be.true;
        });

        it("Should not allow deposit when paused", async function() {
            const { router, asset, user1, admin } = await deployProfessionalFixture();
            await router.connect(admin).pause();
            await asset.connect(user1).approve(router.getAddress(), ethers.parseEther("1"));
            await expect(router.connect(user1).deposit(ethers.parseEther("1")))
                .to.be.reverted; // Accept any revert, as custom error is used
        });
    });

    describe("Advanced & Edge Cases", function() {
        it("Should emit correct event args on deposit and withdraw", async function() {
            const { router, asset, user1 } = await deployProfessionalFixture();
            await asset.connect(user1).approve(router.getAddress(), ethers.parseEther("5"));
            // Perform deposit and capture event
            const tx = await router.connect(user1).deposit(ethers.parseEther("5"));
            const receipt = await tx.wait();
            const iface = router.interface;
            let strategyAddr;
            for (const log of receipt.logs) {
                try {
                    const parsed = iface.parseLog(log);
                    if (parsed.name === "Deposited") {
                        expect(parsed.args[0]).to.equal(user1.address);
                        expect(parsed.args[1]).to.equal(ethers.parseEther("5"));
                        expect(parsed.args[3]).to.equal(ethers.parseEther("5"));
                        strategyAddr = parsed.args[2];
                        break;
                    }
                } catch (e) { /* not a router event */ }
            }
            expect(strategyAddr).to.be.properAddress;
            // Withdraw and check event
            await expect(router.connect(user1).withdraw(ethers.parseEther("5")))
                .to.emit(router, "Withdrawn")
                .withArgs(user1.address, ethers.parseEther("5"), ethers.parseEther("5"), strategyAddr);
        });
        it("Should handle multi-user deposits and withdrawals correctly", async function() {
            const { router, asset, user1, user2 } = await deployProfessionalFixture();
            await asset.connect(user1).approve(router.getAddress(), ethers.parseEther("10"));
            await asset.connect(user2).approve(router.getAddress(), ethers.parseEther("20"));
            await router.connect(user1).deposit(ethers.parseEther("10"));
            await router.connect(user2).deposit(ethers.parseEther("20"));
            await expect(router.connect(user1).withdraw(ethers.parseEther("10")))
                .to.emit(router, "Withdrawn");
            await expect(router.connect(user2).withdraw(ethers.parseEther("20")))
                .to.emit(router, "Withdrawn");
        });
        it("Should allow withdraw from a deactivated strategy", async function() {
            const { router, asset, user1, strategyManager, babylonStrategy } = await deployProfessionalFixture();
            await asset.connect(user1).approve(router.getAddress(), ethers.parseEther("5"));
            await router.connect(user1).deposit(ethers.parseEther("5"));
            await router.connect(strategyManager).removeStrategy(await babylonStrategy.getAddress());
            await expect(router.connect(user1).withdraw(ethers.parseEther("5")))
                .to.emit(router, "Withdrawn");
        });
        it("Should not allow revoked role to add strategies", async function() {
            const { router, admin, strategyManager, asset } = await deployProfessionalFixture();
            const BabylonStrategy = await ethers.getContractFactory("BabylonStrategy");
            const tempStrategy = await BabylonStrategy.deploy(await asset.getAddress(), strategyManager.address);
            await tempStrategy.connect(strategyManager).setRouter(await router.getAddress());
            await router.connect(admin).revokeRole(await router.STRATEGY_MANAGER_ROLE(), strategyManager.address);
            await expect(router.connect(strategyManager).addStrategy(await tempStrategy.getAddress()))
                .to.be.revertedWithCustomError(router, "AccessControlUnauthorizedAccount");
        });
        it("Should revert if adding the same strategy twice", async function() {
            const { router, strategyManager, babylonStrategy } = await deployProfessionalFixture();
            await expect(router.connect(strategyManager).addStrategy(await babylonStrategy.getAddress()))
                .to.be.revertedWithCustomError(router, "StrategyAlreadyExists");
        });
        it("Should emergency withdraw from both strategies", async function() {
            const { router, asset, user1, user2, admin } = await deployProfessionalFixture();
            await asset.connect(user1).approve(router.getAddress(), ethers.parseEther("10"));
            await asset.connect(user2).approve(router.getAddress(), ethers.parseEther("20"));
            await router.connect(user1).deposit(ethers.parseEther("10"));
            await router.connect(user2).deposit(ethers.parseEther("20"));
            await expect(router.connect(admin).emergencyWithdrawFromAllStrategies())
                .to.emit(router, "EmergencyWithdrawAll");
        });
    });
});
