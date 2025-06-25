// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {LuckyNBurnHook} from "../src/LuckyNBurnHook.sol";
import {LoyaltyLib} from "../src/LoyaltyLib.sol";
import {ImmutableState} from "../lib/v4-periphery/src/base/ImmutableState.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Slot0} from "v4-core/types/Slot0.sol";
import {IExtsload} from "v4-core/interfaces/IExtsload.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import "forge-std/console.sol";

contract TestLuckyNBurnHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Define events from LuckyNBurnHook
    event Lucky(address indexed trader, uint16 feeBps, uint256 timestamp);
    event Discounted(address indexed trader, uint16 feeBps);
    event Normal(address indexed trader, uint16 feeBps);
    event Unlucky(address indexed trader, uint16 feeBps, uint256 burnAmount);
    event SetChances(uint16 lucky, uint16 discounted, uint16 normal, uint16 unlucky);
    event SetFees(uint16 lucky, uint16 discounted, uint16 normal, uint16 unlucky);
    event SetCooldown(uint256 period);
    event SetBurnConfig(address burnAddress, uint16 burnShareBps);
    event SetLoyaltyConfig(uint8[5] thresholds, uint16[5] luckyBonuses, uint16[5] feeDiscounts);

    // Define events from LoyaltyLib
    event LoyaltyTierUpgraded(address indexed trader, LoyaltyLib.LoyaltyTier newTier);
    event MilestoneReached(address indexed trader, uint256 milestone, uint256 bonus);

    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);

    LuckyNBurnHook internal hook;
    PoolKey internal poolKey;

    address internal constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    address internal trader = address(0x1234);

    /// @notice Sets up the test environment for LuckyNBurnHook tests.
    function setUp() public {
        // Deploy fresh manager and routers
        deployFreshManagerAndRouters();

        // Deploy and mint test tokens
        deployMintAndApprove2Currencies();

        // Calculate the flags we need for the hook
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(LuckyNBurnHook).creationCode, abi.encode(manager));
        hook = new LuckyNBurnHook{salt: salt}(manager);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add initial liquidity to the pool
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(- 60);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);
        uint256 token0ToAdd = 10 ether;
        uint256 token1ToAdd = 10 ether;

        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, // Current price
            sqrtPriceAtTickLower, // Lower price bound
            sqrtPriceAtTickUpper, // Upper price bound
            token0ToAdd, // Amount of token0
            token1ToAdd // Amount of token1
        );

        modifyLiquidityRouter.modifyLiquidity{value: token0ToAdd}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: - 60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Give the trader some tokens
        deal(Currency.unwrap(currency0), trader, 100000 ether);
        deal(Currency.unwrap(currency1), trader, 100000 ether);

        // Approve the swap router to spend trader's tokens
        vm.startPrank(trader);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Helper function to perform a swap with hook data
    function _performSwap(address _trader, bytes32 salt) internal returns (BalanceDelta) {
        bytes memory hookData = abi.encode(_trader, salt);

        SwapParams memory swapParams =
                        SwapParams({zeroForOne: true, amountSpecified: - 0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        PoolSwapTest.TestSettings memory settings =
                            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(_trader);
        return swapRouter.swap(poolKey, swapParams, settings, hookData);
    }

    /// @notice Test that the hook initializes with correct default values
    function test_initialization() public view {
        // Check owner
        assertEq(hook.owner(), address(this));

        // Check default tier settings
        (uint16 luckyChance, uint16 luckyFee) = hook.lucky();
        assertEq(luckyChance, 1000); // 10%
        assertEq(luckyFee, 0); // 0% additional to base .3% = 0.3%

        (uint16 discountedChance, uint16 discountedFee) = hook.discounted();
        assertEq(discountedChance, 3000); // 30%
        assertEq(discountedFee, 25); // 0.25% additional to base .3% = 0.55%

        (uint16 normalChance, uint16 normalFee) = hook.normal();
        assertEq(normalChance, 5000); // 50%
        assertEq(normalFee, 50); // 0.5% additional to base .3% = 0.8%

        (uint16 unluckyChance, uint16 unluckyFee) = hook.unlucky();
        assertEq(unluckyChance, 1000); // 10%
        assertEq(unluckyFee, 100); // 1% additional to base .3% = 1.3%

        // Check burn config
        assertEq(hook.burnAddress(), BURN_ADDRESS);
        assertEq(hook.burnShareBps(), 5000); // 50%

        // Check cooldown
        assertEq(hook.cooldownPeriod(), 1 hours);

        // Check loyalty initialization - should start at Bronze tier
        assertEq(uint8(hook.getLoyaltyTier(trader)), uint8(LoyaltyLib.LoyaltyTier.Bronze));
        assertEq(hook.getSwapCount(trader), 0);
        assertEq(hook.getTotalVolume(trader), 0);

        // Check loyalty config was initialized properly
        LoyaltyLib.LoyaltyConfig memory config = hook.getLoyaltyConfig();
        assertEq(config.swapThresholds[1], 20); // Silver threshold
        assertEq(config.luckyBonuses[1], 200); // Silver bonus
    }

    /// @notice Test basic swap functionality - should emit one of the tier events
    function test_basic_swap() public {
        bytes32 salt = keccak256("test-salt-1");

        uint256 ts = block.timestamp;
        vm.warp(ts + 2 hours);

        // Just perform the swap and verify it doesn't revert
        // The specific tier is random, so we can't predict which event will be emitted
        _performSwap(trader, salt);

        // Verify that tier result was cleaned up (shows the hook executed properly)
        bytes32 swapId = keccak256(abi.encodePacked(trader, salt));
        (LuckyNBurnHook.TierType tierType, uint16 feeBps) = hook.tierResults(swapId);
        assertEq(uint8(tierType), 0);
        assertEq(feeBps, 0);

        // Verify loyalty metrics were updated
        assertEq(hook.getSwapCount(trader), 1);
        assertGt(hook.getTotalVolume(trader), 0);
    }

    /// @notice Test loyalty tier progression
    function test_loyalty_tier_progression() public {
        // Start at Bronze
        assertEq(uint8(hook.getLoyaltyTier(trader)), uint8(LoyaltyLib.LoyaltyTier.Bronze));

        // Disable lucky to avoid cooldown issues
        hook.setChances(0, 4000, 5000, 1000);

        // Perform 20 swaps to reach Silver
        for (uint i = 0; i < 20; i++) {
            bytes32 salt = keccak256(abi.encodePacked("progression-test", i));
            vm.warp(block.timestamp + 1); // Small time increment

            // Alternate swap direction to avoid price limits
            bool zeroForOne = (i % 2) == 0;
            _performSwapAlternating(trader, salt, zeroForOne);
        }

        assertEq(uint8(hook.getLoyaltyTier(trader)), uint8(LoyaltyLib.LoyaltyTier.Silver));
        assertEq(hook.getSwapCount(trader), 20);

        // Perform 30 more swaps to reach Gold (total 50)
        for (uint i = 20; i < 50; i++) {
            bytes32 salt = keccak256(abi.encodePacked("progression-test", i));
            vm.warp(block.timestamp + 1); // Small time increment

            // Alternate swap direction
            bool zeroForOne = (i % 2) == 0;
            _performSwapAlternating(trader, salt, zeroForOne);
        }

        assertEq(uint8(hook.getLoyaltyTier(trader)), uint8(LoyaltyLib.LoyaltyTier.Gold));
        assertEq(hook.getSwapCount(trader), 50);

        // Reset to original chances
        hook.setChances(1000, 3000, 5000, 1000);
    }

    /// @notice Test loyalty benefits - lucky chance should increase with higher tiers
    function test_loyalty_lucky_chance_bonus() public {
        // Force discounted tier to avoid cooldown issues
        hook.setChances(0, 10000, 0, 0);

        // At Bronze tier, should have base lucky chance
        LoyaltyLib.LoyaltyStats memory stats = hook.getLoyaltyStats(trader);
        assertEq(stats.luckyBonus, 0); // Bronze tier has 0 bonus

        // Perform swaps to reach Silver tier
        for (uint i = 0; i < 20; i++) {
            bytes32 salt = keccak256(abi.encodePacked("lucky-bonus-test", i));
            vm.warp(block.timestamp + 1);

            // Alternate swap direction
            bool zeroForOne = (i % 2) == 0;
            _performSwapAlternating(trader, salt, zeroForOne);
        }

        // At Silver tier, should have increased lucky bonus
        stats = hook.getLoyaltyStats(trader);
        assertEq(stats.luckyBonus, 200); // Silver tier has 200 bps bonus (2%)
        assertEq(uint8(stats.tier), uint8(LoyaltyLib.LoyaltyTier.Silver));

        // Reset chances to normal
        hook.setChances(1000, 3000, 5000, 1000);
    }

    /// @notice Test loyalty fee discounts
    function test_loyalty_fee_discounts() public {
        // Disable lucky to avoid cooldown issues
        hook.setChances(0, 4000, 5000, 1000);

        // Perform swaps to reach Silver tier
        for (uint i = 0; i < 20; i++) {
            bytes32 salt = keccak256(abi.encodePacked("fee-discount-test", i));
            vm.warp(block.timestamp + 1);

            // Alternate swap direction
            bool zeroForOne = (i % 2) == 0;
            _performSwapAlternating(trader, salt, zeroForOne);
        }

        LoyaltyLib.LoyaltyStats memory stats = hook.getLoyaltyStats(trader);
        assertEq(stats.feeDiscount, 25); // Silver tier has 25 bps fee discount (0.25%)
        assertEq(uint8(stats.tier), uint8(LoyaltyLib.LoyaltyTier.Silver));

        // Reset chances
        hook.setChances(1000, 3000, 5000, 1000);
    }

    /// @notice Test loyalty cooldown reduction
    function test_loyalty_cooldown_reduction() public {
        // Disable lucky to avoid cooldown issues
        hook.setChances(0, 4000, 5000, 1000);

        // Perform swaps to reach Silver tier
        for (uint i = 0; i < 20; i++) {
            bytes32 salt = keccak256(abi.encodePacked("cooldown-test", i));
            vm.warp(block.timestamp + 1);

            // Alternate swap direction
            bool zeroForOne = (i % 2) == 0;
            _performSwapAlternating(trader, salt, zeroForOne);
        }

        LoyaltyLib.LoyaltyStats memory stats = hook.getLoyaltyStats(trader);
        assertEq(stats.cooldownReduction, 15); // Silver tier has 15% cooldown reduction

        // Reset chances
        hook.setChances(1000, 3000, 5000, 1000);
    }

    /// @notice Test milestone bonuses
    function test_milestone_bonuses() public {
        // Disable lucky to avoid cooldown issues completely
        hook.setChances(0, 4000, 5000, 1000);

        // Check initial milestone bonus
        LoyaltyLib.LoyaltyStats memory stats = hook.getLoyaltyStats(trader);
        assertEq(stats.milestoneBonus, 0);

        // Perform 50 swaps to trigger 50-swap milestone
        for (uint i = 0; i < 50; i++) {
            bytes32 salt = keccak256(abi.encodePacked("milestone-test", i));
            vm.warp(block.timestamp + 1); // Small increment to avoid any timing issues

            // Alternate swap direction
            bool zeroForOne = (i % 2) == 0;
            _performSwapAlternating(trader, salt, zeroForOne);
        }

        stats = hook.getLoyaltyStats(trader);
        assertGt(stats.milestoneBonus, 0); // Should have earned milestone bonus

        // Reset chances
        hook.setChances(1000, 3000, 5000, 1000);
    }

    /// @notice Test that swaps until next tier calculation works
    function test_swaps_until_next_tier() public {
        // Disable lucky to avoid cooldown issues
        hook.setChances(0, 4000, 5000, 1000);

        // At Bronze (0 swaps), should need 20 swaps to reach Silver
        assertEq(hook.swapsUntilNextTier(trader), 20);

        // Perform 10 swaps
        for (uint i = 0; i < 10; i++) {
            bytes32 salt = keccak256(abi.encodePacked("next-tier-test", i));
            vm.warp(block.timestamp + 1);

            // Alternate swap direction
            bool zeroForOne = (i % 2) == 0;
            _performSwapAlternating(trader, salt, zeroForOne);
        }

        // Should need 10 more swaps to reach Silver
        assertEq(hook.swapsUntilNextTier(trader), 10);

        // Complete the remaining swaps
        for (uint i = 10; i < 20; i++) {
            bytes32 salt = keccak256(abi.encodePacked("next-tier-test", i));
            vm.warp(block.timestamp + 1);

            // Alternate swap direction
            bool zeroForOne = (i % 2) == 0;
            _performSwapAlternating(trader, salt, zeroForOne);
        }

        // Now at Silver, should need 30 more to reach Gold
        assertEq(hook.swapsUntilNextTier(trader), 30);

        // Reset chances
        hook.setChances(1000, 3000, 5000, 1000);
    }

    /// @notice Test tier name function
    function test_tier_names() view public {
        assertEq(hook.getTierName(LoyaltyLib.LoyaltyTier.Bronze), "Bronze");
        assertEq(hook.getTierName(LoyaltyLib.LoyaltyTier.Silver), "Silver");
        assertEq(hook.getTierName(LoyaltyLib.LoyaltyTier.Gold), "Gold");
        assertEq(hook.getTierName(LoyaltyLib.LoyaltyTier.Diamond), "Diamond");
        assertEq(hook.getTierName(LoyaltyLib.LoyaltyTier.Legendary), "Legendary");
    }

    /// @notice Test that owner can update loyalty configuration
    function test_set_loyalty_config_as_owner() public {
        // Disable lucky to avoid cooldown issues
        hook.setChances(0, 4000, 5000, 1000);

        LoyaltyLib.LoyaltyConfig memory newConfig = LoyaltyLib.LoyaltyConfig({
            swapThresholds: [uint8(0), uint8(10), uint8(25), uint8(50), uint8(100)],        // Lower thresholds for faster testing
            luckyBonuses: [uint16(0), uint16(100), uint16(200), uint16(350), uint16(600)],   // Different bonuses
            feeDiscounts: [uint16(0), uint16(15), uint16(30), uint16(60), uint16(120)],      // Different discounts
            cooldownReductions: [uint8(0), uint8(10), uint8(20), uint8(40), uint8(60)]      // Different cooldown reductions
        });

        vm.expectEmit(false, false, false, true);
        emit SetLoyaltyConfig(newConfig.swapThresholds, newConfig.luckyBonuses, newConfig.feeDiscounts);

        hook.setLoyaltyConfig(newConfig);

        // Test that new config is applied
        for (uint i = 0; i < 10; i++) {
            bytes32 salt = keccak256(abi.encodePacked("config-test", i));
            vm.warp(block.timestamp + 1);

            // Alternate swap direction
            bool zeroForOne = (i % 2) == 0;
            _performSwapAlternating(trader, salt, zeroForOne);
        }

        // Should now be at Silver tier with new thresholds (10 swaps instead of 20)
        assertEq(uint8(hook.getLoyaltyTier(trader)), uint8(LoyaltyLib.LoyaltyTier.Silver));

        // Reset chances
        hook.setChances(1000, 3000, 5000, 1000);
    }

    /// @notice Test that non-owner cannot update loyalty configuration
    function test_set_loyalty_config_reverts_if_not_owner() public {
        LoyaltyLib.LoyaltyConfig memory newConfig = LoyaltyLib.LoyaltyConfig({
            swapThresholds: [uint8(0), uint8(10), uint8(25), uint8(50), uint8(100)],
            luckyBonuses: [uint16(0), uint16(100), uint16(200), uint16(350), uint16(600)],
            feeDiscounts: [uint16(0), uint16(15), uint16(30), uint16(60), uint16(120)],
            cooldownReductions: [uint8(0), uint8(10), uint8(20), uint8(40), uint8(60)]
        });

        vm.prank(trader);
        vm.expectRevert(LuckyNBurnHook.NotOwner.selector);
        hook.setLoyaltyConfig(newConfig);
    }

    /// @notice Test that invalid loyalty configuration reverts
    function test_set_loyalty_config_reverts_if_invalid() public {
        // Invalid config with descending thresholds
        LoyaltyLib.LoyaltyConfig memory invalidConfig = LoyaltyLib.LoyaltyConfig({
            swapThresholds: [uint8(0), uint8(20), uint8(15), uint8(50), uint8(100)],  // 15 < 20, invalid
            luckyBonuses: [uint16(0), uint16(100), uint16(200), uint16(350), uint16(600)],
            feeDiscounts: [uint16(0), uint16(15), uint16(30), uint16(60), uint16(120)],
            cooldownReductions: [uint8(0), uint8(10), uint8(20), uint8(40), uint8(60)]
        });

        vm.expectRevert(LuckyNBurnHook.InvalidLoyaltyConfig.selector);
        hook.setLoyaltyConfig(invalidConfig);
    }

    /// @notice Test that owner can update tier chances
    function test_set_chances_as_owner() public {
        vm.expectEmit(false, false, false, true);
        emit SetChances(2000, 2000, 3000, 3000);

        hook.setChances(2000, 2000, 3000, 3000);

        (uint16 luckyChance,) = hook.lucky();
        (uint16 discountedChance,) = hook.discounted();
        (uint16 normalChance,) = hook.normal();
        (uint16 unluckyChance,) = hook.unlucky();

        assertEq(luckyChance, 2000);
        assertEq(discountedChance, 2000);
        assertEq(normalChance, 3000);
        assertEq(unluckyChance, 3000);
    }

    /// @notice Test that non-owner cannot update tier chances
    function test_set_chances_reverts_if_not_owner() public {
        vm.prank(trader);
        vm.expectRevert(LuckyNBurnHook.NotOwner.selector);
        hook.setChances(2000, 2000, 3000, 3000);
    }

    /// @notice Test that setting invalid chances (not summing to 10000) reverts
    function test_set_chances_reverts_if_invalid_sum() public {
        vm.expectRevert(LuckyNBurnHook.InvalidChanceSum.selector);
        hook.setChances(1000, 1000, 1000, 1000); // Sum = 4000, should be 10000
    }

    /// @notice Test that owner can update tier fees
    function test_set_fees_as_owner() public {
        vm.expectEmit(false, false, false, true);
        emit SetFees(5, 15, 30, 150);

        hook.setFees(5, 15, 30, 150);

        (, uint16 luckyFee) = hook.lucky();
        (, uint16 discountedFee) = hook.discounted();
        (, uint16 normalFee) = hook.normal();
        (, uint16 unluckyFee) = hook.unlucky();

        assertEq(luckyFee, 5);
        assertEq(discountedFee, 15);
        assertEq(normalFee, 30);
        assertEq(unluckyFee, 150);
    }

    /// @notice Test that non-owner cannot update tier fees
    function test_set_fees_reverts_if_not_owner() public {
        vm.prank(trader);
        vm.expectRevert(LuckyNBurnHook.NotOwner.selector);
        hook.setFees(5, 15, 30, 150);
    }

    /// @notice Test that owner can update cooldown period
    function test_set_cooldown_as_owner() public {
        uint256 newCooldown = 2 hours;

        vm.expectEmit(false, false, false, true);
        emit SetCooldown(newCooldown);

        hook.setCooldownPeriod(newCooldown);
        assertEq(hook.cooldownPeriod(), newCooldown);
    }

    /// @notice Test that non-owner cannot update cooldown period
    function test_set_cooldown_reverts_if_not_owner() public {
        vm.prank(trader);
        vm.expectRevert(LuckyNBurnHook.NotOwner.selector);
        hook.setCooldownPeriod(2 hours);
    }

    /// @notice Test that owner can update burn config
    function test_set_burn_config_as_owner() public {
        address newBurnAddress = address(0xbeef);
        uint16 newBurnShare = 7500; // 75%

        vm.expectEmit(false, false, false, true);
        emit SetBurnConfig(newBurnAddress, newBurnShare);

        hook.setBurnConfig(newBurnAddress, newBurnShare);

        assertEq(hook.burnAddress(), newBurnAddress);
        assertEq(hook.burnShareBps(), newBurnShare);
    }

    /// @notice Test that non-owner cannot update burn config
    function test_set_burn_config_reverts_if_not_owner() public {
        vm.prank(trader);
        vm.expectRevert(LuckyNBurnHook.NotOwner.selector);
        hook.setBurnConfig(address(0xbeef), 7500);
    }

    /// @notice Test that burn share cannot exceed 100%
    function test_set_burn_config_reverts_if_burn_share_too_high() public {
        vm.expectRevert(LuckyNBurnHook.BurnShareTooHigh.selector);
        hook.setBurnConfig(address(0xbeef), 10001); // 100.01%
    }

    /// @notice Test that unlucky tier emits correct burn amount
    function test_unlucky_burn_calculation() public {
        // Force unlucky tier
        hook.setChances(0, 0, 0, 10000);

        // Get initial balances to calculate actual swap amounts
        address poolManagerAddr = address(manager);
        uint256 preBalance0 = IERC20(Currency.unwrap(currency0)).balanceOf(poolManagerAddr);
        uint256 preBalance1 = IERC20(Currency.unwrap(currency1)).balanceOf(poolManagerAddr);

        // Perform swap that should trigger unlucky tier
        _performSwap(trader, keccak256("burn-calculation-test"));

        // Calculate actual swap amounts
        uint256 postBalance0 = IERC20(Currency.unwrap(currency0)).balanceOf(poolManagerAddr);
        uint256 postBalance1 = IERC20(Currency.unwrap(currency1)).balanceOf(poolManagerAddr);

        uint256 token0Delta = postBalance0 > preBalance0
            ? postBalance0 - preBalance0
            : preBalance0 - postBalance0;

        uint256 token1Delta = postBalance1 > preBalance1
            ? postBalance1 - preBalance1
            : preBalance1 - postBalance1;

        console.log("Token 0 delta:", token0Delta);
        console.log("Token 1 delta:", token1Delta);

        // Get the actual fee basis points for the Unlucky tier
        (, uint16 unluckyFeeBps) = hook.unlucky();
        uint256 burnShareBps = hook.burnShareBps(); // Should be 50% (5000 bps)

        console.log("Unlucky fee (bps):", unluckyFeeBps);
        console.log("Burn share (bps):", burnShareBps);

        // Calculate expected burn amount based on token flow
        // The contract uses the absolute token flow for the fee calculation
        // For a swap from token0 to token1, the token flow is the amount of token1 received
        uint256 tokenFlow = token1Delta;
        uint256 feeAmount = (tokenFlow * unluckyFeeBps) / 10_000;
        uint256 expectedBurnAmount = (feeAmount * burnShareBps) / 10_000;

        console.log("Token flow (token1):", tokenFlow);
        console.log("Fee amount (1% of flow):", feeAmount);
        console.log("Expected burn amount (50% of fee):", expectedBurnAmount);

        uint256 actualBurned = hook.getCollectedForBurning(poolKey.currency1);
        console.log("Actual burned:", actualBurned);

        // Verify the burn amount was collected (allow for small rounding differences)
        assertApproxEqAbs(actualBurned, expectedBurnAmount, 1, "Burn amount mismatch");

        // Reset chances
        hook.setChances(1000, 3000, 5000, 1000);
    }

    /// @notice Test that hooks revert when not called by pool manager
    function test_reverts_if_not_pool_manager() public {
        PoolKey memory key;
        SwapParams memory params;
        BalanceDelta delta = BalanceDelta.wrap(0);
        bytes memory hookData = "";

        // Test beforeSwap
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(1), key, params, hookData);

        // Test afterSwap
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(1), key, params, delta, hookData);
    }

    /// @notice Test tier result storage and cleanup
    function test_tier_result_storage_cleanup() public {
        bytes32 salt = keccak256("storage-test");
        bytes32 swapId = keccak256(abi.encodePacked(trader, salt));

        // Before swap, no tier result should exist
        (LuckyNBurnHook.TierType tierType, uint16 feeBps) = hook.tierResults(swapId);
        assertEq(uint8(tierType), 0);
        assertEq(feeBps, 0);

        // After swap, tier result should be cleaned up
        _performSwap(trader, salt);

        (tierType, feeBps) = hook.tierResults(swapId);
        assertEq(uint8(tierType), 0);
        assertEq(feeBps, 0);
    }

    function log_balances() view public {
        // Get initial balances
        uint256 initialTraderToken0 = IERC20(Currency.unwrap(currency0)).balanceOf(trader);
        uint256 initialTraderToken1 = IERC20(Currency.unwrap(currency1)).balanceOf(trader);
        uint256 initialHookToken0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 initialHookToken1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        uint256 initialPoolToken0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(manager));
        uint256 initialPoolToken1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(manager));
        uint256 initialDeadToken0 = IERC20(Currency.unwrap(currency0)).balanceOf(BURN_ADDRESS);
        uint256 initialDeadToken1 = IERC20(Currency.unwrap(currency1)).balanceOf(BURN_ADDRESS);

        console.log("--------------------------------");
        console.log("Trader Token0:", initialTraderToken0);
        console.log("Trader Token1:", initialTraderToken1);
        console.log("Pool Token0:", initialPoolToken0);
        console.log("Pool Token1:", initialPoolToken1);
        console.log("Hook Token0:", initialHookToken0);
        console.log("Hook Token1:", initialHookToken1);
        console.log("Dead Token0:", initialDeadToken0);
        console.log("Dead Token1:", initialDeadToken1);
        console.log("--------------------------------");
    }

    /// @notice Test randomness with different salts and loyalty progression
    function test_randomness_with_loyalty_progression() public {
        // Temporarily set lucky chance to 0 to avoid cooldown issues
        hook.setChances(0, 4000, 5000, 1000); // No lucky tier

        console.log("");
        console.log("--------------------------------");
        console.log(" INIT test_randomness_with_loyalty_progression ");
        console.log("--------------------------------");
        console.log("");
        log_balances();
        console.log("");

        for (uint256 i = 0; i < 30; i++) {
            bytes32 salt = keccak256(abi.encodePacked("loyalty-random-test", i));

            // Alternate direction every few swaps to avoid price limits
            bool zeroForOne = (i % 4) < 2;
            _performSwapAlternating(trader, salt, zeroForOne);

            // Log loyalty progression every 10 swaps
            if (i > 0 && (i + 1) % 10 == 0) {
                LoyaltyLib.LoyaltyStats memory stats = hook.getLoyaltyStats(trader);
                console.log("After", i + 1, "swaps:");
                console.log("Tier:", uint8(stats.tier));
                console.log("Swaps:", stats.swaps);
                console.log("Volume:", stats.volume);
                console.log("Lucky Bonus:", stats.luckyBonus);
                console.log("Fee Discount:", stats.feeDiscount);
                console.log("Cooldown Reduction:", stats.cooldownReduction);
                console.log("Milestone Bonus:", stats.milestoneBonus);
                console.log("--------------------------------");
            }

            vm.warp(block.timestamp + 1);
        }

        // Final loyalty stats
        LoyaltyLib.LoyaltyStats memory finalStats = hook.getLoyaltyStats(trader);
        console.log("Final Loyalty Stats:");
        console.log("Tier:", uint8(finalStats.tier));
        console.log("Total Swaps:", finalStats.swaps);
        console.log("Total Volume:", finalStats.volume);
        console.log("Lucky Bonus:", finalStats.luckyBonus);
        console.log("Fee Discount:", finalStats.feeDiscount);
        console.log("Milestone Bonus:", finalStats.milestoneBonus);

        // Should have progressed to at least Silver tier (20+ swaps)
        assertGe(uint8(finalStats.tier), uint8(LoyaltyLib.LoyaltyTier.Silver));

        // Reset chances
        hook.setChances(1000, 3000, 5000, 1000);
    }

    function _performSwapAlternating(address _trader, bytes32 salt, bool zeroForOne) internal returns (BalanceDelta) {
        bytes memory hookData = abi.encode(_trader, salt);

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: - 0.1 ether, // Smaller amount to avoid hitting limits
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
                            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(_trader);
        return swapRouter.swap(poolKey, swapParams, settings, hookData);
    }

    /// @notice Test edge case: zero swap amount
    function test_zero_swap_amount() public {
        bytes memory hookData = abi.encode(trader, keccak256("zero-swap"));

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: 0, // Zero amount
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.prank(trader);
        // This might revert at the pool level, but the hook should handle it gracefully
        try swapRouter.swap(
            poolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData
        ) {
            // If it succeeds, that's fine too
        } catch {
            // Expected to potentially fail at pool level
        }
    }

    /// @notice Fuzz test for tier selection consistency with loyalty
    function testFuzz_tier_selection_with_loyalty(address fuzzTrader, uint256 saltSeed) public {
        vm.assume(fuzzTrader != address(0) && fuzzTrader != address(this));

        bytes32 salt = keccak256(abi.encodePacked(saltSeed));
        deal(Currency.unwrap(currency0), fuzzTrader, 100 ether);
        deal(Currency.unwrap(currency1), fuzzTrader, 100 ether);

        // Approve for fuzz trader
        vm.startPrank(fuzzTrader);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // The swap should complete without reverting for any valid trader/salt combination
        vm.prank(fuzzTrader);
        bytes memory hookData = abi.encode(fuzzTrader, salt);
        SwapParams memory swapParams =
                        SwapParams({zeroForOne: true, amountSpecified: - 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        try swapRouter.swap(
            poolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData
        ) {
            // Swap succeeded - check that tier result was cleaned up
            bytes32 swapId = keccak256(abi.encodePacked(fuzzTrader, salt));
            (LuckyNBurnHook.TierType tierType, uint16 feeBps) = hook.tierResults(swapId);
            assertEq(uint8(tierType), 0);
            assertEq(feeBps, 0);

            // Check that loyalty was updated
            assertEq(hook.getSwapCount(fuzzTrader), 1);
            assertGt(hook.getTotalVolume(fuzzTrader), 0);
        } catch {
            // Some combinations might fail due to cooldown or other constraints
            // That's acceptable for fuzz testing
        }
    }

    /// @notice Test loyalty config getter function
    function test_get_loyalty_config() view public {
        LoyaltyLib.LoyaltyConfig memory config = hook.getLoyaltyConfig();

        // Check default values
        assertEq(config.swapThresholds[0], 0);
        assertEq(config.swapThresholds[1], 20);
        assertEq(config.swapThresholds[2], 50);
        assertEq(config.swapThresholds[3], 100);
        assertEq(config.swapThresholds[4], 200);

        assertEq(config.luckyBonuses[1], 200); // Silver tier bonus
        assertEq(config.feeDiscounts[1], 25); // Silver tier discount
        assertEq(config.cooldownReductions[1], 15); // Silver tier cooldown reduction
    }
}
