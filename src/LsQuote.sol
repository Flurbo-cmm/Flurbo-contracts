// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FactoredCost as F} from "./FactoredCost.sol";
import {FactoredQuote as Q} from "./FactoredQuote.sol";
import {QuoteMath} from "./QuoteMath.sol";

/// @notice Liquidity-sensitive LMSR quotes over factored liabilities.
/// @dev depth = initialDepth + rate * mean joint liability. The uniform seed initialDepth / rate cancels in every quote.
library LsQuote {
    error InvalidCommission();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant LN2_WAD = 693147180559945309;
    uint16 internal constant MIN_COMMISSION_BPS = 100;
    uint16 internal constant MAX_COMMISSION_BPS = 2000;

    struct Market {
        uint8 events;
        uint128 initialDepth; // collateral atoms
        uint256 rate; // WAD
        uint8 decimals;
        Q.Factor[] factors;
        uint8[] order;
    }

    /// @dev commission / (events ln 2) in WAD, so a complete set costs at most 1 + commission before impact.
    function depthRate(uint8 events, uint16 commissionBps) internal pure returns (uint256) {
        if (events == 0 || events > 32) revert F.InvalidEventCount();
        if (commissionBps < MIN_COMMISSION_BPS || commissionBps > MAX_COMMISSION_BPS) revert InvalidCommission();
        return uint256(commissionBps) * 1e14 * WAD / (uint256(events) * LN2_WAD);
    }

    /// @dev Each table covers at most 3 events, so its mean over the joint states is its sum times (8 >> size) / 8.
    function depthWad(uint256 initialDepthWad, uint256 rate, F.Factor[] memory factors)
        internal
        pure
        returns (uint256)
    {
        uint256 scaled;
        for (uint256 i; i < factors.length; i++) {
            uint256 size;
            for (uint32 s = factors[i].scope; s != 0; s &= s - 1) {
                size++;
            }
            if (size > 3) revert F.InvalidScope();
            if (factors[i].values.length != uint256(1) << size) revert F.InvalidValues();
            uint256 sum;
            for (uint256 j; j < factors[i].values.length; j++) {
                sum += factors[i].values[j];
            }
            scaled += sum * (8 >> size);
        }
        return initialDepthWad + Math.mulDiv(rate, scaled, 8 * WAD);
    }

    function currentDepth(Market memory market) internal pure returns (uint256) {
        uint256 scale = QuoteMath.scale(market.decimals);
        return depthWad(uint256(market.initialDepth) * scale, market.rate, Q.toWad(market.factors, scale));
    }

    function buy(Market memory market, uint32 scope, uint256 mask, uint128 quantity, uint128 maxCost)
        internal
        pure
        returns (Q.Quote memory quote)
    {
        quote = simulate(market, scope, mask, quantity, true);
        if (quote.collateral > maxCost) revert Q.MaxCostExceeded();
    }

    function sell(Market memory market, uint32 scope, uint256 mask, uint128 quantity, uint128 minProceeds)
        internal
        pure
        returns (Q.Quote memory quote)
    {
        quote = simulate(market, scope, mask, quantity, false);
        if (quote.collateral < minProceeds) revert Q.MinProceedsNotMet();
    }

    function simulate(Market memory market, uint32 scope, uint256 mask, uint128 quantity, bool isBuy)
        private
        pure
        returns (Q.Quote memory quote)
    {
        uint256 scale = QuoteMath.scale(market.decimals);
        F.Factor[] memory beforeWad = Q.toWad(market.factors, scale);
        uint256 depthBefore = depthWad(uint256(market.initialDepth) * scale, market.rate, beforeWad);
        uint128 limit = QuoteMath.fromWadDown(depthBefore, market.decimals);
        quote.factorsAfter = Q.updatedFactors(
            Q.Market(market.events, limit, market.decimals, market.factors, market.order), scope, mask, quantity, isBuy
        );
        QuoteMath.CostBounds memory before_ = F.bounds(market.events, depthBefore, beforeWad, market.order);
        price(market, before_, quote, isBuy);
        if (quote.collateral == 0 || (isBuy && quote.collateral > quantity)) revert Q.UnquotableTrade();
    }

    function price(Market memory market, QuoteMath.CostBounds memory before_, Q.Quote memory quote, bool isBuy)
        private
        pure
    {
        uint256 scale = QuoteMath.scale(market.decimals);
        F.Factor[] memory afterWad = Q.toWad(quote.factorsAfter, scale);
        uint256 depthAfter = depthWad(uint256(market.initialDepth) * scale, market.rate, afterWad);
        (QuoteMath.CostBounds memory after_, uint256 maximum) =
            F.boundsAndMax(market.events, depthAfter, afterWad, market.order);
        quote.collateral = isBuy
            ? QuoteMath.buyFromBounds(before_, after_, market.decimals)
            : QuoteMath.sellFromBounds(before_, after_, market.decimals);
        quote.maxLiabilityAfter = QuoteMath.fromWadUp(maximum, market.decimals);
    }
}
