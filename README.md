# 🎰 LuckyNBurnHook – Gamified Uniswap v4 Hook with Dynamic Fees and Token Burning

**LuckyNBurnHook** is a custom [Uniswap v4 hook](https://github.com/Uniswap/v4-core) that introduces a **gamified fee structure** with burn mechanics. Each swap has a randomized chance of being categorized into one of four tiers: **Lucky**, **Discounted**, **Normal**, or **Unlucky**. Depending on the outcome, the fee varies, and part of the fee may be burned (destroyed forever 🔥).

---

## ✨ Features

- 🎲 **Randomized Fee Tiers**: Each swap randomly lands in a fee tier with defined probabilities.
- 🧊 **Lucky Swaps**: Pay the lowest fees (with cooldown).
- 💸 **Discounted & Normal Swaps**: Reduced or standard LP fees.
- 🔥 **Unlucky Swaps**: Highest fees, with a portion sent to a burn address.
- 🔁 **Cooldown Logic**: Prevents spam lucky wins.
- 🔍 **Full Transparency**: Events emitted for each swap tier and burn.
- ⚙️ **Customizable**: Owner can adjust fee tiers, cooldowns, and burn settings.

---

## 📁 Project Structure

This repo includes:
- `LuckyNBurnHook.sol` – the main hook smart contract
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

Each swap is assigned to a fee tier based on random chance:

| Tier       | Chance (default) | Fee Addition (bps) | Description                          |
|------------|------------------|--------------------|--------------------------------------|
| **Lucky**      | 10%              | 0 bps               | Cooldown-based freebie               |
| **Discounted** | 30%              | 25 bps              | Slightly reduced fee                 |
| **Normal**     | 50%              | 50 bps              | Standard fee                         |
| **Unlucky**    | 10%              | 100 bps             | Highest fee; 50% burned 🔥           |

> 🧠 Base fee is **0.3% (3000 pips)** and tier fee is added dynamically on top.

---

## 🧯 Burn Logic

- Only **Unlucky swaps** trigger token burning.
- The fee is split: part goes to LPs, and the other part is sent to the burn address.
- Default burn address: `0x000000000000000000000000000000000000dEaD`

---

## 🔧 Admin Functions

The contract owner (deployer) can adjust:

- `setChances`: Tier probabilities (must sum to 10,000)
- `setFees`: Basis points added per tier
- `setCooldownPeriod`: Cooldown for Lucky rewards
- `setBurnConfig`: Burn address and burn share

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
  fee: 3000, // base 0.3% fee
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

- Use `hookData = abi.encode(trader, salt)` for swaps to ensure randomness works as intended.
- The hook supports `log_balances()` to debug token flows from the pool, hook, trader, and burn address.
- You can view `collectedForBurning(currency)` for real-time insight into burn amounts per token.

---

## 📊 Events

The contract emits:

- `Lucky`, `Discounted`, `Normal`, `Unlucky`
- `TokensBurned`
- `SetChances`, `SetFees`, `SetBurnConfig`, `SetCooldown`

Use these to power a gamified frontend!

---

## ⚠️ Disclaimer

This hook uses **pseudo-randomness** (e.g., blockhash, timestamp) and is **not safe for mainnet production**. Intended for experimental or educational use. Use real randomness (e.g., Chainlink VRF) for production.

---

## 🧠 Why This Matters

The LuckyNBurnHook brings life and randomness into Uniswap swaps. It rewards traders, punishes greed, and creates deflation through burns. It’s a new way to **gamify liquidity**, **encourage interaction**, and **inject excitement** into DeFi.

---

## 📝 License

GNU GENERAL PUBLIC LICENSE © 2024
