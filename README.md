# LuckyNBurn: A Gamified Uniswap v4 Hook

You might get lucky… or pay the price to fuel the fire. LuckyNBurn is a lightweight, gamified Uniswap v4 hook that makes swap fees unpredictable — turning every trade into a roll of the dice. Most users get the usual rate, some get rewarded with a discount… and a few unlucky ones pay a higher fee that is partially burned.

---

### **Development Plan**

This document outlines the strategic phases to architect, build, test, and deploy the `LuckyNBurn` hook.

#### **Phase 1: Foundation & Project Setup**

1.  **Setup Development Environment:**
    *   **Install Foundry:** Use `foundryup` to get the latest `forge`, `cast`, and `anvil` toolchain.
    *   **Initialize Project:** `forge init LuckyNBurn`
    *   **Navigate to Project:** `cd LuckyNBurn`

2.  **Install Dependencies:**
    *   **Uniswap v4 Core:** `forge install uniswap/v4-core`
    *   **Solmate:** `forge install Rari-Capital/solmate` for gas-optimized primitives.

3.  **Contract Scaffolding:**
    *   Create `src/LuckyNBurnHook.sol`.
    *   The contract will inherit from `BaseHook` and `ReentrancyGuard`.
    *   Define `IUniswapV4PoolManager public immutable POOL_MANAGER;`.
    *   The `constructor` will set the `POOL_MANAGER` address.

---

#### **Phase 2: Core Logic & The "Dice Roll"**

1.  **State Variables & Intelligent Configuration:**
    *   `owner`: An `address` for contract administration.
    *   **Tier Parameters (Basis Points):**
        *   `luckyChanceBps`: `uint16` (e.g., `1000` for 10.00%).
        *   `unluckyChanceBps`: `uint16` (e.g., `500` for 5.00%).
        *   `luckyFeeDiscountBps`: `uint16` (e.g., `5000` for a 50% discount).
        *   `unluckyFeeSurchargeBps`: `uint16` (e.g., `10000` for a 100% surcharge).
    *   **Burn Mechanism:**
        *   `burnAddress`: `address` (e.g., `0x000...0dEaD`).
        *   `burnFeeShareBps`: `uint16` - Percentage of surcharge to burn (e.g., `2500` for 25%).
    *   **Anti-Abuse Feature:**
        *   `traderCooldown`: `mapping(address => uint256) public lastLuckyTimestamp;`.
        *   `cooldownPeriod`: `uint256` (e.g., `1 hour`).

2.  **On-Chain Randomness Engine:**
    *   Internal function `_getRoll(address trader, bytes32 salt) returns (uint16)`.
    *   Uses a `keccak256` hash of `block.timestamp`, `msg.sender`, `blockhash(block.number - 1)`, etc., for pseudo-randomness.

3.  **Primary Hook Implementation (`beforeSwap`):**
    *   Called by the Pool Manager before a swap.
    *   Contains the tier selection logic based on the `_getRoll()` result.
    *   Returns the `afterSwap` selector (`this.afterSwap.selector`) to trigger the fee settlement logic.

---

#### **Phase 3: Fee Mechanics & The Burn**

1.  **Fee & Burn Settlement (`afterSwap`):**
    *   Called after the swap is complete.
    *   **Unlucky Path:** Calculates and takes the surcharge from the user, then splits it between the burn address and the hook's treasury (to fund lucky rewards).
    *   **Lucky Path:** Calculates the discount, verifies the trader is not on cooldown, and sends the rebate from the hook's treasury to the user. Updates the user's `lastLuckyTimestamp`.

---

#### **Phase 4: Administration & Security**

1.  **Owner-Only Functions:**
    *   Implement an `onlyOwner` modifier.
    *   Create setters for all configurable parameters (`setChances`, `setFeeModifiers`, etc.).
    *   Include a `recoverFunds` function to withdraw excess funds.

2.  **Security Best Practices:**
    *   **Re-entrancy:** Apply `nonReentrant` modifier to external functions.
    *   **Input Validation:** Ensure setters validate inputs.
    *   **Access Control:** Rigorously apply `onlyOwner` and `onlyPoolManager` checks.
    *   **Economic Modeling:** Ensure the fee/reward structure is sustainable.

---

#### **Phase 5: Testing & Deployment**

1.  **Local Testing with Foundry:**
    *   Write a comprehensive test suite covering all paths (Lucky, Unlucky, Normal).
    *   Test all calculations, cooldowns, and admin functions.
    *   Use Foundry's cheatcodes (`vm.prank`, `vm.expectEmit`) to simulate interactions.

2.  **Deployment:**
    *   Develop a `forge script` for repeatable deployments.
    *   Deploy to a testnet for live integration testing.
    *   **A professional security audit is required before mainnet.**
    *   Deploy to mainnet and engage with the community.
