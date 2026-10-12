// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FactoredCost as F} from "../src/FactoredCost.sol";
import {FactoredQuote as Q} from "../src/FactoredQuote.sol";
import {LsQuote as L} from "../src/LsQuote.sol";
import {QuoteMath} from "../src/QuoteMath.sol";

contract LsQuoteHarness {
    function rate(uint8 events, uint16 bps) external pure returns (uint256) {
        return L.depthRate(events, bps);
    }

    function depth(uint256 initialWad, uint256 rate_, F.Factor[] memory factors) external pure returns (uint256) {
        return L.depthWad(initialWad, rate_, factors);
    }

    function buy(L.Market memory m, uint32 scope, uint256 mask, uint128 qty, uint128 limit)
        external
        pure
        returns (Q.Quote memory)
    {
        return L.buy(m, scope, mask, qty, limit);
    }

    function sell(L.Market memory m, uint32 scope, uint256 mask, uint128 qty, uint128 limit)
        external
        pure
        returns (Q.Quote memory)
    {
        return L.sell(m, scope, mask, qty, limit);
    }
}

contract LsQuoteTest {
    LsQuoteHarness private harness = new LsQuoteHarness();

    function market(uint8 events, uint128 initialDepth, uint16 bps) private pure returns (L.Market memory m) {
        m.events = events;
        m.initialDepth = initialDepth;
        m.rate = L.depthRate(events, bps);
        m.decimals = 6;
        m.factors = new Q.Factor[](0);
        m.order = new uint8[](events);
        for (uint8 i; i < events; i++) {
            m.order[i] = i;
        }
    }

    function graph() private pure returns (L.Market memory m) {
        m = market(3, 100e6, 500);
        m.order[0] = 2;
        m.order[1] = 0;
        m.order[2] = 1;
        uint32[5] memory scopes = [uint32(0), 1, 6, 5, 7];
        m.factors = new Q.Factor[](5);
        for (uint256 i; i < scopes.length; i++) {
            m.factors[i].scope = scopes[i];
            m.factors[i].values = new uint128[](uint256(1) << popcount(scopes[i]));
            for (uint256 j; j < m.factors[i].values.length; j++) {
                m.factors[i].values[j] = 20e6 + uint128((i * 7 + j * 13) % 43) * 1e6 / 10;
            }
        }
    }

    function yesTable(uint128 quantity) private pure returns (Q.Factor[] memory factors) {
        factors = new Q.Factor[](1);
        factors[0].scope = 1;
        factors[0].values = new uint128[](2);
        factors[0].values[1] = quantity;
    }

    function testDepthRateMatchesCommission() public pure {
        assert(L.depthRate(2, 500) == 36067376022224085);
        assert(L.depthRate(3, 1000) == 48089834696298780);
        assert(L.depthRate(32, 500) == 2254211001389005);
    }

    function testDepthRateRejectsOutOfRange() public {
        rejects(abi.encodeCall(harness.rate, (2, 99)), L.InvalidCommission.selector);
        rejects(abi.encodeCall(harness.rate, (2, 2001)), L.InvalidCommission.selector);
        rejects(abi.encodeCall(harness.rate, (0, 500)), F.InvalidEventCount.selector);
        rejects(abi.encodeCall(harness.rate, (33, 500)), F.InvalidEventCount.selector);
        assert(harness.rate(2, 100) == 7213475204444817);
        assert(harness.rate(2, 2000) == 144269504088896340);
    }

    function testDepthStartsAtInitialDepth() public pure {
        assert(L.depthWad(10e18, L.depthRate(2, 500), new F.Factor[](0)) == 10e18);
    }

    function testDepthAddsRateTimesMeanLiability() public pure {
        uint256 rate = L.depthRate(2, 500);
        assert(L.depthWad(10e18, rate, Q.toWad(yesTable(1e6), 1e12)) == 10018033688011112042);

        L.Market memory m = graph();
        F.Factor[] memory wad = Q.toWad(m.factors, 1e12);
        uint256 sum;
        for (uint32 state; state < 8; state++) {
            for (uint256 i; i < wad.length; i++) {
                sum += wad[i].values[project(wad[i].scope, state)];
            }
        }
        assert(L.depthWad(100e18, m.rate, wad) == 100e18 + Math.mulDiv(m.rate, sum, 8e18));
        assert(L.currentDepth(m) == 100e18 + Math.mulDiv(m.rate, sum, 8e18));
    }

    function testQuotesChargeTheCostDifferenceAtTwoDepths() public pure {
        L.Market memory m = graph();
        Q.Quote memory bought = L.buy(m, 3, 8, 10e6, type(uint128).max);
        (uint128 expected, uint128 maximum) = recompute(m, bought, true);
        assert(bought.collateral == expected && bought.maxLiabilityAfter == maximum);
        Q.Quote memory sold = L.sell(m, 5, 14, 10e6, 0);
        (expected, maximum) = recompute(m, sold, false);
        assert(sold.collateral == expected && sold.maxLiabilityAfter == maximum);
    }

    function recompute(L.Market memory m, Q.Quote memory quote, bool isBuy)
        private
        pure
        returns (uint128 collateral, uint128 maximum)
    {
        F.Factor[] memory beforeWad = Q.toWad(m.factors, 1e12);
        F.Factor[] memory afterWad = Q.toWad(quote.factorsAfter, 1e12);
        uint256 depthBefore = L.depthWad(100e18, m.rate, beforeWad);
        uint256 depthAfter = L.depthWad(100e18, m.rate, afterWad);
        assert(depthAfter != depthBefore);
        QuoteMath.CostBounds memory before_ = F.bounds(3, depthBefore, beforeWad, m.order);
        (QuoteMath.CostBounds memory after_, uint256 max_) = F.boundsAndMax(3, depthAfter, afterWad, m.order);
        collateral =
            isBuy ? QuoteMath.buyFromBounds(before_, after_, 6) : QuoteMath.sellFromBounds(before_, after_, 6);
        maximum = QuoteMath.fromWadUp(max_, 6);
    }

    function testQuantityLimitIsCurrentDepth() public {
        L.Market memory m = market(2, 10e6, 500);
        rejects(abi.encodeCall(harness.buy, (m, 1, 2, 10e6 + 1, type(uint128).max)), Q.InvalidQuantity.selector);
        harness.buy(m, 1, 2, 10e6, type(uint128).max);
        m.factors = yesTable(1e6);
        assert(L.currentDepth(m) == 10018033688011112042);
        harness.buy(m, 1, 2, 10_018_033, type(uint128).max);
        rejects(abi.encodeCall(harness.buy, (m, 1, 2, 10_018_034, type(uint128).max)), Q.InvalidQuantity.selector);
    }

    function testCompleteSetCostsMoreThanFixedDepth() public pure {
        L.Market memory m = market(2, 10e6, 500);
        uint128 yes = L.buy(m, 1, 2, 1e6, type(uint128).max).collateral;
        uint128 no = L.buy(m, 1, 1, 1e6, type(uint128).max).collateral;
        Q.Market memory fixedDepth = Q.Market(2, 10e6, 6, m.factors, m.order);
        uint128 fixedYes = Q.buy(fixedDepth, 1, 2, 1e6, type(uint128).max).collateral;
        uint128 fixedNo = Q.buy(fixedDepth, 1, 1, 1e6, type(uint128).max).collateral;
        assert(yes == no);
        assert(yes + no > fixedYes + fixedNo);
        assert(yes + no > 1e6);
    }

    function testSellAtDomainEdgeReverts() public {
        L.Market memory m = market(3, 1e6, 1000);
        m.factors = new Q.Factor[](2);
        m.factors[0].scope = 7;
        m.factors[0].values = new uint128[](8);
        m.factors[0].values[7] = 285e6;
        m.factors[1].scope = 1;
        m.factors[1].values = new uint128[](2);
        m.factors[1].values[0] = 10e6;
        uint256 depthBefore = L.currentDepth(m);
        assert(depthBefore == 2953649534537137937);
        assert(295e18 <= 100 * depthBefore);
        F.Factor[] memory afterWad = Q.toWad(m.factors, 1e12);
        afterWad[1].values[0] = 9e18;
        uint256 depthAfter = L.depthWad(1e18, m.rate, afterWad);
        assert(depthAfter == 2929604617188988547 && 100 * depthAfter < 294e18);
        rejects(abi.encodeCall(harness.sell, (m, 1, 1, 1e6, 0)), F.InvalidValues.selector);
    }

    function testSlippageLimits() public {
        L.Market memory m = market(2, 10e6, 500);
        uint128 cost = L.buy(m, 1, 2, 1e6, type(uint128).max).collateral;
        assert(cost == 537473);
        rejects(abi.encodeCall(harness.buy, (m, 1, 2, 1e6, cost - 1)), Q.MaxCostExceeded.selector);
        harness.buy(m, 1, 2, 1e6, cost);
        m.factors = yesTable(1e6);
        uint128 proceeds = L.sell(m, 1, 2, 1e6, 0).collateral;
        rejects(abi.encodeCall(harness.sell, (m, 1, 2, 1e6, proceeds + 1)), Q.MinProceedsNotMet.selector);
        harness.sell(m, 1, 2, 1e6, proceeds);
    }

    function rejects(bytes memory data, bytes4 expected) private {
        (bool ok, bytes memory result) = address(harness).call(data);
        assert(!ok && result.length == 4 && bytes4(result) == expected);
    }

    function project(uint32 scope, uint32 state) private pure returns (uint256 local) {
        uint256 index;
        while (scope != 0) {
            uint32 bit = scope & (~scope + 1);
            if (state & bit != 0) local |= uint256(1) << index;
            index++;
            scope &= scope - 1;
        }
    }

    function popcount(uint32 value) private pure returns (uint256 count) {
        while (value != 0) {
            value &= value - 1;
            count++;
        }
    }
}
