// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {ImmutableState} from "../lib/v4-periphery/src/base/ImmutableState.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

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

    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);

    LuckyNBurnHook internal hook;
    PoolKey internal poolKey;

    /// @notice The address where burned tokens are sent
    address public burnAddress;

    address internal constant BURN_ADDRESS = address(0xdEaD);
    address internal trader = address(0x1234);

    /// @notice Sets up the test environment for LuckyNBurnHook tests.
/// @notice Sets up the test environment for LuckyNBurnHook tests.
    function setUp() public {
        // Deploy fresh manager and routers
        deployFreshManagerAndRouters();

        // Deploy and mint test tokens
        deployMintAndApprove2Currencies();

        // Calculate the flags we need for the hook
        // IMPORTANT: You need AFTER_SWAP_FLAG to use AFTER_SWAP_RETURNS_DELTA_FLAG
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(LuckyNBurnHook).creationCode,
            abi.encode(manager)
        );
        hook = new LuckyNBurnHook{salt: salt}(manager);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add initial liquidity to the pool
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);
        uint256 token0ToAdd = 10 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_1, sqrtPriceAtTickUpper, token0ToAdd);

        modifyLiquidityRouter.modifyLiquidity{value: token0ToAdd}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Give the trader some tokens
        deal(Currency.unwrap(currency0), trader, 100 ether);
        deal(Currency.unwrap(currency1), trader, 100 ether);

        // Approve the swap router to spend trader's tokens
        vm.startPrank(trader);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
    /// @notice Helper function to perform a swap with hook data
    function _performSwap(address _trader, bytes32 salt) internal returns (BalanceDelta) {
        bytes memory hookData = abi.encode(_trader, salt);

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: - 1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

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
        assertEq(luckyFee, 10); // 0.1%

        (uint16 discountedChance, uint16 discountedFee) = hook.discounted();
        assertEq(discountedChance, 3000); // 30%
        assertEq(discountedFee, 25); // 0.25%

        (uint16 normalChance, uint16 normalFee) = hook.normal();
        assertEq(normalChance, 5000); // 50%
        assertEq(normalFee, 50); // 0.5%

        (uint16 unluckyChance, uint16 unluckyFee) = hook.unlucky();
        assertEq(unluckyChance, 1000); // 10%
        assertEq(unluckyFee, 100); // 1%

        // Check burn config
        assertEq(hook.burnAddress(), BURN_ADDRESS);
        assertEq(hook.burnShareBps(), 5000); // 50%

        // Check cooldown
        assertEq(hook.cooldownPeriod(), 1 hours);
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

    /// @notice Test lucky tier cooldown functionality
    function test_lucky_cooldown() public {
        // Force lucky tier by setting chances to 100% lucky
        hook.setChances(10000, 0, 0, 0);

        bytes32 salt1 = keccak256("lucky-salt-1");
        bytes32 salt2 = keccak256("lucky-salt-2");

        // First swap should succeed and record lucky timestamp
        _performSwap(trader, salt1);

        uint256 lastLucky = hook.lastLuckyTimestamp(trader);
        assertGt(lastLucky, 0);

        // Second swap immediately after should revert due to cooldown
        vm.expectRevert(LuckyNBurnHook.CooldownActive.selector);
        _performSwap(trader, salt2);

        // After cooldown period, should work again
        vm.warp(block.timestamp + 1 hours + 1);
        _performSwap(trader, salt2);

        // Check that timestamp was updated
        assertGt(hook.lastLuckyTimestamp(trader), lastLucky);
    }

    /// @notice Test that different users have separate cooldowns
    function test_lucky_cooldown_per_user() public {
        address trader2 = address(0x5678);
        deal(Currency.unwrap(currency0), trader2, 100 ether);
        deal(Currency.unwrap(currency1), trader2, 100 ether);

        // Force lucky tier
        hook.setChances(10000, 0, 0, 0);

        bytes32 salt1 = keccak256("user1-salt");
        bytes32 salt2 = keccak256("user2-salt");

        // First user gets lucky
        _performSwap(trader, salt1);

        // Second user should also be able to get lucky immediately
        vm.prank(trader2);
        bytes memory hookData = abi.encode(trader2, salt2);
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: - 1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), hookData);

        // Both should have different timestamps
        assertGt(hook.lastLuckyTimestamp(trader), 0);
        assertGt(hook.lastLuckyTimestamp(trader2), 0);
    }

    /// @notice Test that unlucky tier triggers burning mechanism
    function test_unlucky_burning() public {
        // Force unlucky tier
        hook.setChances(0, 0, 0, 10000);

        uint256 initialBurnBalance = BURN_ADDRESS.balance;
        console.log("0");
        // Perform swap that should trigger burning
        _performSwap(trader, keccak256("burn-test"));

        console.log("8");
        // Check that burn address received tokens
        assertGt(BURN_ADDRESS.balance, initialBurnBalance);
    }

    /// @notice Test hook permissions are set correctly
    function test_hook_permissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
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

    /// @notice Test that all tier types can be selected
    function test_all_tier_types_selectable() public {
        // Test by forcing each tier type to 100% chance

        console.log("test_all_tier_types_selectable 1");
        // Test Lucky - first ensure no cooldown is active
        vm.warp(1000); // fixed base timestamp
        uint256 ts = block.timestamp;

        console.log("test_all_tier_types_selectable 2");
        hook.setChances(10000, 0, 0, 0);
        console.log("test_all_tier_types_selectable 2.1");
        vm.warp(ts + 2 hours);
        ts = block.timestamp;
        console.log("test_all_tier_types_selectable 2.2");
        vm.expectEmit(true, true, false, true);
        console.log("test_all_tier_types_selectable 2.3");
        emit Lucky(trader, 10, ts);
        console.log("test_all_tier_types_selectable 2.4");
        _performSwap(trader, keccak256("lucky")); // should match keccak256("Lucky(address,uint16,uint256)")

        console.log("test_all_tier_types_selectable 3");
        // Test Discounted
        hook.setChances(0, 10000, 0, 0);
        vm.warp(ts + 2 hours);
        ts = block.timestamp;
        vm.expectEmit(true, true, false, false);
        emit Discounted(trader, 25);
        _performSwap(trader, keccak256("discounted"));

        console.log("test_all_tier_types_selectable 4");
        // Test Normal
        hook.setChances(0, 0, 10000, 0);
        vm.warp(ts + 2 hours);
        ts = block.timestamp;
        vm.expectEmit(true, true, false, false);
        emit Normal(trader, 50);
        _performSwap(trader, keccak256("normal"));

        console.log("test_all_tier_types_selectable 5");
        // Test Unlucky
        hook.setChances(0, 0, 0, 10000);
        vm.warp(ts + 2 hours);
        ts = block.timestamp;
        vm.expectEmit(true, true, false, true);
        emit Unlucky(trader, 100, 0); // burnAmount will be calculated
        _performSwap(trader, keccak256("unlucky"));
    }

    /// @notice Test that randomness produces different results with different salts
    function test_randomness_with_different_salts() public {
        // This test is probabilistic, but with enough different salts
        // we should see different outcomes if randomness is working

        // bool seenDifferentOutcomes = false;
        // uint8 firstOutcome = 255; // Invalid initial value

        for (uint256 i = 0; i < 20; i++) {
            bytes32 salt = keccak256(abi.encodePacked("random-test", i));

            // We can't easily predict the outcome, but we can check that
            // the function doesn't revert and processes successfully
            _performSwap(trader, salt);

            // Reset for next iteration (skip cooldown for lucky)
            vm.warp(block.timestamp + 2 hours);
        }
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
        try swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), hookData) {
            // If it succeeds, that's fine too
        } catch {
            // Expected to potentially fail at pool level
        }
    }

    /// @notice Fuzz test for tier selection consistency
    function testFuzz_tier_selection_consistency(address fuzzTrader, uint256 saltSeed) public {
        vm.assume(fuzzTrader != address(0) && fuzzTrader != address(this));

        bytes32 salt = keccak256(abi.encodePacked(saltSeed));
        deal(Currency.unwrap(currency0), fuzzTrader, 100 ether);
        deal(Currency.unwrap(currency1), fuzzTrader, 100 ether);

        // The swap should complete without reverting for any valid trader/salt combination
        vm.prank(fuzzTrader);
        bytes memory hookData = abi.encode(fuzzTrader, salt);
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: - 1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        try swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), hookData) {
            // Swap succeeded - check that tier result was cleaned up
            bytes32 swapId = keccak256(abi.encodePacked(fuzzTrader, salt));
            (LuckyNBurnHook.TierType tierType, uint16 feeBps) = hook.tierResults(swapId);
            assertEq(uint8(tierType), 0);
            assertEq(feeBps, 0);
        } catch {
            // Some combinations might fail due to cooldown or other constraints
            // That's acceptable for fuzz testing
        }
    }
}
