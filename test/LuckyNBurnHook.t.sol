// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LuckyNBurnHook, Config, Tier} from "../src/LuckyNBurnHook.sol";
import {PoolManagerTest} from "v4-core/test/PoolManagerTest.sol";
import {IUniswapV4PoolManager} from "v4-core/interfaces/IUniswapV4PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/libraries/BeforeSwapDelta.sol";

contract LuckyNBurnHookTest is PoolManagerTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LuckyNBurnHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 internal constant SWAP_AMOUNT = 1e18;
    uint256 private constant BASIS_POINTS_MAX = 10_000;

    function setUp() public override {
        super.setUp(); // Sets up manager, currencies, etc.

        // Deploy the hook
        hook = new LuckyNBurnHook(manager);

        // Define the pool
        poolKey = PoolKey({
            currency0: USDC,
            currency1: ETH,
            fee: 3000, // This fee is ignored because our hook overrides it
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Initialize the pool with the hook's default configuration
        manager.initialize(poolKey, SQRT_RATIO_1_1, new bytes(0));

        // Fund this test contract with tokens
        deal(address(USDC), address(this), 1_000_000e6);
        deal(address(ETH), address(this), 1_000e18);

        // Approve the manager to spend tokens
        USDC.approve(address(manager), type(uint256).max);
        ETH.approve(address(manager), type(uint256).max);
    }

    // --- Test Initialization ---

    function test_Initialization_UsesDefaultConfig() public {
        Config memory defaultConfig = hook.defaultConfig();
        Config memory actualConfig = hook.poolConfigs(poolId);

        assertEq(actualConfig.burnAddress, defaultConfig.burnAddress, "Default burn address mismatch");
        assertEq(actualConfig.burnShareBps, defaultConfig.burnShareBps, "Default burn share mismatch");
        for (uint i = 0; i < 4; i++) {
            assertEq(actualConfig.tiers[i].chanceBps, defaultConfig.tiers[i].chanceBps, "Default tier chance mismatch");
            assertEq(actualConfig.tiers[i].feeBps, defaultConfig.tiers[i].feeBps, "Default tier fee mismatch");
        }
    }

    function test_Initialization_WithCustomConfig() public {
        // Create a custom config
        Config memory customConfig = Config({
            tiers: [
                Tier({chanceBps: 2500, feeBps: 100}),
                Tier({chanceBps: 2500, feeBps: 200}),
                Tier({chanceBps: 2500, feeBps: 300}),
                Tier({chanceBps: 2500, feeBps: 400})
            ],
            burnAddress: 0x000000000000000000000000000000000000BEEF,
            burnShareBps: 2000 // 20%
        });

        // Create and initialize a new pool with the custom config
        PoolKey memory customPoolKey = PoolKey(WETH, DAI, 3000, 60, hook);
        manager.initialize(customPoolKey, SQRT_RATIO_1_1, abi.encode(customConfig));
        PoolId customPoolId = customPoolKey.toId();

        Config memory actualConfig = hook.poolConfigs(customPoolId);
        assertEq(actualConfig.burnAddress, customConfig.burnAddress, "Custom burn address mismatch");
        assertEq(actualConfig.burnShareBps, customConfig.burnShareBps, "Custom burn share mismatch");
    }

    function test_Revert_Initialization_WithInvalidConfig() public {
        Config memory invalidConfig = hook.defaultConfig();
        invalidConfig.tiers[0].chanceBps = 9999; // Total chance is now > 100%

        PoolKey memory invalidPoolKey = PoolKey(WETH, DAI, 3000, 60, hook);
        vm.expectRevert(LuckyNBurnHook.InvalidConfig.selector);
        manager.initialize(invalidPoolKey, SQRT_RATIO_1_1, abi.encode(invalidConfig));
    }

    // --- Test Swaps and Fee Tiers ---

    function test_Swap_And_FeeLogic() public {
        // Find a swapper address for each fee tier
        address luckySwapper = _findSwapperForRoll(0); // First tier
        address discountedSwapper = _findSwapperForRoll(1001); // Second tier
        address normalSwapper = _findSwapperForRoll(4001); // Third tier
        address unluckySwapper = _findSwapperForRoll(9001); // Fourth tier
        
        Config memory config = hook.defaultConfig();

        _executeAndVerifySwap(luckySwapper, config.tiers[0], config);
        _executeAndVerifySwap(discountedSwapper, config.tiers[1], config);
        _executeAndVerifySwap(normalSwapper, config.tiers[2], config);
        _executeAndVerifySwap(unluckySwapper, config.tiers[3], config);
    }

    // --- Test Admin Functions ---

    function test_SetDefaultConfig() public {
        Config memory newConfig = Config({
            tiers: [
                Tier({chanceBps: 100, feeBps: 1}),
                Tier({chanceBps: 200, feeBps: 2}),
                Tier({chanceBps: 9000, feeBps: 3}),
                Tier({chanceBps: 700, feeBps: 4})
            ],
            burnAddress: 0x000000000000000000000000000000000000C0DE,
            burnShareBps: 1000 // 10%
        });

        vm.prank(hook.owner());
        hook.setDefaultConfig(newConfig);

        Config memory updatedConfig = hook.defaultConfig();
        assertEq(updatedConfig.burnAddress, newConfig.burnAddress, "Admin set burn address mismatch");
        assertEq(updatedConfig.burnShareBps, newConfig.burnShareBps, "Admin set burn share mismatch");
    }

    function test_Revert_When_NonOwner_SetsDefaultConfig() public {
        vm.expectRevert("OnlyOwner");
        hook.setDefaultConfig(hook.defaultConfig());
    }

    function test_RecoverFunds() public {
        // Send some funds to the hook
        deal(address(DAI), address(hook), 100e18);

        uint256 ownerBalanceBefore = DAI.balanceOf(hook.owner());
        
        vm.prank(hook.owner());
        hook.recoverFunds(DAI, 100e18);

        uint256 ownerBalanceAfter = DAI.balanceOf(hook.owner());
        assertEq(ownerBalanceAfter - ownerBalanceBefore, 100e18, "Owner did not recover funds");
    }

    // --- Test Security/Access Control ---

    function test_Revert_When_HookCalledByNonManager() public {
        vm.expectRevert(LuckyNBurnHook.OnlyPoolManager.selector);
        hook.beforeInitialize(poolKey, new bytes(0));

        vm.expectRevert(LuckyNBurnHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), poolKey, IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: SQRT_RATIO_1_1 / 2
        }), new bytes(0));
    }


    // --- Helper Functions ---

    function _executeAndVerifySwap(address swapper, Tier memory tier, Config memory config) private {
        // Fund the swapper
        deal(address(USDC), swapper, SWAP_AMOUNT * 2);

        uint256 burnFeeBps = (tier.feeBps * config.burnShareBps) / BASIS_POINTS_MAX;
        uint256 expectedBurnAmount = (SWAP_AMOUNT * burnFeeBps) / BASIS_POINTS_MAX;

        uint256 swapperBalanceBefore = USDC.balanceOf(swapper);
        uint256 burnAddressBalanceBefore = USDC.balanceOf(config.burnAddress);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, // Swapping USDC for ETH
            amountSpecified: int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: MIN_SQRT_RATIO + 1
        });
        
        vm.prank(swapper);
        USDC.approve(address(manager), SWAP_AMOUNT);

        vm.prank(swapper);
        manager.swap(poolKey, params, new bytes(0));

        uint256 swapperBalanceAfter = USDC.balanceOf(swapper);
        uint256 burnAddressBalanceAfter = USDC.balanceOf(config.burnAddress);
        
        // The total amount taken from the swapper should be the swap amount + the burn fee.
        uint256 totalPaid = swapperBalanceBefore - swapperBalanceAfter;
        // The LP fee is handled internally by the pool, so we only check the external burn amount.
        assertEq(totalPaid, SWAP_AMOUNT, "Total paid by swapper mismatch");
        assertEq(burnAddressBalanceAfter - burnAddressBalanceBefore, expectedBurnAmount, "Burn amount mismatch");
    }

    /// @dev Replicates the hook's _getRoll logic to find a suitable swapper address.
    function _getRoll(address swapper, PoolId pId) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            swapper,
            pId
        ))) % BASIS_POINTS_MAX;
    }

    /// @dev Brute-forces to find a swapper address that results in a specific dice roll range.
    function _findSwapperForRoll(uint256 targetRoll) internal view returns (address) {
        address swapper;
        uint256 roll;
        for (uint i = 1; i < 1000; i++) {
            swapper = address(uint160(i));
            roll = _getRoll(swapper, poolId);
            // Check if the roll falls into the intended tier's range based on default config
            if (_getTierIndex(roll) == _getTierIndex(targetRoll)) {
                return swapper;
            }
        }
        revert("Could not find a swapper for the target roll");
    }

    /// @dev Helper to determine tier index from a roll, mirroring the hook's logic.
    function _getTierIndex(uint256 roll) internal view returns (uint) {
        Config memory config = hook.defaultConfig();
        uint256 cumulative = 0;
        for(uint i = 0; i < 4; i++) {
            cumulative += config.tiers[i].chanceBps;
            if (roll < cumulative) return i;
        }
        return 3;
    }
} 