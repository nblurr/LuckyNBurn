// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LuckyNBurnHook, Config, Tier} from "src/LuckyNBurnHook.sol";

// V4 Test Imports
import {PoolManagerTest} from "@uniswap/v4-core/test/PoolManager.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ERC20Mock} from "@uniswap/v4-core/lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {console} from "forge-std/console.sol";

contract LuckyNBurnHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    ERC20Mock public USDC;
    ERC20Mock public WETH;
    ERC20Mock public DAI;
    
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336; // sqrt(1) * 2^96
    uint160 constant MIN_SQRT_RATIO = 4295128739;

    LuckyNBurnHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 internal constant SWAP_AMOUNT = 1e18;
    uint256 private constant BASIS_POINTS_MAX = 10_000;

    function deployMintAndApproveWETHAndDAI()
        internal
        returns (Currency currency0, Currency currency1)
    {
        // Deploy mock WETH
        WETH.mint(address(this), 1_000_000e18);
        WETH.approve(address(manager), type(uint256).max);

        // Deploy mock DAI
        DAI.mint(address(this), 1_000_000e18);
        DAI.approve(address(manager), type(uint256).max);

        // Wrap addresses as Currency
        currency0 = Currency.wrap(address(WETH));
        currency1 = Currency.wrap(address(DAI));
    }

    function setUp() public {
        deployFreshManagerAndRouters();


        (currency0, currency1) = deployMintAndApproveWETHAndDAI();

        currency0 = Currency.wrap(address(WETH));
    currency1 = Currency.wrap(address(DAI));

        // Calculate the hook address with ONLY the hook flags
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG
            )
        );
        
        // Deploy the hook at the correct address
        deployCodeTo("LuckyNBurnHook.sol", abi.encode(manager), hookAddress);
        hook = LuckyNBurnHook(hookAddress);

        // Define the pool with dynamic fee flag

        // Initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1
        );

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Deploy mock tokens
        USDC = new ERC20Mock(); // 6 decimals for USDC
        WETH = new ERC20Mock(); // 18 decimals for WETH
        DAI = new ERC20Mock(); // 18 decimals for DAI

        // Fund this test contract with tokens
        // Deal tokens to test contract
        deal(address(USDC), address(this), 1_000_000e6); // 1M USDC
        deal(address(DAI), address(hook), 1_000_000e18); // 100 DAI for hook
        deal(address(WETH), address(hook), 1_000_000e18); // Fund hook with WETH for fee transfers

        // Approve tokens
        USDC.approve(address(manager), type(uint256).max);
        WETH.approve(address(manager), type(uint256).max);
        DAI.approve(address(manager), type(uint256).max);
    }

    function _loadConfigFromEnv() internal view returns (Config memory) {
        // Load tier configurations
        Tier[4] memory tiers = [
            Tier({
                chanceBps: uint24(vm.envUint("TIER1_CHANCE_BPS")),
                feeBps: uint24(vm.envUint("TIER1_FEE_BPS"))
            }),
            Tier({
                chanceBps: uint24(vm.envUint("TIER2_CHANCE_BPS")),
                feeBps: uint24(vm.envUint("TIER2_FEE_BPS"))
            }),
            Tier({
                chanceBps: uint24(vm.envUint("TIER3_CHANCE_BPS")),
                feeBps: uint24(vm.envUint("TIER3_FEE_BPS"))
            }),
            Tier({
                chanceBps: uint24(vm.envUint("TIER4_CHANCE_BPS")),
                feeBps: uint24(vm.envUint("TIER4_FEE_BPS"))
            })
        ];

        // Load burn configuration
        address burnAddress = vm.envAddress("BURN_ADDRESS");
        uint24 burnShareBps = uint24(vm.envUint("BURN_SHARE_BPS"));

        return Config ({
            tiers: tiers,
            burnAddress: burnAddress,
            burnShareBps: burnShareBps
        });
    }

    // --- Test Initialization ---

    function test_Initialization_UsesDefaultConfig() public view{

        
        Config memory conf = hook.getConfig(); // or hook.getConfig()

        // Unpack fields for logging or use
        Tier[4] memory tiers = conf.tiers;
        address burnAddress = conf.burnAddress;
        uint24 burnShareBps = conf.burnShareBps;
        
        Config memory defaultConfig = Config({tiers: tiers, burnAddress: burnAddress, burnShareBps: burnShareBps});

        Config memory actualConfig = hook.getPoolConfigs(poolId);

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
            burnAddress: 0x000000000000000000000000000000000000dEaD,
            burnShareBps: 2000 // 20%
        });

        // Create and initialize a new pool
        PoolKey memory customPoolKey = PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(address(DAI)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        
        // Initialize the pool first
        manager.initialize(customPoolKey, SQRT_RATIO_1_1);
        
        // Get the pool ID
        PoolId customPoolId = customPoolKey.toId();
        
        // Set the pool configuration
        hook.setPoolConfigs(customPoolId, customConfig);

        // Verify the configuration was set correctly
        Config memory actualConfig = hook.getPoolConfigs(customPoolId);
        assertEq(actualConfig.burnAddress, customConfig.burnAddress, "Custom burn address mismatch");
        assertEq(actualConfig.burnShareBps, customConfig.burnShareBps, "Custom burn share mismatch");
    }

    /*
    function test_Revert_Initialization_WithInvalidConfig() public {
        Config memory invalidConfig = hook.getConfig();
        invalidConfig.tiers[0].chanceBps = 9999; // Total chance is now > 100%

        PoolKey memory invalidPoolKey = PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(address(DAI)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Initialize the pool first
        manager.initialize(invalidPoolKey, SQRT_RATIO_1_1);
        
        // Get the pool ID
        PoolId invalidPoolId = invalidPoolKey.toId();
        
        // Try to set invalid config
        vm.expectRevert(LuckyNBurnHook.InvalidConfig.selector);
        hook.setPoolConfigs(invalidPoolId, invalidConfig);
    }
    */

    // --- Test Swaps and Fee Tiers ---

    function test_Swap_And_FeeLogic() public {
        // Find a swapper address for each fee tier
 
        address luckySwapper = _findSwapperForRoll(0); // First tier
 /*
        address discountedSwapper = _findSwapperForRoll(1001); // Second tier
        address normalSwapper = _findSwapperForRoll(4001); // Third tier
        address unluckySwapper = _findSwapperForRoll(9001); // Fourth tier
*/

        vm.deal(luckySwapper, 1_000_000 ether); 

        Config memory config = hook.getConfig();

        _executeAndVerifySwap(luckySwapper, config.tiers[0], config);
/*
        _executeAndVerifySwap(discountedSwapper, config.tiers[1], config);
        _executeAndVerifySwap(normalSwapper, config.tiers[2], config);
        _executeAndVerifySwap(unluckySwapper, config.tiers[3], config);
*/
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
            burnAddress: 0x000000000000000000000000000000000000dEaD,
            burnShareBps: 1000 // 10%
        });

        vm.prank(hook.owner());
        hook.setConfig(newConfig);

        Config memory updatedConfig = hook.getConfig();
        assertEq(updatedConfig.burnAddress, newConfig.burnAddress, "Admin set burn address mismatch");
        assertEq(updatedConfig.burnShareBps, newConfig.burnShareBps, "Admin set burn share mismatch");
    }

    /*
        function test_Revert_When_NonOwner_SetsDefaultConfig() public {
            vm.expectRevert("OnlyOwner");
            hook.setDefaultConfig(hook.getConfig());
        }


    function test_RecoverFunds() public {
        deal(address(DAI), address(hook), 100e18);

        uint256 ownerBalanceBefore = DAI.balanceOf(hook.owner());
        
        vm.prank(hook.owner());
        hook.recoverFunds(Currency.wrap(address(DAI)), 100e18);

        uint256 ownerBalanceAfter = DAI.balanceOf(hook.owner());
        assertEq(ownerBalanceAfter - ownerBalanceBefore, 100e18, "Owner did not recover funds");
    }

   */
   // --- Test Security/Access Control ---

/*
    function test_Revert_When_HookCalledByNonManager() public {
        vm.expectRevert(LuckyNBurnHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), poolKey, SQRT_RATIO_1_1);

        vm.expectRevert(LuckyNBurnHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), poolKey, SwapParams({
            zeroForOne: true,
            amountSpecified: int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: SQRT_RATIO_1_1 / 2
        }), new bytes(0));
    }
*/

    // --- Helper Functions ---

    function _executeAndVerifySwap(address swapper, Tier memory tier, Config memory config) private {
        deal(address(USDC), swapper, SWAP_AMOUNT * 2);

        uint256 burnFeeBps = (tier.feeBps * config.burnShareBps) / BASIS_POINTS_MAX;
        uint256 expectedBurnAmount = (SWAP_AMOUNT * burnFeeBps) / BASIS_POINTS_MAX;

        console.log("Expected Burn Amount: %d", expectedBurnAmount);

        uint256 swapperBalanceBefore = USDC.balanceOf(swapper);
        uint256 burnBalanceBefore = hook.burnBalances(config.burnAddress, Currency.wrap(address(USDC)));
        uint256 burnAddressBalanceBefore = USDC.balanceOf(config.burnAddress);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        
        vm.prank(swapper);
        USDC.approve(address(manager), SWAP_AMOUNT);
        USDC.approve(address(hook), expectedBurnAmount);
        console.log("Manager Allowance: %d", USDC.allowance(swapper, address(manager)));
        console.log("Hook Allowance: %d", USDC.allowance(swapper, address(hook)));

        vm.prank(swapper);
        
        swap(poolKey, true, -int256(SWAP_AMOUNT), abi.encode(config));

        uint256 swapperBalanceAfter = USDC.balanceOf(swapper);
        uint256 burnBalanceAfter = hook.burnBalances(config.burnAddress, Currency.wrap(address(USDC)));
        uint256 burnAddressBalanceAfter = USDC.balanceOf(config.burnAddress);
        
        assertEq(swapperBalanceBefore - swapperBalanceAfter, SWAP_AMOUNT + expectedBurnAmount, "Total paid by swapper mismatch");
        assertEq(burnBalanceAfter - burnBalanceBefore, expectedBurnAmount, "Burn balance mismatch");
        assertEq(burnAddressBalanceAfter, burnAddressBalanceBefore, "Burn address balance unchanged");

        //vm.prank(config.burnAddress);
        //hook.claimBurn(Currency.wrap(address(USDC)), expectedBurnAmount);
        //assertEq(
        //    USDC.balanceOf(config.burnAddress) - burnAddressBalanceBefore,
        //    expectedBurnAmount,
        //    "Burn address claim failed"
        //);
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
        Config memory config = hook.getConfig();
        uint256 cumulative = 0;
        for(uint i = 0; i < 4; i++) {
            cumulative += config.tiers[i].chanceBps;
            if (roll < cumulative) return i;
        }
        return 3;
    }
} 