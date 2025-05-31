// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStrategy
 * @author LayerBTC Team
 * @notice Interface for all yield-generating strategies that can be integrated with the VaultStrategyRouter.
 * Each strategy manages a specific underlying asset and reports its performance.
 */
interface IStrategy {
    /**
     * @notice Returns the ERC20 token address of the asset this strategy manages.
     * @return assetAddress The address of the underlying asset.
     */
    function asset() external view returns (address assetAddress);

    /**
     * @notice Deposits a specified amount of the underlying asset into the strategy.
     * @dev Should only be callable by the authorized VaultStrategyRouter.
     * @param amount The amount of the asset to deposit.
     * @return depositedAmount The actual amount of asset successfully deposited.
     */
    function deposit(uint256 amount) external returns (uint256 depositedAmount);

    /**
     * @notice Withdraws a specified amount of the underlying asset from the strategy.
     * @dev Should only be callable by the authorized VaultStrategyRouter.
     * @param amount The amount of the asset to withdraw.
     * @return withdrawnAmount The actual amount of asset withdrawn.
     */
    function withdraw(uint256 amount) external returns (uint256 withdrawnAmount);

    /**
     * @notice Returns the total assets managed by the strategy.
     * @return totalAssets The total amount of the underlying asset managed.
     */
    function totalAssets() external view returns (uint256 totalAssets);

    /**
     * @notice Returns the current APY or performance metric for the strategy (basis points, e.g., 100 = 1%).
     * @return apy The current APY in basis points.
     */
    function getAPY() external view returns (uint256 apy);

    /**
     * @notice Returns true if the strategy is active and can accept deposits.
     */
    function isActive() external view returns (bool);

    /**
     * @notice Called by the router to set itself as the authorized router.
     * @param router The address of the router contract.
     */
    function setRouter(address router) external;
}
