// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV4PoolManager} from "v4-core/interfaces/IUniswapV4PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BaseHook} from "v4-core/src/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/libraries/BeforeSwapDelta.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @title LuckyNBurnHook
/// @notice A Uniswap v4 hook that introduces a gamified, multi-tiered fee mechanism.
/// @dev For each swap, a fee tier is randomly selected, overriding the pool's default fee.
/// A portion of this fee is directed to LPs, and the remaining portion is burned.
contract LuckyNBurnHook is BaseHook, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeTransferLib for address;

    uint256 private constant BASIS_POINTS_MAX = 10_000;

    // --- Data Structures ---

    struct Tier {
        uint16 chanceBps; // Chance for this tier, in basis points
        uint16 feeBps;    // Total fee for this tier, in basis points
    }

    struct Config {
        Tier[4] tiers;
        address burnAddress;
        uint16 burnShareBps; // Share of the total fee that gets burned, in basis points
    }

    // --- Errors ---

    error InvalidConfig();
    error CooldownNotElapsed();
    error OnlyPoolManager();

    // --- State ---

    address public owner;

    /// @notice The default configuration for new pools if no custom config is provided.
    Config public defaultConfig;

    /// @notice Per-pool configurations, allowing each pool to have unique fee tiers.
    mapping(PoolId => Config) public poolConfigs;

    /// @dev This mapping stores the fee that needs to be burned for a given swap.
    /// It's populated in `beforeSwap` and consumed in `afterSwap`.
    /// The key is a hash of the swapper and the pool ID to ensure it's unique per swap.
    mapping(bytes32 => uint16) private _burnFeeBpsForSwap;

    constructor(IUniswapV4PoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
        _setDefaultConfig();
    }

    /// @notice Returns the hook permissions required by this contract.
    /// @dev This hook requires callbacks before initialization and before/after swaps.
    function getHookPermissions() public pure override returns (Hooks.Permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    /// @notice Hook called by the PoolManager when a pool with this hook is initialized.
    /// @dev This function sets up the fee configuration for the new pool.
    /// @param key The PoolKey of the new pool.
    /// @param hookData Custom configuration data. If empty, the contract's default config is used.
    function beforeInitialize(PoolKey calldata key, bytes calldata hookData) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        PoolId poolId = key.toId();

        if (hookData.length > 0) {
            Config memory customConfig = abi.decode(hookData, (Config));
            _validateConfig(customConfig);
            poolConfigs[poolId] = customConfig;
        } else {
            poolConfigs[poolId] = defaultConfig;
        }
        return this.beforeInitialize.selector;
    }

    /// @notice The hook called before a swap.
    /// @dev It determines the fee tier for the swap, calculates the LP and burn portions,
    /// and returns the LP fee to the pool manager.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    )
        external
        override
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        PoolId poolId = key.toId();
        Config storage config = poolConfigs[poolId];

        // 1. Get the dice roll
        uint256 roll = _getRoll(sender, poolId);

        // 2. Determine the fee tier
        Tier memory selectedTier = _getTier(config, roll);
        uint16 totalFeeBps = selectedTier.feeBps;

        // 3. Calculate LP fee and burn fee
        uint16 burnFeeBps = (totalFeeBps * config.burnShareBps) / uint16(BASIS_POINTS_MAX);
        uint16 lpFeeBps = totalFeeBps - burnFeeBps;

        // 4. Store the burn fee for afterSwap to collect
        bytes32 swapId = keccak256(abi.encodePacked(sender, poolId));
        _burnFeeBpsForSwap[swapId] = burnFeeBps;

        // 5. Return the dynamic LP fee to the PoolManager
        return LPFeeLibrary.setOverride(lpFeeBps);
    }

    /// @notice The hook called after a swap.
    /// @dev It takes the pre-calculated burn fee from the swapper and sends it to the burn address.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BeforeSwapDelta,
        bytes calldata
    )
        external
        override
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        PoolId poolId = key.toId();
        bytes32 swapId = keccak256(abi.encodePacked(sender, poolId));
        uint16 burnFeeBps = _burnFeeBpsForSwap[swapId];

        // Cleanup the storage slot
        delete _burnFeeBpsForSwap[swapId];

        if (burnFeeBps > 0) {
            Config storage config = poolConfigs[poolId];
            Currency currencyToTake = params.zeroForOne ? key.currency0 : key.currency1;
            
            uint256 amountSpecified = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
            uint256 burnAmount = (amountSpecified * burnFeeBps) / BASIS_POINTS_MAX;

            if (burnAmount > 0) {
                poolManager.take(currencyToTake, sender, burnAmount);
                currencyToTake.safeTransfer(config.burnAddress, burnAmount);
            }
        }

        return bytes4(0);
    }

    // --- Internal & Helper Functions ---

    /// @dev Establishes the initial default configuration on deployment.
    function _setDefaultConfig() internal {
        // Default Config: 10/30/50/10 chance for 0.1/0.25/0.5/1.0% fees, 50% burn
        defaultConfig = Config({
            tiers: [
                Tier({chanceBps: 1000, feeBps: 10}),   // Lucky
                Tier({chanceBps: 3000, feeBps: 25}),   // Discounted
                Tier({chanceBps: 5000, feeBps: 50}),   // Normal
                Tier({chanceBps: 1000, feeBps: 100})   // Unlucky
            ],
            burnAddress: 0x000000000000000000000000000000000000dEaD,
            burnShareBps: 5000
        });
        _validateConfig(defaultConfig);
    }

    /// @dev Generates a pseudo-random number for the dice roll.
    function _getRoll(address swapper, PoolId poolId) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            swapper,
            poolId
        ))) % BASIS_POINTS_MAX;
    }

    /// @dev Selects a fee tier based on the dice roll.
    function _getTier(Config storage config, uint256 roll) internal pure returns (Tier memory) {
        uint256 cumulativeChance = 0;
        for (uint i = 0; i < config.tiers.length; i++) {
            cumulativeChance += config.tiers[i].chanceBps;
            if (roll < cumulativeChance) {
                return config.tiers[i];
            }
        }
        // Fallback to the last tier in case of rounding errors (should not happen if config is valid)
        return config.tiers[config.tiers.length - 1];
    }
    
    /// @dev Validates that the sum of chances in a config is 100%.
    function _validateConfig(Config memory config) internal pure {
        uint256 totalChanceBps = 0;
        for (uint i = 0; i < config.tiers.length; i++) {
            totalChanceBps += config.tiers[i].chanceBps;
        }
        if (totalChanceBps != BASIS_POINTS_MAX) revert InvalidConfig();
        if (config.burnShareBps > BASIS_POINTS_MAX) revert InvalidConfig();
    }


    // --- Admin Functions ---

    /// @notice Updates the default configuration for the hook.
    /// @dev This only affects pools initialized *after* this change is made.
    function setDefaultConfig(Config calldata newConfig) external onlyOwner {
        _validateConfig(newConfig);
        defaultConfig = newConfig;
    }

    /// @notice Allows the owner to withdraw any tokens accidentally sent to this contract.
    function recoverFunds(Currency currency, uint256 amount) external onlyOwner {
        currency.safeTransfer(owner, amount);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert("OnlyOwner");
        _;
    }
} 