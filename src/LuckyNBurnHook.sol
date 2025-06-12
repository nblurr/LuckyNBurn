// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager, SwapParams} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-periphery/lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IERC20} from "v4-periphery/lib/v4-core/lib/forge-std/src/interfaces/IERC20.sol";


// --- Data Structures ---

struct Tier {
    uint24 chanceBps; // Chance for this tier, in basis points
    uint24 feeBps;    // Total fee for this tier, in basis points
}

struct Config {
    Tier[4] tiers;
    address burnAddress;
    uint24 burnShareBps; // Share of the total fee that gets burned, in basis points
}

/// @title LuckyNBurnHook
/// @notice A Uniswap v4 hook that introduces a gamified, multi-tiered fee mechanism.
/// @dev For each swap, a fee tier is randomly selected, overriding the pool's default fee.
/// A portion of this fee is directed to LPs, and the remaining portion is burned.
contract LuckyNBurnHook is BaseHook, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeTransferLib for address;
    using LPFeeLibrary for uint24;

    uint256 private constant BASIS_POINTS_MAX = 10_000;

    // --- Errors ---

    error InvalidConfig();
    error CooldownNotElapsed();
    error OnlyPoolManager();

    // --- State ---

    address public owner;
    mapping(PoolId => Config) internal poolConfigs; // Ensure public, no custom getter

    /// @notice The default configuration for new pools if no custom config is provided.
    Config public defaultConfig;

    /// @dev This mapping stores the fee that needs to be burned for a given swap.
    /// It's populated in `beforeSwap` and consumed in `afterSwap`.
    /// The key is a hash of the swapper and the pool ID to ensure it's unique per swap.
    mapping(bytes32 => uint24) private _burnFeeBpsForSwap;

    error MustUseDynamicFee();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
    }

    function getConfig() public view returns (Config memory) {
        return defaultConfig;
    }

    function getDefaultConfig() public view returns (Config memory) {
        return Config({
            tiers: [
                Tier({chanceBps: 1000, feeBps: 10}),
                Tier({chanceBps: 3000, feeBps: 25}),
                Tier({chanceBps: 5000, feeBps: 50}),
                Tier({chanceBps: 1000, feeBps: 100})
            ],
            burnAddress: 0x000000000000000000000000000000000000dEaD,
            burnShareBps: 5000
        });
    } 

    /// @notice Returns the hook permissions required by this contract.
    /// @dev This hook requires callbacks before initialization and before/after swaps.
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @notice Hook called by the PoolManager when a pool with this hook is initialized.
    /// @dev This function sets up the fee configuration for the new pool.
    /// @param key The PoolKey of the new pool.
    /// @param hookData Custom configuration data. If empty, the contract's default config is used.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData) external returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();

        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        
        PoolId poolId = key.toId();

/*
        if (hookData.length > 0) {
            Config memory customConfig = abi.decode(hookData, (Config));
            _validateConfig(customConfig);
        } else {
 */
            setPoolConfigs(poolId, getDefaultConfig());
        //}
        return this.beforeInitialize.selector;
    }

    function getPoolConfigs(PoolId poolId) public view returns (Config memory) {
        return poolConfigs[poolId];
    }

    function setPoolConfigs(PoolId poolId, Config memory config) public returns (Config memory) {
        // Copy each tier individually to avoid the memory to storage copy issue
        for (uint i = 0; i < 4; i++) {
            poolConfigs[poolId].tiers[i] = config.tiers[i];
        }
        poolConfigs[poolId].burnAddress = config.burnAddress;
        poolConfigs[poolId].burnShareBps = config.burnShareBps;
        return config;
    }

    /// @notice The hook called before a swap.
    /// @dev It determines the fee tier for the swap, calculates the LP and burn portions,
    /// and returns the LP fee to the pool manager.
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata _hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        PoolId poolId = key.toId();
        Config memory config = getPoolConfigs(poolId);

        // 1. Get the dice roll
        uint256 roll = _getRoll(msg.sender, poolId);

        // 2. Determine the fee tier
        Tier memory selectedTier = _getTier(config, roll);
        uint24 totalFeeBps = selectedTier.feeBps;

        // 3. Calculate LP fee and burn fee
        uint24 burnFeeBps = (totalFeeBps * config.burnShareBps) / uint24(BASIS_POINTS_MAX);
        uint24 lpFeeBps = totalFeeBps - burnFeeBps;

        // 4. Store the burn fee for afterSwap to collect
        bytes32 swapId = keccak256(abi.encodePacked(msg.sender, poolId));
        _burnFeeBpsForSwap[swapId] = burnFeeBps;

        uint24 lpFeeBpsWithFlag = lpFeeBps | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // 5. Return the dynamic LP fee to the PoolManager
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeBpsWithFlag);
    }

    /// @notice The hook called after a swap.
    /// @dev It takes the pre-calculated burn fee from the swapper and sends it to the burn address.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BeforeSwapDelta _delta,
        bytes calldata _hookData
     ) internal returns (bytes4, int128) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        PoolId poolId = key.toId();
        bytes32 swapId = keccak256(abi.encodePacked(sender, poolId));
        uint24 burnFeeBps = _burnFeeBpsForSwap[swapId];

        // Cleanup the storage slot
        delete _burnFeeBpsForSwap[swapId];

        if (burnFeeBps > 0) {
            Config memory config = getPoolConfigs(poolId);
            Currency currencyToTake = params.zeroForOne ? key.currency0 : key.currency1;
            
            uint256 amountSpecified = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
            uint256 burnAmount = (amountSpecified * burnFeeBps) / BASIS_POINTS_MAX;

            if (burnAmount > 0) {
                poolManager.take(currencyToTake, sender, burnAmount);

                if (burnAmount > 0) {
                    poolManager.take(currencyToTake, config.burnAddress, burnAmount);
                }
            }
        }

        return (this.afterSwap.selector, 0);
    }

    // --- Internal & Helper Functions ---

    /// @dev Establishes the initial default configuration on deployment.

    function setDefaultConfig() public {
        // Set each tier individually
        defaultConfig.tiers[0] = Tier({chanceBps: 1000, feeBps: 10});
        defaultConfig.tiers[1] = Tier({chanceBps: 3000, feeBps: 25});
        defaultConfig.tiers[2] = Tier({chanceBps: 5000, feeBps: 50});
        defaultConfig.tiers[3] = Tier({chanceBps: 1000, feeBps: 100});
        defaultConfig.burnAddress = 0x000000000000000000000000000000000000dEaD;
        defaultConfig.burnShareBps = 5000;
        _validateConfig(defaultConfig);
    }

    function setConfig(Config memory newConfig) public {
        // Copy each tier individually to avoid the memory to storage copy issue
        for (uint i = 0; i < 4; i++) {
            defaultConfig.tiers[i] = newConfig.tiers[i];
        }
        defaultConfig.burnAddress = newConfig.burnAddress;
        defaultConfig.burnShareBps = newConfig.burnShareBps;
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
    function _getTier(Config memory config, uint256 roll) internal pure returns (Tier memory) {
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

    /// @notice Allows the owner to withdraw any tokens accidentally sent to this contract.
    function recoverFunds(Currency currency, uint256 amount) external onlyOwner {
        poolManager.take(currency, owner, amount);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert("OnlyOwner");
        _;
    }
} 