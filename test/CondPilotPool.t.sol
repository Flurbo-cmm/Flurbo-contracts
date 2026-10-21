// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ud} from "@prb/math/src/UD60x18.sol";
import {CondPilotPool} from "../src/CondPilotPool.sol";
import {LsPilotPool} from "../src/LsPilotPool.sol";
import {LsPricer} from "../src/LsPricer.sol";
import {WidePilotPool} from "../src/WidePilotPool.sol";
import {FactoredFunding} from "../src/FactoredFunding.sol";
import {ConditionalShape as S} from "../src/ConditionalShape.sol";
import {FactoredCost as F} from "../src/FactoredCost.sol";
import {FactoredQuote as Q} from "../src/FactoredQuote.sol";
import {ConditionalFixtureValues as FX} from "./ConditionalFixtures.t.sol";
import {MockCollateral} from "./helpers/MockCollateral.sol";

interface CondPoolVm {
    function chainId(uint256) external;
    function warp(uint256) external;
    function prank(address) external;
}

contract WrongVersionPricer {
    function version() external pure returns (uint8) {
        return 2;
    }
}

contract CondPilotPoolTest {
    CondPoolVm constant vm = CondPoolVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    event log_named_uint(string name, uint256 value);
    address constant SPONSOR = address(0x5905);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    bytes32 constant RULES = keccak256("conditional fixture");

    MockCollateral token;
    LsPricer pricer;

    function setUp() public {
        vm.chainId(10143);
        vm.warp(1000);
        token = new MockCollateral(6);
        pricer = new LsPricer();
    }

    function ordered(uint8 events) private pure returns (uint8[] memory result) {
        result = new uint8[](events);
        for (uint8 i; i < events; ++i) result[i] = i;
    }

    function shape(uint32 cs, uint256 cm, uint32 ts, uint256 tm) private pure returns (S.Shape memory) {
        return S.Shape(cs, cm, ts, tm);
    }

    function aGivesB() private pure returns (S.Shape memory) {
        return S.Shape(1, 2, 2, 2);
    }

    function deployWith(uint8 events, uint128 initialDepth, uint8[] memory order) private returns (CondPilotPool pool) {
        vm.prank(SPONSOR);
        pool = new CondPilotPool(address(token), events, initialDepth, 500, 2000, order, address(this), RULES, pricer);
        uint128 funding = pool.requiredFunding();
        token.mint(SPONSOR, funding);
        vm.prank(SPONSOR);
        token.approve(address(pool), funding);
        vm.prank(SPONSOR);
        pool.fund();
        for (uint256 i; i < 2; ++i) {
            address trader = i == 0 ? ALICE : BOB;
            token.mint(trader, 1000e6);
            vm.prank(trader);
            token.approve(address(pool), type(uint256).max);
        }
        token.mint(address(this), 1000e6);
        token.approve(address(pool), type(uint256).max);
    }

    function deploy(uint8 events) private returns (CondPilotPool) {
        return deployWith(events, 10e6, ordered(events));
    }

    function statePool() private returns (CondPilotPool pool) {
        pool = deploy(2);
        buyAs(BOB, pool, 1, 2, 8e6);
        buyAs(BOB, pool, 3, 8, 6e6);
    }

    function graphPool() private returns (CondPilotPool pool) {
        uint8[] memory order = new uint8[](3);
        order[0] = 2;
        order[2] = 1;
        pool = deployWith(3, 100e6, order);
        uint32[4] memory scopes = [uint32(1), 6, 5, 7];
        for (uint256 i; i < scopes.length; ++i) {
            uint256 states = scopes[i] == 1 ? 2 : scopes[i] == 7 ? 8 : 4;
            for (uint256 j; j < states; ++j) {
                buyAs(BOB, pool, scopes[i], uint256(1) << j, 20e6 + uint128(((i + 1) * 7 + j * 13) % 43) * 1e5);
            }
        }
    }

    function buyAs(address trader, WidePilotPool pool, uint32 scope, uint256 mask, uint128 quantity)
        private
        returns (uint128)
    {
        vm.prank(trader);
        return LsPilotPool(address(pool)).buy(scope, mask, quantity, type(uint128).max, block.timestamp);
    }

    function sellAs(address trader, WidePilotPool pool, uint32 scope, uint256 mask, uint128 quantity)
        private
        returns (uint128)
    {
        vm.prank(trader);
        return LsPilotPool(address(pool)).sell(scope, mask, quantity, 0, block.timestamp);
    }

    function buyConditionalAs(address trader, CondPilotPool pool, S.Shape memory s, uint128 shares, uint128 price)
        private
        returns (bytes32)
    {
        vm.prank(trader);
        return pool.buyConditional(s, shares, price, block.timestamp);
    }

    function sellConditionalAs(address trader, CondPilotPool pool, S.Shape memory s, uint128 shares)
        private
        returns (uint128)
    {
        vm.prank(trader);
        return pool.sellConditional(s, shares, 0, block.timestamp);
    }

    function expectBuyRevert(CondPilotPool pool, S.Shape memory s, uint128 shares, uint128 price, bytes4 selector)
        private
    {
        vm.prank(ALICE);
        try pool.buyConditional(s, shares, price, block.timestamp) returns (bytes32) {
            assert(false);
        } catch (bytes memory reason) {
            assert(reason.length == 4 && bytes4(reason) == selector);
        }
    }

    function within(uint256 actual, uint256 ideal, uint256 allowance) private pure {
        assert(actual >= ideal && actual - ideal <= allowance);
    }

    function testVersions() public {
        CondPilotPool pool = deploy(2);
        assert(pool.protocolVersion() == 5);
        assert(pool.conditionalVersion() == 1);
        assert(address(pool.pricer()) == address(pricer));
        assert(pool.sponsor() == SPONSOR);
        assert(pool.commissionBps() == 500);
        assert(pool.depthRate() == 36067376022224085);
        assert(pool.depth() == 10e18);
        assert(pool.MAX_SHAPES() == 256);
        assert(pool.shapeCount() == 0);
    }

    function testConstructorRejectsBadPricer() public {
        address[2] memory bad = [address(0xBEEF), address(new WrongVersionPricer())];
        for (uint256 i; i < bad.length; ++i) {
            try new CondPilotPool(address(token), 2, 10e6, 500, 2000, ordered(2), address(this), RULES, LsPricer(bad[i]))
            returns (CondPilotPool) {
                assert(false);
            } catch (bytes memory reason) {
                assert(reason.length == 4 && bytes4(reason) == CondPilotPool.InvalidPricer.selector);
            }
        }
    }

    function testConstructorRejectsCommissionOutsideRange() public {
        uint16[2] memory invalid = [uint16(99), 2001];
        for (uint256 i; i < invalid.length; ++i) {
            try new CondPilotPool(address(token), 2, 10e6, invalid[i], 2000, ordered(2), address(this), RULES, pricer)
            returns (CondPilotPool) {
                assert(false);
            } catch (bytes memory reason) {
                assert(reason.length == 4 && bytes4(reason) == FactoredFunding.InvalidConfiguration.selector);
            }
        }
    }

    function testRuntimeFitsEip170() public {
        CondPilotPool pool = deploy(32);
        emit log_named_uint("CondPilotPool runtime bytes", address(pool).code.length);
        emit log_named_uint("LsPricer runtime bytes", address(pricer).code.length);
        assert(address(pool).code.length <= 24576);
        assert(address(pricer).code.length <= 24576);
    }

    function sameState(LsPilotPool ls, CondPilotPool cond) private view {
        assert(ls.depth() == cond.depth());
        assert(ls.requiredCollateral() == cond.requiredCollateral());
        assert(ls.quoteBuy(4, 2, 1e6) == cond.quoteBuy(4, 2, 1e6));
        assert(ls.quoteBuy(7, 128, 1e6) == cond.quoteBuy(7, 128, 1e6));
        Q.Factor[] memory a = ls.factors();
        Q.Factor[] memory b = cond.factors();
        assert(a.length == b.length);
        for (uint256 i; i < a.length; ++i) {
            assert(a[i].scope == b[i].scope && a[i].values.length == b[i].values.length);
            for (uint256 j; j < a[i].values.length; ++j) assert(a[i].values[j] == b[i].values[j]);
        }
    }

    function testNormalClaimsMatchLsPilotPool() public {
        LsPilotPool ls = new LsPilotPool(address(token), 3, 10e6, 500, 2000, ordered(3), address(this), RULES);
        token.mint(address(this), ls.requiredFunding() + 1000e6);
        token.approve(address(ls), type(uint256).max);
        ls.fund();
        CondPilotPool cond = deploy(3);
        assert(ls.requiredFunding() == cond.requiredFunding());
        uint32[10] memory scopes = [uint32(1), 2, 3, 5, 7, 7, 1, 3, 6, 7];
        uint256[10] memory masks = [uint256(2), 1, 8, 14, 128, 254, 2, 8, 14, 128];
        uint128[10] memory quantities = [uint128(2e6), 1e6, 1e6, 1e6, 1e6, 1e6, 1e6, 5e5, 1e6, 1e6];
        bool[10] memory buys = [true, true, true, true, true, true, false, false, true, false];
        for (uint256 i; i < scopes.length; ++i) {
            if (buys[i]) {
                uint128 paid = ls.buy(scopes[i], masks[i], quantities[i], type(uint128).max, block.timestamp);
                assert(cond.quoteBuy(scopes[i], masks[i], quantities[i]) == paid);
                assert(cond.buy(scopes[i], masks[i], quantities[i], type(uint128).max, block.timestamp) == paid);
            } else {
                uint128 received = ls.sell(scopes[i], masks[i], quantities[i], 0, block.timestamp);
                assert(cond.quoteSell(scopes[i], masks[i], quantities[i]) == received);
                assert(cond.sell(scopes[i], masks[i], quantities[i], 0, block.timestamp) == received);
            }
            sameState(ls, cond);
        }
        vm.warp(2000);
        ls.resolve(5, 2);
        cond.resolve(5, 2);
        assert(ls.requiredCollateral() == cond.requiredCollateral());
        assert(ls.redeem(7, 254, 1e6) == cond.redeem(7, 254, 1e6));
        assert(ls.surplus() == cond.surplus());
    }

    function testBuyConditionalAtFairPrice() public {
        CondPilotPool pool = deploy(2);
        uint128 price = FX.EMPTY_B_GIVEN_A_PRICE_ATOMS;
        uint128 cost = pool.quoteConditionalBuy(aGivesB(), 1e6, price);
        within(cost, FX.EMPTY_B_GIVEN_A_COST_AT_PRICE, FX.EMPTY_B_GIVEN_A_ALLOWANCE);
        assert(cost <= price);
        assert(pool.quoteConditionalBuy(aGivesB(), 1e6, FX.EMPTY_B_GIVEN_A_FAIR_ATOMS - 2) > FX.EMPTY_B_GIVEN_A_FAIR_ATOMS - 2);
        expectBuyRevert(pool, aGivesB(), 1e6, FX.EMPTY_B_GIVEN_A_FAIR_ATOMS - 2, CondPilotPool.PriceBelowCost.selector);
        uint256 before = token.balanceOf(ALICE);
        bytes32 key = buyConditionalAs(ALICE, pool, aGivesB(), 1e6, price);
        assert(before - token.balanceOf(ALICE) == price);
        assert(key == keccak256(abi.encode(uint32(1), uint256(2), uint32(2), uint256(2))));
        (uint128 shares, uint128 refund) = pool.conditionalHolding(ALICE, key);
        assert(shares == 1e6 && refund == price);
        Q.Factor[] memory stored = pool.factors();
        assert(stored.length == 1 && stored[0].scope == 3);
        assert(stored[0].values[0] == price && stored[0].values[1] == 0);
        assert(stored[0].values[2] == price && stored[0].values[3] == 1e6);
        assert(pool.requiredCollateral() == FX.EMPTY_B_GIVEN_A_MAX_AFTER);
        assert(token.balanceOf(address(pool)) >= pool.requiredCollateral());
    }

    function testPriceAboveSharesReverts() public {
        CondPilotPool pool = deploy(2);
        expectBuyRevert(pool, aGivesB(), 1e6, 1e6 + 1, CondPilotPool.InvalidPrice.selector);
    }

    function testZeroReverts() public {
        CondPilotPool pool = deploy(2);
        expectBuyRevert(pool, aGivesB(), 0, 0, CondPilotPool.InvalidPrice.selector);
        expectBuyRevert(pool, aGivesB(), 1e6, 0, CondPilotPool.InvalidPrice.selector);
        expectBuyRevert(pool, shape(1, 2, 1, 2), 1e6, 9e5, S.InvalidShape.selector);
    }

    function testTooCertainConditionalIsRefused() public {
        CondPilotPool pool = deploy(2);
        for (uint256 round; round < 4; ++round) {
            buyAs(BOB, pool, 3, 1, 10e6);
            buyAs(BOB, pool, 3, 4, 10e6);
            buyAs(BOB, pool, 3, 8, 10e6);
        }
        assert(pool.quoteConditionalBuy(aGivesB(), 1e6, 1e6) >= FX.TOO_CERTAIN_COST_AT_SHARES);
        expectBuyRevert(pool, aGivesB(), 1e6, 1e6, CondPilotPool.PriceBelowCost.selector);
        expectBuyRevert(pool, aGivesB(), 1e6, 1e6 + 1, CondPilotPool.InvalidPrice.selector);
    }

    function testDeadlineAndCloseRefuse() public {
        CondPilotPool pool = deploy(2);
        vm.prank(ALICE);
        try pool.buyConditional(aGivesB(), 1e6, 9e5, block.timestamp - 1) returns (bytes32) {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == bytes4(keccak256("ExpiredDeadline()")));
        }
        vm.warp(2000);
        expectBuyRevert(pool, aGivesB(), 1e6, 9e5, bytes4(keccak256("Closed()")));
    }

    function testQuoteMatchesFixtures() public {
        CondPilotPool pool = statePool();
        uint128 cost = pool.quoteConditionalBuy(aGivesB(), 1e6, FX.STATE_B_GIVEN_A_PRICE_ATOMS);
        within(cost, FX.STATE_B_GIVEN_A_COST_AT_PRICE, FX.STATE_B_GIVEN_A_ALLOWANCE);
        assert(cost <= FX.STATE_B_GIVEN_A_PRICE_ATOMS);
        cost = pool.quoteConditionalBuy(shape(1, 1, 2, 2), 1e6, FX.STATE_B_GIVEN_NOT_A_PRICE_ATOMS);
        within(cost, FX.STATE_B_GIVEN_NOT_A_COST_AT_PRICE, FX.STATE_B_GIVEN_NOT_A_ALLOWANCE);
        assert(cost <= FX.STATE_B_GIVEN_NOT_A_PRICE_ATOMS);
        cost = pool.quoteConditionalBuy(aGivesB(), 5e6, FX.STATE_FIVE_B_GIVEN_A_PRICE_ATOMS);
        within(cost, FX.STATE_FIVE_B_GIVEN_A_COST_AT_PRICE, FX.STATE_FIVE_B_GIVEN_A_ALLOWANCE);
        assert(cost <= FX.STATE_FIVE_B_GIVEN_A_PRICE_ATOMS);
        CondPilotPool graph = graphPool();
        cost = graph.quoteConditionalBuy(shape(1, 2, 6, 8), 2e6, FX.THREE_QUESTION_TWO_TARGET_PRICE_ATOMS);
        within(cost, FX.THREE_QUESTION_TWO_TARGET_COST_AT_PRICE, FX.THREE_QUESTION_TWO_TARGET_ALLOWANCE);
        assert(cost <= FX.THREE_QUESTION_TWO_TARGET_PRICE_ATOMS);
        buyConditionalAs(ALICE, graph, shape(1, 2, 6, 8), 2e6, FX.THREE_QUESTION_TWO_TARGET_PRICE_ATOMS);
        assert(graph.requiredCollateral() == FX.THREE_QUESTION_TWO_TARGET_MAX_AFTER);
        CondPilotPool near = deploy(2);
        for (uint256 round; round < 6; ++round) {
            buyAs(BOB, near, 3, 8, 10e6);
            buyAs(BOB, near, 3, 7, 10e6);
        }
        for (uint256 round; round < 6; ++round) sellAs(BOB, near, 3, 7, 10e6);
        Q.Factor[] memory stored = near.factors();
        assert(stored.length == 1 && stored[0].values[0] == 0 && stored[0].values[3] == 60e6);
        cost = near.quoteConditionalBuy(aGivesB(), 1e6, FX.NEAR_CERTAIN_PRICE_ATOMS);
        within(cost, FX.NEAR_CERTAIN_COST_AT_PRICE, FX.NEAR_CERTAIN_ALLOWANCE);
        assert(cost <= FX.NEAR_CERTAIN_PRICE_ATOMS && FX.NEAR_CERTAIN_PRICE_ATOMS < 1e6);
    }

    function chances(CondPilotPool pool) private view returns (uint256 a, uint256 bGivenA) {
        Q.Factor[] memory stored = pool.factors();
        uint256 d = pool.depth();
        uint256[4] memory liability;
        for (uint256 i; i < stored.length; ++i) {
            for (uint256 x; x < 4; ++x) {
                uint256 local = stored[i].scope == 3 ? x : stored[i].scope == 1 ? x & 1 : x >> 1;
                liability[x] += uint256(stored[i].values[local]) * 1e12;
            }
        }
        uint256[4] memory w;
        uint256 total;
        for (uint256 x; x < 4; ++x) {
            w[x] = ud(liability[x] * 1e18 / d).exp().unwrap();
            total += w[x];
        }
        a = (w[1] + w[3]) * 1e18 / total;
        bGivenA = w[3] * 1e18 / (w[1] + w[3]);
    }

    function testConditionalBarelyMovesCondition() public {
        CondPilotPool pool = statePool();
        (uint256 aBefore, uint256 bBefore) = chances(pool);
        buyConditionalAs(ALICE, pool, aGivesB(), 5e6, FX.STATE_FIVE_B_GIVEN_A_PRICE_ATOMS);
        (uint256 aAfter, uint256 bAfter) = chances(pool);
        uint256 moved = aBefore > aAfter ? aBefore - aAfter : aAfter - aBefore;
        assert(moved < 0.01e18);
        assert(bAfter > bBefore && bAfter - bBefore > 0.09e18);
        emit log_named_uint("chance of A before (WAD)", aBefore);
        emit log_named_uint("chance of A after (WAD)", aAfter);
        emit log_named_uint("chance of B given A before (WAD)", bBefore);
        emit log_named_uint("chance of B given A after (WAD)", bAfter);
    }

    function testSellPartialKeepsProportionalRefund() public {
        CondPilotPool pool = statePool();
        uint128 price = FX.STATE_FIVE_B_GIVEN_A_PRICE_ATOMS;
        bytes32 key = buyConditionalAs(ALICE, pool, aGivesB(), 5e6, price);
        (uint128 quoted, uint128 removed) = pool.quoteConditionalSell(aGivesB(), ALICE, 2e6);
        assert(removed == uint128(uint256(price) * 2 / 5));
        uint128 received = sellConditionalAs(ALICE, pool, aGivesB(), 2e6);
        assert(received == quoted);
        (uint128 shares, uint128 refund) = pool.conditionalHolding(ALICE, key);
        assert(shares == 3e6 && refund == price - uint128(uint256(price) * 2 / 5));
        sellConditionalAs(ALICE, pool, aGivesB(), 3e6);
        (shares, refund) = pool.conditionalHolding(ALICE, key);
        assert(shares == 0 && refund == 0);
        Q.Factor[] memory stored = pool.factors();
        assert(stored.length == 2 && stored[1].scope == 3);
        assert(stored[1].values[0] == 0 && stored[1].values[1] == 0 && stored[1].values[2] == 0 && stored[1].values[3] == 6e6);
        vm.prank(ALICE);
        try pool.sellConditional(aGivesB(), 1, 0, block.timestamp) returns (uint128) {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == CondPilotPool.NoConditionalHolding.selector);
        }
    }

    function testSellRespectsMinimumProceeds() public {
        CondPilotPool pool = statePool();
        buyConditionalAs(ALICE, pool, aGivesB(), 1e6, FX.STATE_B_GIVEN_A_PRICE_ATOMS);
        (uint128 quoted,) = pool.quoteConditionalSell(aGivesB(), ALICE, 1e6);
        vm.prank(ALICE);
        try pool.sellConditional(aGivesB(), 1e6, quoted + 1, block.timestamp) returns (uint128) {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == Q.MinProceedsNotMet.selector);
        }
    }

    function testRoundTripNeverProfits() public {
        CondPilotPool pool = statePool();
        uint256 before = token.balanceOf(ALICE);
        buyConditionalAs(ALICE, pool, aGivesB(), 5e6, FX.STATE_FIVE_B_GIVEN_A_PRICE_ATOMS);
        uint128 received = sellConditionalAs(ALICE, pool, aGivesB(), 5e6);
        assert(received <= FX.STATE_FIVE_B_GIVEN_A_PRICE_ATOMS);
        assert(token.balanceOf(ALICE) <= before);
    }

    function testRedeemPaysEachCase() public {
        uint32[5] memory yes = [uint32(3), 1, 2, 2, 0];
        uint32[5] memory voids = [uint32(0), 0, 0, 1, 1];
        uint128[5] memory expected = [FX.PAYOUT_A_YES_B_YES, FX.PAYOUT_A_YES_B_NO, FX.PAYOUT_A_NO,
            FX.PAYOUT_A_VOID_B_YES, FX.PAYOUT_A_VOID_B_NO];
        for (uint256 i; i < yes.length; ++i) {
            CondPilotPool pool = statePool();
            buyConditionalAs(ALICE, pool, aGivesB(), 5e6, FX.STATE_FIVE_B_GIVEN_A_PRICE_ATOMS);
            vm.warp(2000);
            pool.resolve(yes[i], voids[i]);
            assert(pool.conditionalPayout(aGivesB(), ALICE) == expected[i]);
            uint256 before = token.balanceOf(ALICE);
            vm.prank(ALICE);
            assert(pool.redeemConditional(aGivesB()) == expected[i]);
            assert(token.balanceOf(ALICE) - before == expected[i]);
            vm.prank(ALICE);
            try pool.redeemConditional(aGivesB()) returns (uint128) {
                assert(false);
            } catch (bytes memory reason) {
                assert(bytes4(reason) == CondPilotPool.NoConditionalHolding.selector);
            }
            assert(token.balanceOf(address(pool)) >= pool.requiredCollateral());
            vm.warp(1000);
        }
    }

    function testRedeemBeforeResolutionReverts() public {
        CondPilotPool pool = statePool();
        buyConditionalAs(ALICE, pool, aGivesB(), 1e6, FX.STATE_B_GIVEN_A_PRICE_ATOMS);
        vm.prank(ALICE);
        try pool.redeemConditional(aGivesB()) returns (uint128) {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == WidePilotPool.NotResolved.selector);
        }
    }

    function testNormalAndConditionalHoldersBothPaid() public {
        CondPilotPool pool = deploy(2);
        buyAs(BOB, pool, 3, 8, 2e6);
        buyConditionalAs(ALICE, pool, aGivesB(), 1e6, 8e5);
        vm.warp(2000);
        pool.resolve(3, 0);
        assert(pool.requiredCollateral() == 3e6);
        vm.prank(BOB);
        assert(pool.redeem(3, 8, 2e6) == 2e6);
        vm.prank(ALICE);
        assert(pool.redeemConditional(aGivesB()) == 1e6);
        assert(pool.requiredCollateral() == 0);
        assert(pool.surplus() == token.balanceOf(address(pool)));
    }

    function testSurplusReservesConditionalPayouts() public {
        CondPilotPool pool = statePool();
        buyConditionalAs(ALICE, pool, aGivesB(), 5e6, FX.STATE_FIVE_B_GIVEN_A_PRICE_ATOMS);
        buyConditionalAs(BOB, pool, shape(1, 1, 2, 2), 1e6, 9e5);
        vm.warp(2000);
        uint256 sponsorBefore = token.balanceOf(SPONSOR);
        pool.withdrawSurplus();
        assert(token.balanceOf(address(pool)) == pool.requiredCollateral());
        pool.resolve(2, 1);
        uint128 owed = pool.requiredCollateral();
        if (pool.surplus() > 0) pool.withdrawSurplus();
        assert(token.balanceOf(address(pool)) == owed);
        uint256 paid;
        vm.prank(ALICE);
        paid += pool.redeemConditional(aGivesB());
        vm.prank(BOB);
        paid += pool.redeemConditional(shape(1, 1, 2, 2));
        vm.prank(BOB);
        paid += pool.redeem(1, 2, 8e6);
        vm.prank(BOB);
        paid += pool.redeem(3, 8, 6e6);
        assert(paid <= owed && owed - paid <= 2);
        assert(token.balanceOf(address(pool)) == owed - paid);
        assert(token.balanceOf(SPONSOR) > sponsorBefore);
    }

    function testWidthRuleRefusesConditional() public {
        CondPilotPool pool = deploy(4);
        buyAs(BOB, pool, 7, 128, 1e6);
        expectBuyRevert(pool, shape(1, 2, 8, 2), 1e6, 9e5, F.WidthExceeded.selector);
        buyConditionalAs(ALICE, pool, shape(1, 2, 2, 2), 1e6, 9e5);
    }

    function testShapesEnumerate() public {
        CondPilotPool pool = deploy(6);
        S.Shape[3] memory first = [shape(1, 2, 2, 2), shape(2, 1, 1, 2), shape(1, 2, 6, 8)];
        for (uint256 i; i < first.length; ++i) buyConditionalAs(ALICE, pool, first[i], 1000, 1000);
        buyConditionalAs(BOB, pool, first[0], 1000, 1000);
        assert(pool.shapeCount() == 3);
        for (uint256 i; i < first.length; ++i) {
            (bytes32 key, S.Shape memory stored) = pool.shapeAt(i);
            assert(key == keccak256(abi.encode(first[i].conditionScope, first[i].conditionMask,
                first[i].targetScope, first[i].targetMask)));
            assert(stored.conditionScope == first[i].conditionScope && stored.conditionMask == first[i].conditionMask);
            assert(stored.targetScope == first[i].targetScope && stored.targetMask == first[i].targetMask);
        }
        uint256 count = 3;
        for (uint32 base; base < 6 && count < 257; base += 3) {
            uint32 triple = uint32(7) << base;
            for (uint32 c; c < 3 && count < 257; ++c) {
                uint32 single = uint32(1) << (base + c);
                uint32 pair = triple & ~single;
                for (uint256 flip; flip < 2 && count < 257; ++flip) {
                    for (uint256 sm = 1; sm <= 2 && count < 257; ++sm) {
                        for (uint256 pm = 1; pm <= 14 && count < 257; ++pm) {
                            S.Shape memory s = flip == 0 ? shape(single, sm, pair, pm) : shape(pair, pm, single, sm);
                            if (alreadyBought(first, s)) continue;
                            if (count == 256) {
                                expectBuyRevert(pool, s, 1000, 1000, CondPilotPool.TooManyShapes.selector);
                                buyConditionalAs(ALICE, pool, first[1], 1000, 1000);
                            } else {
                                buyConditionalAs(ALICE, pool, s, 1000, 1000);
                            }
                            count++;
                        }
                    }
                }
            }
        }
        assert(count == 257 && pool.shapeCount() == 256);
    }

    function alreadyBought(S.Shape[3] memory first, S.Shape memory s) private pure returns (bool) {
        for (uint256 i; i < first.length; ++i) {
            if (first[i].conditionScope == s.conditionScope && first[i].conditionMask == s.conditionMask
                && first[i].targetScope == s.targetScope && first[i].targetMask == s.targetMask) return true;
        }
        return false;
    }

    function fuzzShape(uint256 r) private pure returns (S.Shape memory) {
        uint256 pick = r % 6;
        if (pick == 0) return S.Shape(1, 2, 2, 2);
        if (pick == 1) return S.Shape(1, 1, 2, 2);
        if (pick == 2) return S.Shape(2, 2, 4, 1);
        if (pick == 3) return S.Shape(1, 2, 6, 8);
        if (pick == 4) return S.Shape(3, 8, 4, 2);
        return S.Shape(4, 2, 3, 14);
    }

    function testFuzzMixedTradesStaySolvent(uint256 seed) public {
        CondPilotPool pool = deploy(3);
        for (uint256 step; step < 16; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 kind = r % 4;
            uint128 quantity = uint128(1 + (r >> 16) % 5e6);
            if (kind < 2) {
                uint32 scope = uint32(1 + (r >> 8) % 7);
                uint256 states = scope == 7 ? 8 : scope == 3 || scope == 5 || scope == 6 ? 4 : 2;
                uint256 mask = 1 + (r >> 40) % ((uint256(1) << states) - 2);
                uint128 held = pool.holdings(address(this), scope, mask);
                if (kind == 1 && held != 0) {
                    try pool.sell(scope, mask, quantity > held ? held : quantity, 0, block.timestamp) {} catch {}
                } else {
                    try pool.buy(scope, mask, quantity, type(uint128).max, block.timestamp) {} catch {}
                }
            } else {
                S.Shape memory s = fuzzShape(r >> 64);
                (uint128 heldShares,) = pool.conditionalHolding(address(this), keccak256(abi.encode(
                    s.conditionScope, s.conditionMask, s.targetScope, s.targetMask)));
                if (kind == 3 && heldShares != 0) {
                    try pool.sellConditional(s, quantity > heldShares ? heldShares : quantity, 0, block.timestamp) {} catch {}
                } else {
                    uint128 price = uint128(uint256(quantity) * (300 + (r >> 128) % 701) / 1000);
                    if (price == 0) price = 1;
                    try pool.buyConditional(s, quantity, price, block.timestamp) {} catch {}
                }
            }
            assert(token.balanceOf(address(pool)) >= pool.requiredCollateral());
        }
        vm.warp(2000);
        uint32 yesMask = uint32(seed % 8);
        uint32 voidMask = uint32((seed >> 3) % 8) & ~yesMask;
        pool.resolve(yesMask, voidMask);
        uint256 owed = pool.requiredCollateral();
        uint256 balance = token.balanceOf(address(pool));
        uint256 paid;
        for (uint32 scope = 1; scope <= 7; ++scope) {
            uint256 states = scope == 7 ? 8 : scope == 3 || scope == 5 || scope == 6 ? 4 : 2;
            for (uint256 mask = 1; mask < (uint256(1) << states) - 1; ++mask) {
                uint128 held = pool.holdings(address(this), scope, mask);
                if (held != 0) paid += pool.redeem(scope, mask, held);
            }
        }
        for (uint256 i; i < pool.shapeCount(); ++i) {
            (bytes32 key, S.Shape memory s) = pool.shapeAt(i);
            (uint128 heldShares,) = pool.conditionalHolding(address(this), key);
            if (heldShares != 0) paid += pool.redeemConditional(s);
        }
        assert(paid <= owed);
        assert(token.balanceOf(address(pool)) == balance - paid);
        assert(token.balanceOf(address(pool)) >= pool.requiredCollateral());
    }
}
