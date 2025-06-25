# 🎰 LuckyNBurnHook – Gamified Uniswap v4 Hook with Dynamic Fees, Token Burning & Loyalty System

**LuckyNBurnHook** is a custom [Uniswap v4 hook](https://github.com/Uniswap/v4-core) that introduces a **gamified fee structure** with burn mechanics and a **loyalty program**. Each swap has a randomized chance of being categorized into one of four tiers: **Lucky**, **Discounted**, **Normal**, or **Unlucky**. Depending on the outcome, the fee varies, and part of the fee may be burned (destroyed forever 🔥). The more you trade, the better your odds become!

---

## ✨ Features

### Core Mechanics
- 🎲 **Randomized Fee Tiers**: Each swap randomly lands in a fee tier with defined probabilities
- 🧊 **Lucky Swaps**: Pay the lowest fees (with cooldown)
- 💸 **Discounted & Normal Swaps**: Reduced or standard LP fees
- 🔥 **Unlucky Swaps**: Highest fees, with a portion sent to a burn address
- 🔁 **Cooldown Logic**: Prevents spam lucky wins

### Loyalty System 🏆
- 📈 **Progressive Tiers**: Bronze → Silver → Gold → Diamond → Legendary
- 🎯 **Better Lucky Odds**: Higher tiers get increased chances for lucky swaps
- 💰 **Fee Discounts**: Loyal traders pay less across all tiers
- ⏰ **Reduced Cooldowns**: VIP treatment with shorter wait times
- 🎖️ **Milestone Rewards**: Special bonuses for reaching swap/volume milestones

### Admin & Transparency
- 🔍 **Full Transparency**: Events emitted for each swap tier, burn, and loyalty upgrade
- ⚙️ **Customizable**: Owner can adjust fee tiers, cooldowns, burn settings, and loyalty parameters

---

## 📁 Project Structure

This repo includes:
- `LuckyNBurnHook.sol` – the main hook smart contract with loyalty system
- `LoyaltyLib.sol` – loyalty system library for tracking user engagement
- Uses `v4-core` and `v4-periphery` dependencies from Uniswap
- Designed for testing and educational purposes

---

## 🛠️ Requirements

- **Foundry** (for compiling, testing, and deploying)  
  📦 Install via: https://book.getfoundry.sh/getting-started/installation

- **Uniswap v4 dependencies**  
  You must clone both `v4-core` and `v4-periphery` locally or include them as submodules or git dependencies.

---

## 🚀 Setup & Deployment

### 1. Clone & Install

```bash
git clone https://github.com/YOUR_USERNAME/luckynburn-hook.git
cd luckynburn-hook

# Initialize Foundry project if not already
forge init

# Add dependencies
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install OpenZeppelin/openzeppelin-contracts
```

### 2. Compile

```bash
forge build
```

### 3. Test

```bash
forge test -vvv
```

---

## 🧪 Tier Mechanics

Each swap is assigned to a fee tier based on random chance (with loyalty bonuses):

| Tier       | Base Chance | Fee Addition (bps) | Description                          |
|------------|-------------|-------------------|--------------------------------------|
| **Lucky**      | 10%         | 0 bps             | Cooldown-based freebie               |
| **Discounted** | 30%         | 25 bps            | Slightly reduced fee                 |
| **Normal**     | 50%         | 50 bps            | Standard fee                         |
| **Unlucky**    | 10%         | 100 bps           | Highest fee; 50% burned 🔥           |

> 🧠 Base fee is **0.3% (3000 pips)** and tier fee is added dynamically on top.

---

## 🏆 Loyalty System

The loyalty system rewards frequent traders with better odds and lower fees:

### Loyalty Tiers

| Tier        | Swaps Required | Lucky Bonus | Fee Discount | Cooldown Reduction |
|-------------|----------------|-------------|--------------|-------------------|
| **Bronze**    | 0-19           | +0%         | 0%           | 0%                |
| **Silver**    | 20-49          | +2%         | -0.25%       | -15%              |
| **Gold**      | 50-99          | +4%         | -0.5%        | -30%              |
| **Diamond**   | 100-199        | +7%         | -1%          | -50%              |
| **Legendary** | 200+           | +12%        | -2%          | -75%              |

### Milestone Bonuses 🎖️

- **50th swap**: +1% permanent lucky chance bonus
- **100th swap**: +2% permanent lucky chance bonus
- **500th swap**: +5% permanent lucky chance bonus
- **Volume milestones**: +0.2% lucky chance per 100 ETH traded (up to 50 milestones)

### Benefits Explained

- **Lucky Bonus**: Additional chance to hit the lucky tier (stacks with base 10%)
- **Fee Discount**: Applies to ALL tier fees (lucky, discounted, normal, unlucky)
- **Cooldown Reduction**: Lucky tier cooldown reduced (1 hour base → 15 minutes for Legendary)
- **Milestone Bonuses**: Permanent bonuses that stack on top of tier bonuses

---

## 🧯 Burn Logic

- Only **Unlucky swaps** trigger token burning
- The fee is split: part goes to LPs, and the other part is sent to the burn address
- Default burn address: `0x000000000000000000000000000000000000dEaD`
- Burn share configurable by owner (default: 50% of unlucky fees)

---

## 🔧 Admin Functions

The contract owner (deployer) can adjust:

### Core Settings
- `setChances`: Tier probabilities (must sum to 10,000)
- `setFees`: Basis points added per tier
- `setCooldownPeriod`: Cooldown for Lucky rewards
- `setBurnConfig`: Burn address and burn share

### Loyalty Settings
- `setLoyaltyConfig`: Update swap thresholds, bonuses, discounts, and cooldown reductions

---

## 📊 View Functions

Query loyalty and trading stats:

```solidity
// Get trader's loyalty information
getLoyaltyTier(trader)        // Current loyalty tier
getLoyaltyStats(trader)       // Complete stats (tier, swaps, volume, bonuses)
getSwapCount(trader)          // Total swaps performed
getTotalVolume(trader)        // Total volume traded
swapsUntilNextTier(trader)    // Swaps needed for next tier

// Get system information
getCollectedForBurning(currency)  // Tokens collected for burning
getLoyaltyConfig()                // Current loyalty configuration
```

---

## 🏗️ Create a Pool, Attach the Hook & Provide Liquidity

Below is a quick guide to deploy your pool and become a believer by adding liquidity.

### 1. Deploy the Hook

After deploying Uniswap v4 core contracts, deploy `LuckyNBurnHook` with the `PoolManager` address:

```solidity
new LuckyNBurnHook(poolManagerAddress)
```

> This returns your hook address, e.g., `0x123...abc`

### 2. Encode the Hook into the PoolId

When creating a new pool, encode the hook into the `PoolId` using Uniswap's helper:

```solidity
PoolKey memory key = PoolKey({
  currency0: Currency.wrap(address(token0)),
  currency1: Currency.wrap(address(token1)),
  fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // Enable dynamic fees
  tickSpacing: 60,
  hooks: address(luckyNBurnHook) // Your deployed hook
});
```

Then compute the PoolId:

```solidity
bytes32 poolId = PoolIdLibrary.toId(key);
```

### 3. Initialize the Pool

Use the `PoolManager` to initialize your pool with a square root price (encoded as sqrtPriceX96):

```solidity
poolManager.initialize(key, sqrtPriceX96);
```

### 4. Provide LP as a Believer

Choose your tick range and desired liquidity amount, then provide LP like this:

```solidity
poolManager.lock(
    address(this), 
    abi.encodeWithSelector(
        IPoolManager.modifyPosition.selector,
        key,
        IPoolManager.ModifyPositionParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: int128(1e18)
        }),
        ""
    )
);
```

This effectively adds liquidity to the pool. You are now a **LuckyNBurn LP believer** ✊🔥

---

## 🧠 Tips & Debug

- Use `hookData = abi.encode(trader, salt)` for swaps to ensure randomness works as intended
- The hook supports `log_balances()` to debug token flows from the pool, hook, trader, and burn address
- You can view `collectedForBurning(currency)` for real-time insight into burn amounts per token
- Monitor loyalty progression with `getLoyaltyStats()` to see tier upgrades and bonuses
- Track milestone achievements through emitted `MilestoneReached` events

---

## 📊 Events

The contract emits comprehensive events for tracking:

### Swap Events
- `Lucky(trader, feeBps, timestamp)` - Lucky tier achieved
- `Discounted(trader, feeBps)` - Discounted tier achieved
- `Normal(trader, feeBps)` - Normal tier achieved
- `Unlucky(trader, feeBps, burnAmount)` - Unlucky tier with burn amount

### Loyalty Events
- `LoyaltyTierUpgraded(trader, newTier)` - Tier progression
- `MilestoneReached(trader, milestone, bonus)` - Milestone achievements

### Admin Events
- `SetChances`, `SetFees`, `SetBurnConfig`, `SetCooldown` - Configuration updates
- `SetLoyaltyConfig` - Loyalty system updates
- `TokensBurned` - Burn execution events

Use these to power a gamified frontend with real-time loyalty tracking! 📈

---

## 🎮 Example User Journey

1. **New Trader** (Bronze):
  - 10% base lucky chance, standard fees
  - Performs 25 swaps over time

2. **Silver Tier Achieved** (20+ swaps):
  - 12% lucky chance (+2% bonus), 0.25% fee discount
  - 15% cooldown reduction, milestone bonus at 50 swaps

3. **Gold Tier & Beyond** (50+ swaps):
  - 14% lucky chance (+4% bonus), 0.5% fee discount
  - 30% cooldown reduction, additional milestone bonuses

4. **Volume Milestones**:
  - Every 100 ETH traded = +0.2% permanent lucky bonus
  - Special bonuses at 100, 500 swap milestones

5. **Legendary Status** (200+ swaps):
  - 22% lucky chance (+12% bonus), 2% fee discount
  - 75% cooldown reduction = VIP treatment! 👑

---

## ⚠️ Disclaimer

This hook uses **pseudo-randomness** (e.g., blockhash, timestamp) and is **not safe for mainnet production**. Intended for experimental or educational use. Use real randomness (e.g., Chainlink VRF) for production.

---

## 🧠 Why This Matters

The LuckyNBurnHook brings life and randomness into Uniswap swaps while **rewarding loyalty**. It:

- **Rewards traders** with better odds and lower fees over time
- **Punishes greed** through unlucky burns while **encouraging engagement**
- **Creates deflation** through systematic token burning
- **Gamifies liquidity** with progression systems and milestone rewards
- **Injects excitement** into DeFi with unpredictable outcomes and VIP treatment

It's a new way to build **sticky, engaging DeFi protocols** that reward your most active users! 🚀

---

## 📝 License

GNU GENERAL PUBLIC LICENSE © 2025
