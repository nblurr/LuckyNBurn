// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title LoyaltyLib
 * @notice Library for managing user loyalty metrics and rewards
 * @dev Provides functionality for tracking swaps, volumes, and calculating loyalty benefits
 */
library LoyaltyLib {

    // -------------------------------------------------------------------
    //                             STRUCTS & ENUMS
    // -------------------------------------------------------------------

    enum LoyaltyTier {
        Bronze,    // 0-19 swaps
        Silver,    // 20-49 swaps
        Gold,      // 50-99 swaps
        Diamond,   // 100-199 swaps
        Legendary  // 200+ swaps
    }

    struct LoyaltyConfig {
        uint8[5] swapThresholds;    // Required swaps for each tier
        uint16[5] luckyBonuses;      // Lucky chance bonus (bps) for each tier
        uint16[5] feeDiscounts;      // Fee discount (bps) for each tier
        uint8[5] cooldownReductions; // Cooldown reduction (percentage) for each tier
    }

    struct LoyaltyData {
        uint256 swapCount;
        uint256 totalVolume;
        LoyaltyTier currentTier;
        uint16 milestoneBonus;
        mapping(uint256 => bool) milestoneReached;
    }

    struct LoyaltyStats {
        LoyaltyTier tier;
        uint256 swaps;
        uint256 volume;
        uint16 luckyBonus;
        uint16 feeDiscount;
        uint8 cooldownReduction;
        uint16 milestoneBonus;
    }

    // -------------------------------------------------------------------
    //                              EVENTS
    // -------------------------------------------------------------------

    event LoyaltyTierUpgraded(address indexed trader, LoyaltyTier newTier);
    event MilestoneReached(address indexed trader, uint256 milestone, uint256 bonus);

    // -------------------------------------------------------------------
    //                          CORE FUNCTIONS
    // -------------------------------------------------------------------

    /**
     * @notice Initialize default loyalty configuration
     * @return config The default loyalty configuration
     */
    function getDefaultConfig() internal pure returns (LoyaltyConfig memory config) {
        config.swapThresholds = [uint8(0), uint8(20), uint8(50), uint8(100), uint8(200)];
        config.luckyBonuses = [uint16(0), uint16(200), uint16(400), uint16(700), uint16(1200)];
        config.feeDiscounts = [uint16(0), uint16(25), uint16(50), uint16(100), uint16(200)];
        config.cooldownReductions = [uint8(0), uint8(15), uint8(30), uint8(50), uint8(75)];
    }

    /**
     * @notice Get the loyalty tier for a trader based on swap count
     * @param data The loyalty data for the trader
     * @param config The loyalty configuration
     * @return The loyalty tier
     */
    function getLoyaltyTier(
        LoyaltyData storage data,
        LoyaltyConfig memory config
    ) internal view returns (LoyaltyTier) {
        uint256 count = data.swapCount;

        if (count >= config.swapThresholds[4]) return LoyaltyTier.Legendary;
        if (count >= config.swapThresholds[3]) return LoyaltyTier.Diamond;
        if (count >= config.swapThresholds[2]) return LoyaltyTier.Gold;
        if (count >= config.swapThresholds[1]) return LoyaltyTier.Silver;
        return LoyaltyTier.Bronze;
    }

    /**
     * @notice Get adjusted lucky chance including loyalty bonuses
     * @param data The loyalty data for the trader
     * @param config The loyalty configuration
     * @param baseLuckyChance The base lucky chance before loyalty
     * @return The adjusted lucky chance (capped at 3000 bps for balance)
     */
    function getAdjustedLuckyChance(
        LoyaltyData storage data,
        LoyaltyConfig storage config,
        uint16 baseLuckyChance
    ) internal view returns (uint16) {
        LoyaltyTier tier = getLoyaltyTier(data, config);
        uint16 tierBonus = config.luckyBonuses[uint256(tier)];
        uint16 milestoneBonus = data.milestoneBonus;

        uint256 totalChance = uint256(baseLuckyChance) + uint256(tierBonus) + uint256(milestoneBonus);

        // Cap at 3000 bps (30%) to maintain game balance
        return totalChance > 3000 ? 3000 : uint16(totalChance);
    }

    /**
     * @notice Get fee discount based on loyalty tier
     * @param data The loyalty data for the trader
     * @param config The loyalty configuration
     * @return The fee discount in basis points
     */
    function getFeeDiscount(
        LoyaltyData storage data,
        LoyaltyConfig storage config
    ) internal view returns (uint16) {
        LoyaltyTier tier = getLoyaltyTier(data, config);
        return config.feeDiscounts[uint256(tier)];
    }

    /**
     * @notice Get adjusted cooldown period based on loyalty tier
     * @param data The loyalty data for the trader
     * @param config The loyalty configuration
     * @param baseCooldown The base cooldown period
     * @return The adjusted cooldown period
     */
    function getAdjustedCooldown(
        LoyaltyData storage data,
        LoyaltyConfig storage config,
        uint256 baseCooldown
    ) internal view returns (uint256) {
        LoyaltyTier tier = getLoyaltyTier(data, config);
        uint8 reduction = config.cooldownReductions[uint256(tier)];

        return baseCooldown - (baseCooldown * reduction / 100);
    }

    /**
     * @notice Update loyalty metrics after a swap
     * @param data The loyalty data for the trader
     * @param config The loyalty configuration
     * @param trader The trader's address (for events)
     * @param swapAmount The amount swapped (in wei)
     */
    function updateLoyaltyMetrics(
        LoyaltyData storage data,
        LoyaltyConfig storage config,
        address trader,
        uint256 swapAmount
    ) internal {
        // Update metrics
        data.swapCount++;
        data.totalVolume += swapAmount;

        // Check for tier upgrade
        LoyaltyTier oldTier = data.currentTier;
        LoyaltyTier newTier = getLoyaltyTier(data, config);

        if (newTier > oldTier) {
            data.currentTier = newTier;
            emit LoyaltyTierUpgraded(trader, newTier);
        }

        // Check milestones
        _checkMilestones(data, trader);
    }

    /**
     * @notice Check and award milestone bonuses
     * @param data The loyalty data for the trader
     * @param trader The trader's address (for events)
     */
    function _checkMilestones(
        LoyaltyData storage data,
        address trader
    ) internal {
        uint256 count = data.swapCount;

        // Volume milestones (every 100 ETH equivalent)
        uint256 volumeMilestone = data.totalVolume / 100 ether;
        if (volumeMilestone > 0 && volumeMilestone <= 50 && !data.milestoneReached[volumeMilestone + 2000]) {
            data.milestoneReached[volumeMilestone + 2000] = true;
            data.milestoneBonus += 20; // +0.2% lucky chance per 100 ETH traded
            emit MilestoneReached(trader, volumeMilestone + 2000, 20);
        }

        // Special count milestones
        if (count == 50 && !data.milestoneReached[50]) {
            data.milestoneReached[50] = true;
            data.milestoneBonus += 100; // +1% lucky chance for 50th swap
            emit MilestoneReached(trader, 50, 100);
        }

        if (count == 100 && !data.milestoneReached[100]) {
            data.milestoneReached[100] = true;
            data.milestoneBonus += 200; // +2% lucky chance for 100th swap
            emit MilestoneReached(trader, 100, 200);
        }

        if (count == 500 && !data.milestoneReached[500]) {
            data.milestoneReached[500] = true;
            data.milestoneBonus += 500; // +5% lucky chance for 500th swap
            emit MilestoneReached(trader, 500, 500);
        }
    }

    // -------------------------------------------------------------------
    //                          VIEW FUNCTIONS
    // -------------------------------------------------------------------

    /**
     * @notice Get comprehensive loyalty stats for a trader
     * @param data The loyalty data for the trader
     * @param config The loyalty configuration
     * @return stats Complete loyalty statistics
     */
    function getLoyaltyStats(
        LoyaltyData storage data,
        LoyaltyConfig storage config
    ) internal view returns (LoyaltyStats memory stats) {
        LoyaltyTier tier = getLoyaltyTier(data, config);

        stats = LoyaltyStats({
            tier: tier,
            swaps: data.swapCount,
            volume: data.totalVolume,
            luckyBonus: config.luckyBonuses[uint256(tier)],
            feeDiscount: config.feeDiscounts[uint256(tier)],
            cooldownReduction: config.cooldownReductions[uint256(tier)],
            milestoneBonus: data.milestoneBonus
        });
    }

    /**
     * @notice Check how many swaps until next tier
     * @param data The loyalty data for the trader
     * @param config The loyalty configuration
     * @return swapsNeeded Number of swaps needed for next tier (0 if max tier)
     */
    function swapsUntilNextTier(
        LoyaltyData storage data,
        LoyaltyConfig storage config
    ) internal view returns (uint256 swapsNeeded) {
        LoyaltyTier currentTierLevel = getLoyaltyTier(data, config);

        if (currentTierLevel == LoyaltyTier.Legendary) return 0;

        uint256 nextThreshold = config.swapThresholds[uint256(currentTierLevel) + 1];
        uint256 currentSwaps = data.swapCount;

        return nextThreshold > currentSwaps ? nextThreshold - currentSwaps : 0;
    }

    /**
     * @notice Get loyalty tier name as string
     * @param tier The loyalty tier
     * @return The tier name
     */
    function getTierName(LoyaltyTier tier) internal pure returns (string memory) {
        if (tier == LoyaltyTier.Bronze) return "Bronze";
        if (tier == LoyaltyTier.Silver) return "Silver";
        if (tier == LoyaltyTier.Gold) return "Gold";
        if (tier == LoyaltyTier.Diamond) return "Diamond";
        if (tier == LoyaltyTier.Legendary) return "Legendary";
        return "Unknown";
    }

    /**
     * @notice Validate loyalty configuration
     * @param config The loyalty configuration to validate
     * @return isValid Whether the configuration is valid
     */
    function validateConfig(LoyaltyConfig memory config) internal pure returns (bool isValid) {
        // Check that thresholds are in ascending order
        for (uint256 i = 1; i < 5; i++) {
            if (config.swapThresholds[i] <= config.swapThresholds[i - 1]) {
                return false;
            }
        }

        // Check that bonuses and discounts are reasonable
        for (uint256 i = 0; i < 5; i++) {
            if (config.luckyBonuses[i] > 2000 || // Max 20% bonus
            config.feeDiscounts[i] > 500 ||  // Max 5% discount
                config.cooldownReductions[i] > 90) { // Max 90% reduction
                return false;
            }
        }

        return true;
    }
}
