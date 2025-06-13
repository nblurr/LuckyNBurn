// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LuckyNBurnHook
/// @notice A gamified Uniswap v4 hook that implements variable swap fees with different tiers
/// @dev This hook introduces a gamification layer to swaps with different fee tiers:
/// - Lucky: Lowest fees with cooldown period
/// - Discounted: Reduced fees
/// - Normal: Standard fees
/// - Unlucky: Highest fees with a portion burned

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LuckyNBurnHook - A gamified Uniswap v4 hook with variable swap fees
/**
 * @title LuckyNBurnHook
 * @notice A Uniswap v4 hook that implements a gamified fee structure with different tiers
 * @dev Inherits from BaseHook and implements the required hook functions for swap operations
 */
contract LuckyNBurnHook is BaseHook {
    // -------------------------------------------------------------------
    //                              ERRORS
    // -------------------------------------------------------------------

    /// @notice Thrown when a function is called by an address that is not the owner
    error NotOwner();

    /// @notice Thrown when the sum of tier chances does not equal 10,000 basis points (100%)
    error InvalidChanceSum();

    /// @notice Thrown when a user attempts to get lucky again before the cooldown period has passed
    error CooldownActive();

    /// @notice Thrown when the burn share is set higher than 100% (10,000 basis points)
    error BurnShareTooHigh();

    // -------------------------------------------------------------------
    //                              EVENTS
    // -------------------------------------------------------------------

    /// @notice Emitted when the chances for each tier are updated
    event SetChances(uint16 lucky, uint16 discounted, uint16 normal, uint16 unlucky);

    /// @notice Emitted when the fees for each tier are updated
    event SetFees(uint16 lucky, uint16 discounted, uint16 normal, uint16 unlucky);

    /// @notice Emitted when the cooldown period is updated
    event SetCooldown(uint256 period);

    /// @notice Emitted when the burn configuration is updated
    event SetBurnConfig(address burnAddress, uint16 burnShareBps);

    /// @notice Emitted when a user gets the lucky tier
    event Lucky(address indexed trader, uint16 feeBps, uint256 timestamp);

    /// @notice Emitted when a user gets the discounted tier
    event Discounted(address indexed trader, uint16 feeBps);

    /// @notice Emitted when a user gets the normal tier
    event Normal(address indexed trader, uint16 feeBps);

    /// @notice Emitted when a user gets the unlucky tier (includes burn amount)
    event Unlucky(address indexed trader, uint16 feeBps, uint256 burnAmount);

    // -------------------------------------------------------------------
    //                             STRUCTS & ENUMS
    // -------------------------------------------------------------------

    /**
     * @notice Defines a fee tier with its chance and fee rate
     * @member chanceBps The chance of this tier being selected (in basis points)
     * @member feeBps The fee rate for this tier (in basis points)
     */
    struct Tier {
        uint16 chanceBps;
        uint16 feeBps;
    }

    /**
     * @notice Enumerates the possible tier types
     */
    enum TierType {
        Lucky,      // Lowest fees with cooldown
        Discounted, // Reduced fees
        Normal,     // Standard fees
        Unlucky     // Highest fees with burn
    }

    /**
     * @notice Stores the result of a tier selection
     * @member tierType The type of tier selected
     * @member feeBps The fee rate for the selected tier (in basis points)
     */
    struct TierResult {
        TierType tierType;
        uint16 feeBps;
    }

    // -------------------------------------------------------------------
    //                            MODIFIERS
    // -------------------------------------------------------------------

    /**
     * @notice Restricts function access to the contract owner
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // -------------------------------------------------------------------
    //                             STORAGE
    // -------------------------------------------------------------------

    /// @notice The owner of the contract with administrative privileges
    address public immutable owner;

    // Fee tiers configuration
    Tier public lucky;      // Lowest fee tier with cooldown
    Tier public discounted; // Reduced fee tier
    Tier public normal;     // Standard fee tier
    Tier public unlucky;    // Highest fee tier with burn

    /// @notice The address where burned tokens are sent
    address public burnAddress;

    /// @notice The percentage of fees to burn (in basis points)
    uint16 public burnShareBps;

    /// @notice The cooldown period between lucky rewards for a single address
    uint256 public cooldownPeriod = 1 hours;

    /// @notice Tracks the last timestamp an address received a lucky reward
    mapping(address => uint256) public lastLuckyTimestamp;

    /// @notice Stores the tier results for each swap by swap ID
    mapping(bytes32 => TierResult) public tierResults;

    // -------------------------------------------------------------------
    //                          CONSTRUCTOR
    // -------------------------------------------------------------------

    /**
     * @notice Initializes the LuckyNBurnHook contract
     * @param _poolManager The address of the Uniswap v4 PoolManager
     * @dev Sets up initial fee tiers and burn configuration
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;

        // Initialize fee tiers (chanceBps, feeBps)
        lucky = Tier(1000, 10);      // 10% chance, 0.1% fee
        discounted = Tier(3000, 25);  // 30% chance, 0.25% fee
        normal = Tier(5000, 50);      // 50% chance, 0.5% fee
        unlucky = Tier(1000, 100);    // 10% chance, 1% fee

        // Default burn configuration
        burnAddress = 0x000000000000000000000000000000000000dEaD; // Burn address
        burnShareBps = 5000; // 50% of fees are burned for unlucky swaps
    }

    // -------------------------------------------------------------------
    //                          PERMISSIONS
    // -------------------------------------------------------------------

    /**
     * @notice Returns the hook permissions required by this contract
     * @return permissions The hook permissions configuration
     * @dev This hook implements beforeSwap and afterSwap callbacks
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------
    //                          TIER SELECTION
    // -------------------------------------------------------------------

    /**
     * @notice Generates a pseudo-random roll for fee tier selection
     * @param trader The address of the trader
     * @param salt A unique salt for the swap
     * @return A random number between 0 and 9,999 (inclusive)
     * @dev Uses block.timestamp and blockhash for randomness (not suitable for production)
     */
    function _getRoll(address trader, bytes32 salt) internal view returns (uint16) {
        return uint16(uint256(keccak256(abi.encodePacked(
            trader,
            salt,
            block.timestamp,
            blockhash(block.number - 1)
        ))) % 10_000);
    }

    /**
     * @notice Selects a fee tier based on a random roll
     * @param roll A random number between 0 and 9,999
     * @return The selected tier type and its corresponding fee
     * @dev Uses cumulative probability to select the appropriate tier
     */
    function _selectTier(uint16 roll) internal view returns (TierType, uint16) {
        uint16 cumulative = 0;
        if (roll < (cumulative += lucky.chanceBps)) {
            return (TierType.Lucky, lucky.feeBps);
        } else if (roll < (cumulative += discounted.chanceBps)) {
            return (TierType.Discounted, discounted.feeBps);
        } else if (roll < (cumulative += normal.chanceBps)) {
            return (TierType.Normal, normal.feeBps);
        } else {
            return (TierType.Unlucky, unlucky.feeBps);
        }
    }

    // -------------------------------------------------------------------
    //                          HOOK IMPLEMENTATION
    // -------------------------------------------------------------------

    /**
     * @notice Hook called before a swap executes
     * @param hookData Encoded trader and salt for tier selection
     * @return selector The function selector for the beforeSwap hook
     * @return delta The before swap delta (empty)
     * @return fee The dynamic fee for this swap
     * @dev Selects a random tier for the swap and stores the result
     */
    function _beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (address trader, bytes32 salt) = abi.decode(hookData, (address, bytes32));
        uint16 roll = _getRoll(trader, salt);
        (TierType tier, uint16 feeBps) = _selectTier(roll);
        tierResults[keccak256(abi.encodePacked(trader, salt))] = TierResult(tier, feeBps);

        // Return the correct selector for beforeSwap
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeBps);
    }

    /**
     * @notice Hook called after a swap executes to process fees and rewards
     * @param key The pool key
     * @param params Swap parameters
     * @param delta The balance delta from the swap
     * @param hookData Encoded trader and salt for tier lookup
     * @return selector The function selector
     * @return deltaReturn The delta to return to the pool
     * @dev Processes fees, burns tokens for unlucky swaps, and applies cooldowns
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        (address trader, bytes32 salt) = abi.decode(hookData, (address, bytes32));
        bytes32 swapId = keccak256(abi.encodePacked(trader, salt));
        TierResult memory result = tierResults[swapId];

        int128 deltaReturn = 0;

        if (result.tierType == TierType.Unlucky) {
            uint256 amountIn = params.zeroForOne
                ? uint256(int256(-delta.amount0()))
                : uint256(int256(-delta.amount1()));

            uint256 totalFee = (amountIn * result.feeBps) / 10_000;
            uint256 burnAmount = (totalFee * burnShareBps) / 10_000;

            // Return a delta that reduces the user's output by the burn amount
            // This effectively "burns" the tokens by never giving them to the user
            deltaReturn = params.zeroForOne ? int128(uint128(burnAmount)) : -int128(uint128(burnAmount));

            emit Unlucky(trader, result.feeBps, burnAmount);
        } else if (result.tierType == TierType.Lucky) {
            if (block.timestamp < lastLuckyTimestamp[trader] + cooldownPeriod) {
                revert CooldownActive();
            }
            lastLuckyTimestamp[trader] = block.timestamp;
            emit Lucky(trader, result.feeBps, block.timestamp);
        } else if (result.tierType == TierType.Discounted) {
            emit Discounted(trader, result.feeBps);
        } else {
            emit Normal(trader, result.feeBps);
        }

        delete tierResults[swapId];
        return (BaseHook.afterSwap.selector, deltaReturn);
    }

    // -------------------------------------------------------------------
    //                          ADMIN FUNCTIONS
    // -------------------------------------------------------------------
    /**
     * @notice Updates the chance distribution for each tier
     * @param luckyBps Chance for lucky tier (in basis points)
     * @param discountedBps Chance for discounted tier (in basis points)
     * @param normalBps Chance for normal tier (in basis points)
     * @param unluckyBps Chance for unlucky tier (in basis points)
     * @dev The sum of all chances must equal 10,000 (100%)
     */
    function setChances(
        uint16 luckyBps,
        uint16 discountedBps,
        uint16 normalBps,
        uint16 unluckyBps
    ) external onlyOwner {
        if (luckyBps + discountedBps + normalBps + unluckyBps != 10_000) {
            revert InvalidChanceSum();
        }
        lucky.chanceBps = luckyBps;
        discounted.chanceBps = discountedBps;
        normal.chanceBps = normalBps;
        unlucky.chanceBps = unluckyBps;
        emit SetChances(luckyBps, discountedBps, normalBps, unluckyBps);
    }

    /**
     * @notice Updates the fee rates for each tier
     * @param luckyFee Fee for lucky tier (in basis points)
     * @param discountedFee Fee for discounted tier (in basis points)
     * @param normalFee Fee for normal tier (in basis points)
     * @param unluckyFee Fee for unlucky tier (in basis points)
     */
    function setFees(
        uint16 luckyFee,
        uint16 discountedFee,
        uint16 normalFee,
        uint16 unluckyFee
    ) external onlyOwner {
        lucky.feeBps = luckyFee;
        discounted.feeBps = discountedFee;
        normal.feeBps = normalFee;
        unlucky.feeBps = unluckyFee;
        emit SetFees(luckyFee, discountedFee, normalFee, unluckyFee);
    }

    function setCooldownPeriod(uint256 period) external onlyOwner {
        cooldownPeriod = period;
        emit SetCooldown(period);
    }

    function setBurnConfig(address _burnAddress, uint16 _burnShareBps) external onlyOwner {
        if (_burnShareBps > 10_000) revert BurnShareTooHigh();
        burnAddress = _burnAddress;
        burnShareBps = _burnShareBps;
        emit SetBurnConfig(_burnAddress, _burnShareBps);
    }
}
