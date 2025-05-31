// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IStrategy.sol";

/**
 * @title BabylonStrategy
 * @author LayerBTC Team
 * @notice Example strategy for Babylon protocol integration (mocked for demo).
 */
contract BabylonStrategy is IStrategy, AccessControlEnumerable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant STRATEGY_ADMIN_ROLE = keccak256("STRATEGY_ADMIN_ROLE");
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    // --- State ---
    address private immutable _asset;
    address public routerAddress;
    bool public active = true;
    uint256 public totalAssetsHeld;
    uint256 public mockAPY; // basis points

    // --- Custom Errors ---
    error CallerNotRouter();
    error ZeroAmount();
    error NotActive();
    error RouterCannotBeZero();

    // --- Events ---
    event DepositedInStrategy(uint256 amount);
    event WithdrawnFromStrategy(uint256 amount);
    event APYUpdated(uint256 newAPY);

    modifier onlyRouter() {
        if (msg.sender != routerAddress) revert CallerNotRouter();
        _;
    }
    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(STRATEGY_ADMIN_ROLE, msg.sender)) revert CallerNotRouter();
        _;
    }

    constructor(address asset_, address _admin) {
        require(asset_ != address(0) && _admin != address(0), "Zero address");
        _asset = asset_;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(STRATEGY_ADMIN_ROLE, _admin);
    }

    function setRouter(address _router) external onlyAdmin {
        if (_router == address(0)) revert RouterCannotBeZero();
        routerAddress = _router;
        _grantRole(ROUTER_ROLE, _router);
    }

    function deposit(uint256 amount) external override onlyRouter nonReentrant returns (uint256) {
        if (!active) revert NotActive();
        if (amount == 0) revert ZeroAmount();
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), amount);
        totalAssetsHeld += amount;
        emit DepositedInStrategy(amount);
        return amount;
    }

    function withdraw(uint256 amount) external override onlyRouter nonReentrant returns (uint256) {
        if (!active) revert NotActive();
        if (amount == 0) revert ZeroAmount();
        if (amount > totalAssetsHeld) amount = totalAssetsHeld;
        totalAssetsHeld -= amount;
        IERC20(_asset).safeTransfer(msg.sender, amount);
        emit WithdrawnFromStrategy(amount);
        return amount;
    }

    function totalAssets() external view override returns (uint256) {
        return totalAssetsHeld;
    }

    function getAPY() external view override returns (uint256) {
        return mockAPY;
    }

    function isActive() external view override returns (bool) {
        return active;
    }

    function setPerformanceMetric(uint256 apy) external onlyAdmin {
        mockAPY = apy;
        emit APYUpdated(apy);
    }

    function asset() external view override returns (address assetAddress) {
        return _asset;
    }
}
