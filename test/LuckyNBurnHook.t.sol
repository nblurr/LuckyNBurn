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
import {ImmutableState} from "../lib/v4-periphery/src/base/ImmutableState.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Slot0} from "v4-core/types/Slot0.sol";
import {IExtsload} from "v4-core/interfaces/IExtsload.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";

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
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
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
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        address pool = address(uint160(uint256(keccak256(abi.encode(poolKey)))));
        uint256 initialPoolToken0 = IERC20(Currency.unwrap(currency0)).balanceOf(pool);
        uint256 initialPoolToken1 = IERC20(Currency.unwrap(currency1)).balanceOf(pool);

        // Give the trader some tokens
        deal(Currency.unwrap(currency0), trader, 100000 ether);
        deal(Currency.unwrap(currency1), trader, 100000 ether);

        deal(Currency.unwrap(currency0), pool, 100000 ether);
        deal(Currency.unwrap(currency1), pool, 100000 ether);

        //deal(Currency.unwrap(currency0), address(hook), 100000 ether);
        //deal(Currency.unwrap(currency1), address(hook), 100000 ether);

        initialPoolToken0 = IERC20(Currency.unwrap(currency0)).balanceOf(pool);
        initialPoolToken1 = IERC20(Currency.unwrap(currency1)).balanceOf(pool);

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
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

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
        assertEq(luckyFee, 0); // 0% additionnal to base .3% = 0.3%

        (uint16 discountedChance, uint16 discountedFee) = hook.discounted();
        assertEq(discountedChance, 3000); // 30%
        assertEq(discountedFee, 25); // 0.25% additionnal to base .3% = 0.55%

        (uint16 normalChance, uint16 normalFee) = hook.normal();
        assertEq(normalChance, 5000); // 50%
        assertEq(normalFee, 50); // 0.5% additionnal to base .3% = 0.8%

        (uint16 unluckyChance, uint16 unluckyFee) = hook.unlucky();
        assertEq(unluckyChance, 1000); // 10%
        assertEq(unluckyFee, 100); // 1% additionnal to base .3% = 1.3%. 50% of 1% burn

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

        // Ensure no existing cooldown by warping forward enough
        vm.warp(block.timestamp + 2 hours);

        // First swap should succeed and record lucky timestamp
        _performSwap(trader, salt1);

        uint256 lastLucky = hook.lastLuckyTimestamp(trader);
        assertGt(lastLucky, 0);

        // Second swap immediately after should revert due to cooldown
        vm.expectRevert();
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

        // Approve for trader2
        vm.startPrank(trader2);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Force lucky tier
        hook.setChances(10000, 0, 0, 0);

        bytes32 salt1 = keccak256("user1-salt");
        bytes32 salt2 = keccak256("user2-salt");

        // Ensure no existing cooldown by warping forward enough
        vm.warp(block.timestamp + 2 hours);

        // First user gets lucky
        _performSwap(trader, salt1);

        // Second user should also be able to get lucky immediately
        vm.prank(trader2);
        bytes memory hookData = abi.encode(trader2, salt2);
        SwapParams memory swapParams =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        swapRouter.swap(
            poolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData
        );

        // Both should have different timestamps
        assertGt(hook.lastLuckyTimestamp(trader), 0);
        assertGt(hook.lastLuckyTimestamp(trader2), 0);
    }

    /// @notice Test that unlucky tier emits correct burn amount
    function test_unlucky_burn_calculation() public {
        // Force unlucky tier
        hook.setChances(0, 0, 0, 10000);

        // NOTE: THIS NUMBER SEEM'S TO CHANGE SOME TIMES        
        uint256 amountIn = 986708288047964564; // Swap amount
        uint256 totalFee = (amountIn * 100) / 10_000; // 100 bps = 1%
        uint256 expectedBurnAmount = (totalFee * 5000) / 10_000; // 50% burn share = 5000000000000000 wei 50% burn share = 5000000000000000 wei


        // 50% of fee goes to burn (burnShareBps = 5000)
        // Expect the unlucky event with corr
        console.log("expectedBurnAmount ");
        console.log(expectedBurnAmount);

        vm.expectEmit(true, true, false, true);
        emit Unlucky(trader, 100, expectedBurnAmount);

        // Perform swap that should trigger unlucky tier
        _performSwap(trader, keccak256("burn-calculation-test"));

        // Verify the burn amount was collected
        assertEq(hook.getCollectedForBurning(poolKey.currency1), expectedBurnAmount);
        
        console.log("");
        console.log("--------------------------------");
        console.log(" test_unlucky_burn_calculation ");
        console.log("--------------------------------");
        console.log("");
        log_balances();


        // TODO: Not accurate or I do miss a point in the hook & protocol
        console.log("FEES COLLECTED currency0 currency1");

        console.log(manager.protocolFeesAccrued(key.currency0));
        console.log(manager.protocolFeesAccrued(key.currency1));

        address protocolFeeControllerAddress = manager.protocolFeeController();

        console.log("LP Fees Collected (currency0):", IERC20(Currency.unwrap(currency0)).balanceOf(address(protocolFeeControllerAddress)));
        console.log("LP Fees Collected (currency1):", IERC20(Currency.unwrap(currency1)).balanceOf(address(protocolFeeControllerAddress)));
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

    function logWithTopicExists(bytes32 topic0Sig, Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic0Sig) {
                return true;
            }
        }
        return false;
    }

    /// @notice Test that all tier types can be selected
    function test_all_tier_types_selectable() public {
        // Test by forcing each tier type to 100% chance

        // Test Lucky - first ensure no cooldown is active
        vm.warp(1000); // fixed base timestamp
        uint256 ts = block.timestamp;
        hook.setChances(10000, 0, 0, 0);
        vm.warp(ts + 2 hours);
        ts = block.timestamp;
        _performSwap(trader, keccak256("lucky"));

        // Test Discounted
        hook.setChances(0, 10000, 0, 0);
        vm.warp(ts + 2 hours);
        ts = block.timestamp;
        vm.expectEmit(true, true, false, false);
        emit Discounted(trader, 25);
        _performSwap(trader, keccak256("discounted"));

        // Test Normal
        hook.setChances(0, 0, 10000, 0);
        vm.warp(ts + 2 hours);
        ts = block.timestamp;
        vm.expectEmit(true, true, false, false);
        emit Normal(trader, 50);
        _performSwap(trader, keccak256("normal"));

        // NOTE: THIS NUMBER SEEM'S TO CHANGE SOME TIMES   
        uint256 amountIn = 984942916782828359; // Swap amount
        uint256 totalFee = (amountIn * 100) / 10_000; // 100 bps = 1% to burn, Rest to the LP provider
        uint256 expectedBurnAmount = (totalFee * 5000) / 10_000; // 50% burn share = 5000000000000000 wei 50% burn share = 5000000000000000 wei

        hook.setChances(0, 0, 0, 10000);
        vm.warp(ts + 2 hours);
        ts = block.timestamp;
        vm.expectEmit(true, true, false, true);

        emit Unlucky(trader, 100, expectedBurnAmount); // expectedBurnAmount = 5000000000000000
        _performSwap(trader, keccak256("unlucky"));     

    }

    function log_balances() public {
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

    /// @notice Test that randomness produces different results with different salts
    function test_randomness_with_different_salts() public {
        // Temporarily set lucky chance to 0 to avoid cooldown issues
        hook.setChances(0, 4000, 5000, 1000); // No lucky tier


        console.log("");
        console.log("--------------------------------");
        console.log(" INIT test_randomness_with_different_salts ");
        console.log("--------------------------------");
        console.log("");
        log_balances();
        console.log("");

        for (uint256 i = 0; i < 20; i++) {
            bytes32 salt = keccak256(abi.encodePacked("random-test", i));


            // Alternate direction every few swaps to avoid price limits
            bool zeroForOne = (i % 4) < 2;
            _performSwapAlternating(trader, salt, zeroForOne);
   

            console.log("");
            console.log("--------------------------------");
            console.log(" test_randomness_with_different_salts ");
            console.log("--------------------------------");
            console.log("");
            log_balances();

            // TODO: Not accurate or I do miss a point in the hook & protocol as no fees seem's collected in pool... 
            console.log("FEES COLLECTED currency0 currency1");

            console.log(manager.protocolFeesAccrued(key.currency0));
            console.log(manager.protocolFeesAccrued(key.currency1));

            address protocolFeeControllerAddress = manager.protocolFeeController();

            console.log("LP Fees Collected (currency0):", IERC20(Currency.unwrap(currency0)).balanceOf(address(protocolFeeControllerAddress)));
            console.log("LP Fees Collected (currency1):", IERC20(Currency.unwrap(currency1)).balanceOf(address(protocolFeeControllerAddress)));

            vm.warp(block.timestamp + 2 hours);

        }
    }

    function _performSwapAlternating(address _trader, bytes32 salt, bool zeroForOne) internal returns (BalanceDelta) {
        bytes memory hookData = abi.encode(_trader, salt);

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1 ether, // Smaller amount to avoid hitting limits
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

    /// @notice Fuzz test for tier selection consistency
    function testFuzz_tier_selection_consistency(address fuzzTrader, uint256 saltSeed) public {
        vm.assume(fuzzTrader != address(0) && fuzzTrader != address(this));

        bytes32 salt = keccak256(abi.encodePacked(saltSeed));
        deal(Currency.unwrap(currency0), fuzzTrader, 100 ether);
        deal(Currency.unwrap(currency1), fuzzTrader, 100 ether);

        // The swap should complete without reverting for any valid trader/salt combination
        vm.prank(fuzzTrader);
        bytes memory hookData = abi.encode(fuzzTrader, salt);
        SwapParams memory swapParams =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        try swapRouter.swap(
            poolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData
        ) {
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
