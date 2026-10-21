// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {LsPricer} from "../src/LsPricer.sol";
import {LsQuote as L} from "../src/LsQuote.sol";
import {FactoredQuote as Q} from "../src/FactoredQuote.sol";
import {FactoredCost as F} from "../src/FactoredCost.sol";
import {QuoteMath} from "../src/QuoteMath.sol";

contract LsPricerTest {
    LsPricer private pricer;

    function setUp() public {
        pricer = new LsPricer();
    }

    function graph(uint16 bps) private pure returns (L.Market memory m) {
        uint128 unit = 1e6;
        m.events = 3;
        m.decimals = 6;
        m.initialDepth = 100 * unit;
        m.rate = L.depthRate(3, bps);
        m.order = new uint8[](3);
        m.order[0] = 2;
        m.order[2] = 1;
        m.factors = new Q.Factor[](5);
        uint32[5] memory scopes = [uint32(0), 1, 6, 5, 7];
        for (uint256 i; i < scopes.length; i++) {
            uint256 size;
            for (uint32 s = scopes[i]; s != 0; s &= s - 1) size++;
            m.factors[i].scope = scopes[i];
            m.factors[i].values = new uint128[](1 << size);
            for (uint256 j; j < m.factors[i].values.length; j++) {
                m.factors[i].values[j] = 20 * unit + uint128((i * 7 + j * 13) % 43) * unit / 10;
            }
        }
    }

    function values4(uint128 a, uint128 b, uint128 c, uint128 d) private pure returns (uint128[] memory v) {
        v = new uint128[](4);
        v[0] = a;
        v[1] = b;
        v[2] = c;
        v[3] = d;
    }

    function sameQuote(Q.Quote memory a, Q.Quote memory b) private pure {
        assert(a.collateral == b.collateral && a.maxLiabilityAfter == b.maxLiabilityAfter);
        assert(a.factorsAfter.length == b.factorsAfter.length);
        for (uint256 i; i < a.factorsAfter.length; i++) {
            assert(a.factorsAfter[i].scope == b.factorsAfter[i].scope);
            assert(a.factorsAfter[i].values.length == b.factorsAfter[i].values.length);
            for (uint256 j; j < a.factorsAfter[i].values.length; j++) {
                assert(a.factorsAfter[i].values[j] == b.factorsAfter[i].values[j]);
            }
        }
    }

    function expectRevert(L.Market memory m, uint32 scope, uint128[] memory delta, bool isBuy, bytes4 selector)
        private
        view
    {
        try pricer.quoteVector(m, scope, delta, isBuy) returns (uint128, uint128) {
            assert(false);
        } catch (bytes memory reason) {
            assert(reason.length == 4 && bytes4(reason) == selector);
        }
    }

    function testVersion() public view {
        assert(pricer.version() == 1);
    }

    function testDepthEqualsLsQuote() public view {
        assert(pricer.depth(graph(500)) == L.currentDepth(graph(500)));
    }

    function testQuoteClaimEqualsLsQuote() public view {
        uint32[6] memory scopes = [uint32(3), 5, 5, 7, 7, 1];
        uint256[6] memory masks = [uint256(8), 14, 14, 85, 85, 2];
        bool[6] memory buys = [true, true, false, true, false, false];
        uint16[3] memory rates = [uint16(100), 500, 2000];
        for (uint256 r; r < rates.length; r++) {
            for (uint256 i; i < scopes.length; i++) {
                Q.Quote memory direct = buys[i]
                    ? L.buy(graph(rates[r]), scopes[i], masks[i], 10e6, 10e6)
                    : L.sell(graph(rates[r]), scopes[i], masks[i], 10e6, 1);
                Q.Quote memory viaPricer =
                    pricer.quoteClaim(graph(rates[r]), scopes[i], masks[i], 10e6, buys[i] ? 10e6 : 1, buys[i]);
                sameQuote(direct, viaPricer);
            }
        }
    }

    function testQuoteClaimKeepsLimitErrors() public view {
        try pricer.quoteClaim(graph(500), 3, 8, 10e6, 1, true) returns (Q.Quote memory) {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == Q.MaxCostExceeded.selector);
        }
    }

    function testQuoteVectorMatchesUniformClaim() public view {
        Q.Quote memory claim = pricer.quoteClaim(graph(500), 3, 8, 10e6, 10e6, true);
        (uint128 collateral, uint128 maximum) = pricer.quoteVector(graph(500), 3, values4(0, 0, 0, 10e6), true);
        assert(collateral == claim.collateral && maximum == claim.maxLiabilityAfter);
        claim = pricer.quoteClaim(graph(500), 5, 14, 10e6, 1, false);
        (collateral, maximum) = pricer.quoteVector(graph(500), 5, values4(0, 10e6, 10e6, 10e6), false);
        assert(collateral == claim.collateral && maximum == claim.maxLiabilityAfter);
    }

    function testQuoteVectorChargesCostDifference() public view {
        L.Market memory m = graph(500);
        uint128[] memory delta = values4(3e6, 0, 3e6, 5e6);
        (uint128 collateral, uint128 maximum) = pricer.quoteVector(m, 3, delta, true);
        Q.Factor[] memory after_ = new Q.Factor[](m.factors.length + 1);
        for (uint256 i; i < m.factors.length; i++) after_[i] = m.factors[i];
        after_[m.factors.length] = Q.Factor(3, delta);
        (uint128 expected, uint128 expectedMaximum) = recomputed(m, after_);
        assert(collateral == expected && maximum == expectedMaximum);
        assert(collateral > 0 && collateral < 5e6);
    }

    function recomputed(L.Market memory m, Q.Factor[] memory after_) private pure returns (uint128, uint128) {
        F.Factor[] memory beforeWad = Q.toWad(m.factors, 1e12);
        uint256 depthBefore = L.depthWad(uint256(m.initialDepth) * 1e12, m.rate, beforeWad);
        QuoteMath.CostBounds memory before_ = F.bounds(m.events, depthBefore, beforeWad, m.order);
        F.Factor[] memory afterWad = Q.toWad(after_, 1e12);
        uint256 depthAfter = L.depthWad(uint256(m.initialDepth) * 1e12, m.rate, afterWad);
        (QuoteMath.CostBounds memory afterBounds, uint256 maxWad) = F.boundsAndMax(m.events, depthAfter, afterWad, m.order);
        return (QuoteMath.buyFromBounds(before_, afterBounds, 6), QuoteMath.fromWadUp(maxWad, 6));
    }

    function testQuoteVectorMergesIntoExistingTable() public view {
        L.Market memory m = graph(500);
        uint128[] memory delta = new uint128[](4);
        delta[1] = 2e6;
        delta[3] = 1e6;
        (uint128 viaVector,) = pricer.quoteVector(m, 6, delta, true);
        assert(viaVector > 0);
        (uint128 sold,) = pricer.quoteVector(m, 6, delta, false);
        assert(sold < viaVector);
    }

    function testQuoteVectorLimits() public view {
        expectRevert(graph(500), 3, values4(0, 0, 0, 0), true, Q.InvalidQuantity.selector);
        uint128[] memory short = new uint128[](3);
        short[0] = 1e6;
        expectRevert(graph(500), 3, short, true, Q.InvalidQuantity.selector);
        expectRevert(graph(500), 3, values4(0, 0, 0, 1000e6), true, Q.InvalidQuantity.selector);
        expectRevert(graph(500), 3, values4(0, 0, 0, 1e6), false, Q.InsufficientLiability.selector);
        uint128[] memory one = new uint128[](1);
        one[0] = 1e6;
        expectRevert(graph(500), 0, one, true, F.InvalidScope.selector);
        expectRevert(graph(500), 8, values4(0, 1e6, 0, 0), true, F.InvalidScope.selector);
        expectRevert(full(), 9, values4(0, 1e6, 0, 0), true, F.TooManyFactors.selector);
    }

    function full() private pure returns (L.Market memory m) {
        m.events = 32;
        m.decimals = 6;
        m.initialDepth = 100e6;
        m.rate = L.depthRate(32, 500);
        m.order = new uint8[](32);
        for (uint8 i; i < 32; i++) m.order[i] = i;
        m.factors = new Q.Factor[](64);
        for (uint256 i; i < 32; i++) {
            m.factors[i] = Q.Factor(uint32(1) << i, new uint128[](2));
        }
        for (uint256 i; i < 31; i++) {
            m.factors[32 + i] = Q.Factor((uint32(3) << i), new uint128[](4));
        }
        m.factors[63] = Q.Factor(5, new uint128[](4));
    }
}
