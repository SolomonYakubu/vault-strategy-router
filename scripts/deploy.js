const { ethers } = require("hardhat");

async function main() {
  const [deployer, admin, keeper, strategyManager, user1] =
    await ethers.getSigners();

  console.log("--- Account Addresses ---");
  console.log("Deployer:", deployer.address);
  console.log("Admin:", admin.address);
  console.log("Keeper:", keeper.address);
  console.log("Strategy Manager:", strategyManager.address);
  console.log("User1:", user1.address);

  // 1. Deploy Mock ERC20 (stBTC)
  const MockStBTC = await ethers.getContractFactory("MockStBTC", deployer);
  const assetToken = await MockStBTC.deploy("stBTC", "stBTC", admin.address);
  const assetTokenAddress = await assetToken.getAddress();
  console.log(`MockStBTC (stBTC) deployed to: ${assetTokenAddress}`);

  // 2. Deploy VaultStrategyRouter
  const VaultStrategyRouter = await ethers.getContractFactory(
    "VaultStrategyRouter",
    deployer
  );
  const router = await VaultStrategyRouter.deploy(
    assetTokenAddress,
    admin.address,
    keeper.address
  );
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log(`VaultStrategyRouter deployed to: ${routerAddress}`);

  // Grant STRATEGY_MANAGER_ROLE from the admin
  const STRATEGY_MANAGER_ROLE = await router.STRATEGY_MANAGER_ROLE();
  await router
    .connect(admin)
    .grantRole(STRATEGY_MANAGER_ROLE, strategyManager.address);
  console.log(`Granted STRATEGY_MANAGER_ROLE to ${strategyManager.address}`);

  // 3. Deploy Mock Strategies
  const BabylonStrategy = await ethers.getContractFactory(
    "BabylonStrategy",
    deployer
  );
  const babylonStrategy = await BabylonStrategy.deploy(
    assetTokenAddress,
    strategyManager.address
  );
  await babylonStrategy.waitForDeployment();
  const babylonStrategyAddress = await babylonStrategy.getAddress();
  console.log(`BabylonStrategy deployed to: ${babylonStrategyAddress}`);

  const BounceBitStrategy = await ethers.getContractFactory(
    "BounceBitStrategy",
    deployer
  );
  const bounceBitStrategy = await BounceBitStrategy.deploy(
    assetTokenAddress,
    strategyManager.address
  );
  await bounceBitStrategy.waitForDeployment();
  const bounceBitStrategyAddress = await bounceBitStrategy.getAddress();
  console.log(`BounceBitStrategy deployed to: ${bounceBitStrategyAddress}`);

  // 4. Configure Strategies and Add to Router
  console.log("Configuring strategies to recognize the router...");
  await babylonStrategy.connect(strategyManager).setRouter(routerAddress);
  await bounceBitStrategy.connect(strategyManager).setRouter(routerAddress);
  console.log("Strategies configured with router address.");

  console.log("Adding strategies to the router...");
  await router.connect(strategyManager).addStrategy(babylonStrategyAddress);
  await router.connect(strategyManager).addStrategy(bounceBitStrategyAddress);
  console.log("Strategies added to router.");

  // 5. Initial APY setting
  await babylonStrategy.connect(strategyManager).setPerformanceMetric(475); // 4.75%
  await bounceBitStrategy.connect(strategyManager).setPerformanceMetric(625); // 6.25%
  console.log("Initial mock APYs set on strategies.");

  // Keeper run to update router's APY cache
  console.log("Performing initial keeper run to sync APYs to router...");
  await router.connect(keeper).runKeeperTasks();
  console.log("Initial keeper run completed.");

  // Mint assets to users (MockStBTC is pre-minted to admin, so use transfer)
  console.log("\n--- Example: Transfer some stBTC to user1 ---");
  await assetToken
    .connect(admin)
    .transfer(user1.address, ethers.parseEther("1000"));
  console.log(`Transferred 1000 stBTC to User1 (${user1.address})`);

  console.log("\n🎉 Deployment and Professional Configuration Complete! 🎉");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
