// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LuckyNBurnHook
/// @notice A gamified Uniswap v4 hook that implements variable swap fees with different tiers
/// @dev This hook introduces a gamification layer to swaps with different fee tiers:
/// - Lucky: Lowest fees with cooldown period
/// - Discounted: Reduced fees
/// - Normal: Standard fees
/// - Unlucky: Highest fees with a portion collected for burning

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

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
        lucky = Tier(1000, 10); // 10% chance, 0.1% fee
        discounted = Tier(3000, 25); // 30% chance, 0.25% fee
        normal = Tier(5000, 50); // 50% chance, 0.5% fee
        unlucky = Tier(1000, 100); // 10% chance, 1% fee

        // Default burn configuration
        burnAddress = 0x000000000000000000000000000000000000dEaD; // Burn address
        burnShareBps = 5000; // 50% of unlucky fees go toward burn calculation
    }

    // -------------------------------------------------------------------
    //                          PERMISSIONS
    // -------------------------------------------------------------------

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
    //                          TIER SELECTION
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

    function logTier(TierType tier) internal view {
        if (tier == TierType.Lucky) {
            console.log("Tier: Lucky");
        } else if (tier == TierType.Discounted) {
            console.log("Tier: Discounted");
        } else if (tier == TierType.Normal) {
            console.log("Tier: Normal");
        } else if (tier == TierType.Unlucky) {
            console.log("Tier: Unlucky");
        } else {
            console.log("Tier: Unknown");
        }
    }

    // -------------------------------------------------------------------
    //                          HOOK IMPLEMENTATION
    // -------------------------------------------------------------------

    /**
     * @notice Hook called before a swap executes
     * @param hookData Encoded trader and salt for tier selection
     * @return selector The function selector for the afterSwap hook
     * @return delta The before swap delta (empty)
     * @return fee The dynamic fee for this swap
     * @dev Selects a random tier for the swap and stores the result
     */
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24)
    {
        (address trader, bytes32 salt) = abi.decode(hookData, (address, bytes32));
        uint16 roll = _getRoll(trader, salt);
        (TierType tier, uint16 feeBps) = _selectTier(roll);
        if (tier == TierType.Lucky) {
            if (block.timestamp < lastLuckyTimestamp[trader] + cooldownPeriod) {
                revert CooldownActive();
            }
        }
        tierResults[keccak256(abi.encodePacked(trader, salt))] = TierResult(tier, feeBps);

        // Return empty BeforeSwapDelta and dynamic fee
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeBps);
    }

    struct BurnInfo {
        Currency token;
        uint256 amount;
    }
    mapping(address => BurnInfo) public pendingBurn;

    /**
     * @notice Hook called after a swap executes to process fees and rewards
     * @param key The pool key
     * @param params Swap parameters
     * @param delta The balance delta from the swap
     * @param hookData Encoded trader and salt for tier lookup
     * @return selector The function selector
     * @return hookDelta The delta the hook takes (for burn amount)
     * @dev Uses return delta to collect tokens for burning per official Uniswap v4 pattern
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

        // End goal, only burn some token1 no matter the params.zeroForOne value 
        if (result.tierType == TierType.Unlucky) {

            uint256 burnAmount = 0;
 
            int256 tokenDelta = params.zeroForOne
                                ? delta.amount1()
                                : delta.amount0();

            uint256 absToken1Flow = uint256(tokenDelta > 0 ? tokenDelta : -tokenDelta);
            uint256 feeAmount = (absToken1Flow * result.feeBps) / 10_000;

            // Only burn when params.zeroForOne == true is the output token as we can't settle token1 when params.zeroForOne == false
            burnAmount = (feeAmount * burnShareBps) / 10_000;

            console.log("burnableHookAmount:");
            console.log(burnAmount);

            if (burnAmount > 0) {
                // Only the output token can be settled and set to hook delta
                Currency burnCurrency = params.zeroForOne ? key.currency1 : key.currency0;

                // Track burned amount
                collectedForBurning[burnCurrency] += burnAmount;

                // Emit burn event
                emit Unlucky(trader, result.feeBps, burnAmount);

                // Clean up
                delete tierResults[swapId];

                int128 hookDelta  = int128(int256(burnAmount));

                poolManager.take(
                    burnCurrency,
                    address(this),
                    burnAmount
                );

                // Burn by transferring to 0xdead
                IERC20(Currency.unwrap(burnCurrency)).transfer(address(0xdead), burnAmount);

                poolManager.settleFor(Currency.unwrap(burnCurrency));
                poolManager.settle();

                return (this.afterSwap.selector, hookDelta);
            }
        } else if (result.tierType == TierType.Lucky) {
            lastLuckyTimestamp[trader] = block.timestamp;
            emit Lucky(trader, 10, block.timestamp);
            //emit Lucky(trader, result.feeBps, block.timestamp);
        } else if (result.tierType == TierType.Discounted) {
            emit Discounted(trader, result.feeBps);
        } else {
            emit Normal(trader, result.feeBps);
        }

        // Clean up storage for non-Unlucky swaps or if no burn was needed
        delete tierResults[swapId];
        return (BaseHook.afterSwap.selector, 0);
    }

    function afterLock(address caller) external returns (bytes4) {
        BurnInfo memory info = pendingBurn[caller];

        if (info.amount > 0) {
            delete pendingBurn[caller];
            IERC20(Currency.unwrap(info.token)).transfer(
                address(0x000000000000000000000000000000000000dEaD),
                info.amount
            );

            poolManager.settle();
        }

        return this.afterLock.selector;
    }

    // -------------------------------------------------------------------
    //                          VIEW FUNCTIONS
    // -------------------------------------------------------------------
    function getCollectedForBurning(Currency currency) external view returns (uint256) {
           return collectedForBurning[currency];
    }

    // -------------------------------------------------------------------
    //                          BURN FUNCTIONS
    // -------------------------------------------------------------------
    /**
     * @notice Burns collected tokens by transferring them to the burn address
     * @param currency The currency to burn
     * @dev Can be called by anyone to trigger the burn

    function burnCollectedTokens(Currency currency) external {
        uint256 amount = collectedForBurning[currency];
        if (amount == 0) revert NothingToBurn();

        collectedForBurning[currency] = 0;

        // Transfer tokens to burn address
        bool success = IERC20(Currency.unwrap(currency)).transfer(burnAddress, amount);
        if (!success) revert TransferFailed();

        emit TokensBurned(currency, amount);
    }     */

    /**
     * @notice Burns collected tokens for multiple currencies in one transaction
     * @param currencies Array of currencies to burn

    function burnCollectedTokensBatch(Currency[] calldata currencies) external {
        for (uint256 i = 0; i < currencies.length; i++) {
            uint256 amount = collectedForBurning[currencies[i]];
            if (amount > 0) {
                collectedForBurning[currencies[i]] = 0;
                bool success = IERC20(Currency.unwrap(currencies[i])).transfer(burnAddress, amount);
                if (!success) revert TransferFailed();
                emit TokensBurned(currencies[i], amount);
            }
        }
    }     */

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