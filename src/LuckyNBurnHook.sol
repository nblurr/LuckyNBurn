// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LuckyNBurnHook
/// @notice A gamified Uniswap v4 hook that implements variable swap fees with different tiers and loyalty program
/// @dev This hook introduces a gamification layer to swaps with different fee tiers:
/// - Lucky: Lowest fees with cooldown period
/// - Discounted: Reduced fees
/// - Normal: Standard fees
/// - Unlucky: Highest fees with a portion collected for burning

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Slot0} from "v4-core/types/Slot0.sol";
import {IExtsload} from "v4-core/interfaces/IExtsload.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import {LoyaltyLib} from "./LoyaltyLib.sol";

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

    /// @notice Thrown when trying to burn tokens but no tokens are collected
    error NothingToBurn();

    /// @notice Thrown when token transfer fails
    error TransferFailed();

    /// @notice Thrown when loyalty configuration is invalid
    error InvalidLoyaltyConfig();

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

    /// @notice Emitted when the loyalty configuration is updated
    event SetLoyaltyConfig(uint8[5] thresholds, uint16[5] luckyBonuses, uint16[5] feeDiscounts);

    /// @notice Emitted when a user gets the lucky tier
    event Lucky(address indexed trader, uint16 feeBps, uint256 timestamp);

    /// @notice Emitted when a user gets the discounted tier
    event Discounted(address indexed trader, uint16 feeBps);

    /// @notice Emitted when a user gets the normal tier
    event Normal(address indexed trader, uint16 feeBps);

    /// @notice Emitted when a user gets the unlucky tier (includes burn amount)
    event Unlucky(address indexed trader, uint16 feeBps, uint256 burnAmount);

    /// @notice Emitted when tokens are burned
    event TokensBurned(Currency indexed currency, uint256 amount);

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
        Lucky, // Lowest fees with cooldown
        Discounted, // Reduced fees
        Normal, // Standard fees
        Unlucky // Highest fees with burn
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
    Tier public lucky; // Lowest fee tier with cooldown
    Tier public discounted; // Reduced fee tier
    Tier public normal; // Standard fee tier
    Tier public unlucky; // Highest fee tier with burn

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

    /// @notice Tracks tokens collected for burning by currency
    mapping(Currency => uint256) public collectedForBurning;

    Currency[] public allCurrencies;
    mapping(Currency => bool) public isTrackedCurrency;

    // Loyalty system storage - store as single struct instead of separate arrays
    LoyaltyLib.LoyaltyConfig loyaltyConfig;

    /// @notice Loyalty data per trader
    mapping(address => LoyaltyLib.LoyaltyData) loyaltyData;

    // The default base fees we will charge
    uint24 public constant BASE_FEE = 3000; // denominated in pips (one-hundredth bps) 0.3%

    // -------------------------------------------------------------------
    //                          CONSTRUCTOR
    // -------------------------------------------------------------------

    /**
     * @notice Initializes the LuckyNBurnHook contract
     * @param _poolManager The address of the Uniswap v4 PoolManager
     * @dev Sets up initial fee tiers, burn configuration, and loyalty system
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;

        // Initialize fee tiers (chanceBps, feeBps)
        lucky = Tier(1000, 0); // 10% chance, 0% additional to base .3% = 0.3%
        discounted = Tier(3000, 25); // 30% chance, 0.25% additional to base .3% = 0.55%
        normal = Tier(5000, 50); // 50% chance, 0.5% additional to base .3% = 0.8%
        unlucky = Tier(1000, 100); // 10% chance, 1% additional to base .3% = 1.3%. 50% of 1% burn

        // Default burn configuration
        burnAddress = 0x000000000000000000000000000000000000dEaD; // Burn address
        burnShareBps = 5000; // 50% of unlucky fees go toward burn calculation

        // Initialize loyalty system with default configuration
        loyaltyConfig = LoyaltyLib.getDefaultConfig();
    }

    /**
     * @notice Returns the hook permissions required by this contract
     * @return permissions The hook permissions configuration
     * @dev This hook implements beforeSwap and afterSwap callbacks with return delta
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
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true, // ENABLE: Required to return delta from afterSwap
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------
    //                          TIER SELECTION & FEES + REWARD
    // -------------------------------------------------------------------

    /**
     * @notice Generates a pseudo-random roll for fee tier selection
     * @param trader The address of the trader
     * @param salt A unique salt for the swap
     * @return A random number between 0 and 9,999 (inclusive)
     * @dev Uses block.timestamp and block-hash for randomness (not suitable for production)
     */
    function _getRoll(address trader, bytes32 salt) internal view returns (uint16) {
        return uint16(
            uint256(keccak256(abi.encodePacked(trader, salt, block.timestamp, blockhash(block.number - 1)))) % 10_000
        );
    }

    /**
     * @notice Selects a fee tier based on a random roll and loyalty adjustments
     * @param trader The trader's address
     * @param roll A random number between 0 and 9,999
     * @return The selected tier type and its corresponding fee (after loyalty discounts)
     * @dev Uses cumulative probability to select the appropriate tier with loyalty bonuses
     */
    function _selectTier(address trader, uint16 roll) internal view returns (TierType, uint16) {
        // Get loyalty-adjusted lucky chance and fee discount
        uint16 adjustedLuckyChance = LoyaltyLib.getAdjustedLuckyChance(loyaltyData[trader], loyaltyConfig, lucky.chanceBps);
        uint16 feeDiscount = LoyaltyLib.getFeeDiscount(loyaltyData[trader], loyaltyConfig);

        uint16 cumulative = 0;
        if (roll < (cumulative += adjustedLuckyChance)) {
            uint16 discountedFee = lucky.feeBps > feeDiscount ? lucky.feeBps - feeDiscount : 0;
            return (TierType.Lucky, discountedFee);
        } else if (roll < (cumulative += discounted.chanceBps)) {
            uint16 discountedFee = discounted.feeBps > feeDiscount ? discounted.feeBps - feeDiscount : 0;
            return (TierType.Discounted, discountedFee);
        } else if (roll < (cumulative += normal.chanceBps)) {
            uint16 discountedFee = normal.feeBps > feeDiscount ? normal.feeBps - feeDiscount : 0;
            return (TierType.Normal, discountedFee);
        } else {
            uint16 discountedFee = unlucky.feeBps > feeDiscount ? unlucky.feeBps - feeDiscount : 0;
            return (TierType.Unlucky, discountedFee);
        }
    }

    /**
    * @notice Hook called before a swap executes to determine the fee tier, set dynamic fees, and prepare for afterSwap processing.
    */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24)
    {
        (address trader, bytes32 salt) = abi.decode(hookData, (address, bytes32));
        uint16 roll = _getRoll(trader, salt);
        (TierType tier, uint16 feeBps) = _selectTier(trader, roll);

        if (tier == TierType.Lucky) {
            uint256 adjustedCooldown = LoyaltyLib.getAdjustedCooldown(loyaltyData[trader], loyaltyConfig, cooldownPeriod);
            if (block.timestamp < lastLuckyTimestamp[trader] + adjustedCooldown) {
                revert CooldownActive();
            }
        }

        tierResults[keccak256(abi.encodePacked(trader, salt))] = TierResult(tier, feeBps);

        uint24 newFee = BASE_FEE + (((feeBps/100) * 1000000) / 100);

        uint24 feeWithFlag = newFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        poolManager.updateDynamicLPFee(key, newFee);

        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeWithFlag
        );
    }

    /**
    * @notice Hook called after a swap executes to process tier-based fee logic, burning, loyalty updates, and event emission.
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

        // Update loyalty metrics
        int256 tokenDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 swapAmount = uint256(tokenDelta > 0 ? tokenDelta : -tokenDelta);
        LoyaltyLib.updateLoyaltyMetrics(loyaltyData[trader], loyaltyConfig, trader, swapAmount);

        // End goal, only burn some token1 no matter the params.zeroForOne value
        if (result.tierType == TierType.Unlucky) {
            uint256 burnAmount = 0;

            uint256 absTokenFlow = uint256(tokenDelta > 0 ? tokenDelta : -tokenDelta);
            uint256 feeAmount = (absTokenFlow * result.feeBps) / 10_000; // Always burn the base fee
            burnAmount = (feeAmount * burnShareBps) / 10_000;

            Currency burnCurrency = params.zeroForOne ? key.currency1 : key.currency0;

            // Track burned amount
            collectedForBurning[burnCurrency] += burnAmount;
            if (!isTrackedCurrency[burnCurrency]) {
                isTrackedCurrency[burnCurrency] = true;
                allCurrencies.push(burnCurrency);
            }

            // Emit burn event
            emit Unlucky(trader, result.feeBps, burnAmount);

            // Clean up
            delete tierResults[swapId];

            int128 hookDelta = int128(int256(burnAmount));

            // Take some from pool to hook
            poolManager.take(
                burnCurrency,
                address(this),
                burnAmount
            );

            // Send some from hook to death / burn
            IERC20(Currency.unwrap(burnCurrency)).transfer(burnAddress, burnAmount);

            // Return the other 50% of fees to pool
            return (this.afterSwap.selector, hookDelta);

        } else if (result.tierType == TierType.Lucky) {
            lastLuckyTimestamp[trader] = block.timestamp;
            emit Lucky(trader, result.feeBps, block.timestamp);
        } else if (result.tierType == TierType.Discounted) {
            emit Discounted(trader, result.feeBps);
        } else {
            emit Normal(trader, result.feeBps);
        }

        // Clean up storage for non-Unlucky swaps or if no burn was needed
        delete tierResults[swapId];
        return (BaseHook.afterSwap.selector, 0);
    }

    // -------------------------------------------------------------------
    //                          LOYALTY VIEW FUNCTIONS
    // -------------------------------------------------------------------

    /**
     * @notice Get comprehensive loyalty stats for a trader
     * @param trader The trader's address
     * @return stats Complete loyalty statistics
     */
    function getLoyaltyStats(address trader) external view returns (LoyaltyLib.LoyaltyStats memory stats) {
        return LoyaltyLib.getLoyaltyStats(loyaltyData[trader], loyaltyConfig);
    }

    /**
     * @notice Get the loyalty tier for a trader
     * @param trader The trader's address
     * @return The loyalty tier
     */
    function getLoyaltyTier(address trader) external view returns (LoyaltyLib.LoyaltyTier) {
        return LoyaltyLib.getLoyaltyTier(loyaltyData[trader], loyaltyConfig);
    }

    /**
     * @notice Check how many swaps until next tier
     * @param trader The trader's address
     * @return swapsNeeded Number of swaps needed for next tier (0 if max tier)
     */
    function swapsUntilNextTier(address trader) external view returns (uint256 swapsNeeded) {
        return LoyaltyLib.swapsUntilNextTier(loyaltyData[trader], loyaltyConfig);
    }

    /**
     * @notice Get loyalty tier name as string
     * @param tier The loyalty tier
     * @return The tier name
     */
    function getTierName(LoyaltyLib.LoyaltyTier tier) external pure returns (string memory) {
        return LoyaltyLib.getTierName(tier);
    }

    /**
     * @notice Get swap count for a trader
     * @param trader The trader's address
     * @return The number of swaps
     */
    function getSwapCount(address trader) external view returns (uint256) {
        return loyaltyData[trader].swapCount;
    }

    /**
     * @notice Get total volume for a trader
     * @param trader The trader's address
     * @return The total volume traded
     */
    function getTotalVolume(address trader) external view returns (uint256) {
        return loyaltyData[trader].totalVolume;
    }

    // -------------------------------------------------------------------
    //                          VIEW FUNCTIONS
    // -------------------------------------------------------------------

    function getCollectedForBurning(Currency currency) external view returns (uint256) {
        return collectedForBurning[currency];
    }

    /**
     * @notice Get current loyalty configuration (for testing)
     * @return The current loyalty configuration
     */
    function getLoyaltyConfig() external view returns (LoyaltyLib.LoyaltyConfig memory) {
        return loyaltyConfig;
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
    function setChances(uint16 luckyBps, uint16 discountedBps, uint16 normalBps, uint16 unluckyBps)
    external
    onlyOwner
    {
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
    function setFees(uint16 luckyFee, uint16 discountedFee, uint16 normalFee, uint16 unluckyFee) external onlyOwner {
        lucky.feeBps = luckyFee;
        discounted.feeBps = discountedFee;
        normal.feeBps = normalFee;
        unlucky.feeBps = unluckyFee;
        emit SetFees(luckyFee, discountedFee, normalFee, unluckyFee);
    }

    /**
    * @notice Updates the cooldown period between lucky rewards for a single address.
    * @param period The new cooldown period in seconds.
    * @dev Only callable by the contract owner. Emits a SetCooldown event.
    */
    function setCooldownPeriod(uint256 period) external onlyOwner {
        cooldownPeriod = period;
        emit SetCooldown(period);
    }

    /**
    * @notice Updates the burn address and the percentage of fees to burn.
    * @param _burnAddress The new address where burned tokens will be sent.
    * @param _burnShareBps The new burn share in basis points (max 10,000 = 100%).
    * @dev Only callable by the contract owner. Reverts if burn share is above 100%. Emits a SetBurnConfig event.
    */
    function setBurnConfig(address _burnAddress, uint16 _burnShareBps) external onlyOwner {
        if (_burnShareBps > 10_000) revert BurnShareTooHigh();
        burnAddress = _burnAddress;
        burnShareBps = _burnShareBps;
        emit SetBurnConfig(_burnAddress, _burnShareBps);
    }

    /**
     * @notice Update loyalty configuration
     * @param newConfig The new loyalty configuration
     * @dev Only callable by the contract owner
     */
    function setLoyaltyConfig(LoyaltyLib.LoyaltyConfig calldata newConfig) external onlyOwner {
        if (!LoyaltyLib.validateConfig(newConfig)) {
            revert InvalidLoyaltyConfig();
        }
        loyaltyConfig = newConfig;
        emit SetLoyaltyConfig(newConfig.swapThresholds, newConfig.luckyBonuses, newConfig.feeDiscounts);
    }
}
