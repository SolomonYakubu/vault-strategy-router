// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IStrategy.sol";

/**
 * @title VaultStrategyRouter
 * @author LayerBTC Team
 * @notice Routes BTC assets to the best-performing BTCFi strategies and manages dynamic rebalancing.
 */
contract VaultStrategyRouter is AccessControlEnumerable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant STRATEGY_MANAGER_ROLE = keccak256("STRATEGY_MANAGER_ROLE");

    // --- Custom Errors ---
    error ZeroAddressInput();
    error StrategyAlreadyExists();
    error StrategyAssetMismatch();
    error StrategyNotFound();
    error NoActiveStrategies();
    error AmountMustBePositive();
    error InsufficientShares();
    error NoSuitableStrategy();
    error KeeperIntervalNotMet();
    error NotEnoughFundsForWithdrawal();
    error CannotRecoverPrimaryAsset();
    error StrategyInactive();

    // --- Events ---
    event Deposited(address indexed user, uint256 amount, address indexed strategy, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 amountReturned, address indexed strategy);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event Rebalanced(address indexed fromStrategy, address indexed toStrategy, uint256 amount);
    event EmergencyWithdrawAll(address indexed admin);

    // --- State ---
    IERC20 public immutable asset;
    uint256 public totalShares;
    uint256 public keeperLastRun;
    uint256 public constant KEEPER_INTERVAL = 7 days;
    uint256 public constant REBALANCE_THRESHOLD_BPS = 150; // 1.5%

    struct StrategyInfo {
        IStrategy strategy;
        bool isActiveInRouter;
        uint256 lastAPY;
        uint256 balance;
    }

    mapping(address => StrategyInfo) public strategyDefinitions;
    address[] public activeStrategyList;
    mapping(address => uint256) public userShares;

    /**
     * @notice Constructor
     * @param _assetTokenAddress The ERC20 asset managed (e.g., stBTC, bridged BTC, etc.)
     * @param _initialAdmin Admin address
     * @param _initialKeeper Keeper address
     */
    constructor(address _assetTokenAddress, address _initialAdmin, address _initialKeeper) {
        if (_assetTokenAddress == address(0)) revert ZeroAddressInput();
        if (_initialAdmin == address(0)) revert ZeroAddressInput();
        if (_initialKeeper == address(0)) revert ZeroAddressInput();
        asset = IERC20(_assetTokenAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(ADMIN_ROLE, _initialAdmin);
        _grantRole(KEEPER_ROLE, _initialKeeper);
    }

    // --- Strategy Management ---
    /**
     * @notice Add a new strategy to the router
     * @param _strategyAddr The address of the strategy contract
     */
    function addStrategy(address _strategyAddr) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (_strategyAddr == address(0)) revert ZeroAddressInput();
        if (address(strategyDefinitions[_strategyAddr].strategy) != address(0)) revert StrategyAlreadyExists();
        if (!_isContract(_strategyAddr)) revert StrategyNotFound();
        IStrategy strategyContract = IStrategy(_strategyAddr);
        if (strategyContract.asset() != address(asset)) revert StrategyAssetMismatch();
        strategyDefinitions[_strategyAddr] = StrategyInfo({
            strategy: strategyContract,
            isActiveInRouter: true,
            lastAPY: 0,
            balance: 0
        });
        activeStrategyList.push(_strategyAddr);
        emit StrategyAdded(_strategyAddr);
    }

    /**
     * @notice Remove a strategy from the router
     * @param _strategyAddr The address of the strategy contract
     */
    function removeStrategy(address _strategyAddr) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (address(strategyDefinitions[_strategyAddr].strategy) == address(0)) revert StrategyNotFound();
        strategyDefinitions[_strategyAddr].isActiveInRouter = false;
        emit StrategyRemoved(_strategyAddr);
    }

    /**
     * @notice Activate a previously deactivated strategy (test/dev only)
     * @param _strategyAddr The address of the strategy contract
     */
    function activateStrategy(address _strategyAddr) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (address(strategyDefinitions[_strategyAddr].strategy) == address(0)) revert StrategyNotFound();
        strategyDefinitions[_strategyAddr].isActiveInRouter = true;
    }

    // --- Deposit/Withdraw ---
    /**
     * @notice Deposit BTC asset into the best-performing strategy
     * @param _amount Amount to deposit
     * @return sharesMinted Amount of shares minted to the user
     */
    function deposit(uint256 _amount) external whenNotPaused nonReentrant returns (uint256 sharesMinted) {
        if (_amount == 0) revert AmountMustBePositive();
        if (activeStrategyList.length == 0) revert NoActiveStrategies();
        (address bestStrategyAddr, ) = _findBestPerformingStrategy();
        if (bestStrategyAddr == address(0)) revert NoSuitableStrategy();
        asset.safeTransferFrom(msg.sender, address(this), _amount);
        asset.approve(bestStrategyAddr, _amount);
        uint256 deposited = IStrategy(bestStrategyAddr).deposit(_amount);
        strategyDefinitions[bestStrategyAddr].balance += deposited;
        sharesMinted = deposited; // 1:1 for simplicity; can be improved for real vaults
        userShares[msg.sender] += sharesMinted;
        totalShares += sharesMinted;
        emit Deposited(msg.sender, deposited, bestStrategyAddr, sharesMinted);
    }

    /**
     * @notice Withdraw BTC asset by burning shares
     * @param _sharesAmount Amount of shares to burn
     * @return assetAmountReturned Amount of asset returned to the user
     */
    function withdraw(uint256 _sharesAmount) external nonReentrant returns (uint256 assetAmountReturned) {
        if (_sharesAmount == 0) revert AmountMustBePositive();
        if (userShares[msg.sender] < _sharesAmount) revert InsufficientShares();
        // Withdraw from the best strategy (for simplicity)
        (address bestStrategyAddr, ) = _findBestPerformingStrategy();
        if (bestStrategyAddr == address(0)) revert NoSuitableStrategy();
        uint256 withdrawn = IStrategy(bestStrategyAddr).withdraw(_sharesAmount);
        strategyDefinitions[bestStrategyAddr].balance -= withdrawn;
        userShares[msg.sender] -= _sharesAmount;
        totalShares -= _sharesAmount;
        asset.safeTransfer(msg.sender, withdrawn);
        emit Withdrawn(msg.sender, _sharesAmount, withdrawn, bestStrategyAddr);
        assetAmountReturned = withdrawn;
    }

    // --- Keeper/Rebalancing ---
    /**
     * @notice Keeper function to update APYs and rebalance if needed
     */
    function runKeeperTasks() external onlyRole(KEEPER_ROLE) {
        if (block.timestamp < keeperLastRun + KEEPER_INTERVAL) revert KeeperIntervalNotMet();
        keeperLastRun = block.timestamp;
        // Update APYs
        for (uint256 i = 0; i < activeStrategyList.length; i++) {
            address stratAddr = activeStrategyList[i];
            if (!strategyDefinitions[stratAddr].isActiveInRouter) continue;
            uint256 apy = strategyDefinitions[stratAddr].strategy.getAPY();
            strategyDefinitions[stratAddr].lastAPY = apy;
        }
        // Rebalance if needed
        _rebalanceFunds();
    }

    /**
     * @dev Internal: Rebalance funds if a better strategy is available
     */
    function _rebalanceFunds() internal {
        (address bestStrategyAddr, uint256 bestAPY) = _findBestPerformingStrategy();
        // Find the richest strategy (where most funds are)
        uint256 maxBalance = 0;
        address richestStrategy;
        for (uint256 i = 0; i < activeStrategyList.length; i++) {
            address stratAddr = activeStrategyList[i];
            if (!strategyDefinitions[stratAddr].isActiveInRouter) continue;
            uint256 bal = strategyDefinitions[stratAddr].balance;
            if (bal > maxBalance) {
                maxBalance = bal;
                richestStrategy = stratAddr;
            }
        }
        if (richestStrategy == address(0) || richestStrategy == bestStrategyAddr) return; // Already optimal
        uint256 richestAPY = strategyDefinitions[richestStrategy].lastAPY;
        if (bestAPY < richestAPY + REBALANCE_THRESHOLD_BPS) return; // Not enough improvement
        // Withdraw all from richest, deposit to best
        uint256 toMove = strategyDefinitions[richestStrategy].balance;
        if (toMove == 0) return;
        uint256 withdrawn = IStrategy(richestStrategy).withdraw(toMove);
        strategyDefinitions[richestStrategy].balance -= withdrawn;
        asset.approve(bestStrategyAddr, withdrawn);
        uint256 deposited = IStrategy(bestStrategyAddr).deposit(withdrawn);
        strategyDefinitions[bestStrategyAddr].balance += deposited;
        emit Rebalanced(richestStrategy, bestStrategyAddr, deposited);
    }

    /**
     * @dev Internal: Find the best performing strategy
     * @return bestStrategyAddr Address of the best strategy
     * @return maxApy APY of the best strategy
     */
    function _findBestPerformingStrategy() internal view returns (address bestStrategyAddr, uint256 maxApy) {
        maxApy = 0;
        bestStrategyAddr = address(0);
        for (uint256 i = 0; i < activeStrategyList.length; i++) {
            address stratAddr = activeStrategyList[i];
            if (!strategyDefinitions[stratAddr].isActiveInRouter) continue;
            uint256 apy = strategyDefinitions[stratAddr].lastAPY;
            if (apy > maxApy) {
                maxApy = apy;
                bestStrategyAddr = stratAddr;
            }
        }
    }

    // --- Emergency ---
    /**
     * @notice Emergency withdraw from all strategies and pause the router
     */
    function emergencyWithdrawFromAllStrategies() external onlyRole(ADMIN_ROLE) {
        _pause();
        for (uint256 i = 0; i < activeStrategyList.length; i++) {
            address stratAddr = activeStrategyList[i];
            if (!strategyDefinitions[stratAddr].isActiveInRouter) continue;
            uint256 bal = strategyDefinitions[stratAddr].balance;
            if (bal > 0) {
                IStrategy(stratAddr).withdraw(bal);
                strategyDefinitions[stratAddr].balance = 0;
            }
        }
        emit EmergencyWithdrawAll(msg.sender);
    }

    /**
     * @notice Pause the router (admin only)
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the router (admin only)
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Returns the list of all strategy addresses ever added (may include inactive)
     */
    function getAllStrategies() external view returns (address[] memory) {
        return activeStrategyList;
    }

    // --- Helpers ---
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}
