// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {FactoredCost as F} from "./FactoredCost.sol";
import {FactoredQuote as Q} from "./FactoredQuote.sol";
import {LsQuote as L} from "./LsQuote.sol";
import {QuoteMath} from "./QuoteMath.sol";

/// @notice Stateless liquidity-sensitive quotes for pools that keep their tables in storage.
/// @dev Claims are priced by LsQuote unchanged. A vector adds possibly different amounts to the states of one table.
contract LsPricer {
    function version() external pure returns (uint8) { return 1; }

    function quoteClaim(L.Market memory m, uint32 scope, uint256 mask, uint128 quantity, uint128 limit, bool isBuy)
        external
        pure
        returns (Q.Quote memory)
    {
        return isBuy ? L.buy(m, scope, mask, quantity, limit) : L.sell(m, scope, mask, quantity, limit);
    }

    function quoteVector(L.Market memory m, uint32 scope, uint128[] memory delta, bool isBuy)
        external
        pure
        returns (uint128 collateral, uint128 maxLiabilityAfter)
    {
        (QuoteMath.CostBounds memory before_, Q.Factor[] memory after_) = prepared(m, scope, delta, isBuy);
        (collateral, maxLiabilityAfter) = bounds(m, before_, after_, isBuy);
        if (collateral == 0) revert Q.UnquotableTrade();
    }

    function depth(L.Market memory m) external pure returns (uint256) {
        return L.currentDepth(m);
    }

    function prepared(L.Market memory m, uint32 scope, uint128[] memory delta, bool isBuy)
        private
        pure
        returns (QuoteMath.CostBounds memory before_, Q.Factor[] memory after_)
    {
        uint256 scale = QuoteMath.scale(m.decimals);
        F.Factor[] memory beforeWad = Q.toWad(m.factors, scale);
        uint256 depthBefore = L.depthWad(uint256(m.initialDepth) * scale, m.rate, beforeWad);
        checkDelta(m.events, scope, delta, QuoteMath.fromWadDown(depthBefore, m.decimals));
        after_ = merged(m.factors, scope, delta, isBuy);
        before_ = F.bounds(m.events, depthBefore, beforeWad, m.order);
    }

    function checkDelta(uint8 events, uint32 scope, uint128[] memory delta, uint128 limit) private pure {
        uint256 size;
        for (uint32 s = scope; s != 0; s &= s - 1) {
            size++;
        }
        if (scope == 0 || uint256(scope) >> events != 0 || size > 3) revert F.InvalidScope();
        if (delta.length != uint256(1) << size) revert Q.InvalidQuantity();
        bool any;
        for (uint256 j; j < delta.length; j++) {
            if (delta[j] > limit) revert Q.InvalidQuantity();
            if (delta[j] != 0) any = true;
        }
        if (!any) revert Q.InvalidQuantity();
    }

    /// @dev The changed table goes last, as in FactoredQuote.update.
    function merged(Q.Factor[] memory factors, uint32 scope, uint128[] memory delta, bool isBuy)
        private
        pure
        returns (Q.Factor[] memory after_)
    {
        uint256 matches;
        for (uint256 i; i < factors.length; i++) {
            if (factors[i].scope == scope) matches++;
        }
        if (factors.length + 1 - matches > 64) revert F.TooManyFactors();
        after_ = new Q.Factor[](factors.length + 1 - matches);
        uint128[] memory values = new uint128[](delta.length);
        uint256 cursor;
        for (uint256 i; i < factors.length; i++) {
            if (factors[i].scope != scope) {
                after_[cursor++] = factors[i];
                continue;
            }
            for (uint256 j; j < values.length; j++) {
                values[j] += factors[i].values[j];
            }
        }
        for (uint256 j; j < values.length; j++) {
            if (isBuy) {
                values[j] += delta[j];
            } else {
                if (values[j] < delta[j]) revert Q.InsufficientLiability();
                values[j] -= delta[j];
            }
        }
        after_[cursor] = Q.Factor(scope, values);
    }

    function bounds(L.Market memory m, QuoteMath.CostBounds memory before_, Q.Factor[] memory after_, bool isBuy)
        private
        pure
        returns (uint128 collateral, uint128 maxLiabilityAfter)
    {
        uint256 scale = QuoteMath.scale(m.decimals);
        F.Factor[] memory afterWad = Q.toWad(after_, scale);
        uint256 depthAfter = L.depthWad(uint256(m.initialDepth) * scale, m.rate, afterWad);
        (QuoteMath.CostBounds memory afterBounds, uint256 maximum) = F.boundsAndMax(m.events, depthAfter, afterWad, m.order);
        collateral = isBuy
            ? QuoteMath.buyFromBounds(before_, afterBounds, m.decimals)
            : QuoteMath.sellFromBounds(before_, afterBounds, m.decimals);
        maxLiabilityAfter = QuoteMath.fromWadUp(maximum, m.decimals);
    }
}
