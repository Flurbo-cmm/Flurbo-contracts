// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {HybridPilotResolver as R} from "../src/HybridPilotResolver.sol";
import {LsPilotPool} from "../src/LsPilotPool.sol";
import {WidePilotPool} from "../src/WidePilotPool.sol";
import {CondPilotPool} from "../src/CondPilotPool.sol";
import {LsPricer} from "../src/LsPricer.sol";
import {ConditionalShape as S} from "../src/ConditionalShape.sol";
import {MockCollateral} from "./helpers/MockCollateral.sol";

interface HybridVm {
    function chainId(uint256) external;
    function warp(uint256) external;
    function prank(address) external;
}

contract HybridPilotLifecycleTest {
    HybridVm constant vm = HybridVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant PROPOSER = address(0xA11CE);
    address constant CHALLENGER = address(0xB0B);
    address constant RELAY = address(0xBEEF);
    bytes32 constant EVIDENCE = keccak256("source capture");
    bytes32 constant CASE_ID = keccak256("sepolia case");

    MockCollateral token;
    R resolver;
    LsPilotPool pool;

    function setUp() public {
        vm.chainId(10143);
        vm.warp(1000);
        token = new MockCollateral(6);
        R.Config memory c;
        c.collateral = address(token);
        c.draftHash = keccak256("hybrid synthetic fixture");
        c.closesAt = 2000;
        c.eventHashes = new bytes32[](2);
        c.eventHashes[0] = bytes32(uint256(1));
        c.eventHashes[1] = bytes32(uint256(2));
        c.observationEnds = new uint64[](2);
        c.observationEnds[0] = 3000;
        c.observationEnds[1] = 3000;
        c.routes = new R.Route[](2);
        c.routes[0] = R.Route.Mechanical;
        c.routes[1] = R.Route.Reality;
        c.proposer = PROPOSER;
        c.relay = RELAY;
        c.bond = 1e6;
        c.assertionPeriod = 3600;
        c.challengePeriod = 3600;
        c.reportPeriod = 90 days;
        c.arbitrationPeriod = 90 days;
        resolver = new R(c);
        uint8[] memory order = new uint8[](2);
        order[0] = 0;
        order[1] = 1;
        pool = new LsPilotPool(address(token), 2, 10e6, 500, 2000, order, address(resolver), resolver.rulesHash());
        resolver.bindPool(address(pool));
        token.mint(address(this), pool.requiredFunding());
        token.approve(address(pool), pool.requiredFunding());
        pool.fund();
        token.mint(PROPOSER, 10e6);
        token.mint(CHALLENGER, 10e6);
        vm.prank(PROPOSER); token.approve(address(resolver), type(uint256).max);
        vm.prank(CHALLENGER); token.approve(address(resolver), type(uint256).max);
    }

    function callAs(address sender, bytes memory data) internal returns (bool ok) {
        vm.prank(sender);
        (ok,) = address(resolver).call(data);
    }

    function realityPair() internal returns (R r, LsPilotPool p) {
        R.Config memory c;
        c.collateral = address(token);
        c.draftHash = keccak256("all reality fixture");
        c.closesAt = 2000;
        c.eventHashes = new bytes32[](2);
        c.eventHashes[0] = bytes32(uint256(1));
        c.eventHashes[1] = bytes32(uint256(2));
        c.observationEnds = new uint64[](2);
        c.observationEnds[0] = 3000;
        c.observationEnds[1] = 3000;
        c.routes = new R.Route[](2);
        c.routes[0] = R.Route.Reality;
        c.routes[1] = R.Route.Reality;
        c.proposer = PROPOSER;
        c.relay = RELAY;
        c.bond = 1e6;
        c.assertionPeriod = 3600;
        c.challengePeriod = 3600;
        c.reportPeriod = 90 days;
        c.arbitrationPeriod = 90 days;
        r = new R(c);
        uint8[] memory order = new uint8[](2);
        order[0] = 0;
        order[1] = 1;
        p = new LsPilotPool(address(token), 2, 10e6, 500, 2000, order, address(r), r.rulesHash());
        r.bindPool(address(p));
        token.mint(address(this), p.requiredFunding());
        token.approve(address(p), p.requiredFunding());
        p.fund();
    }

    function callOn(R target, address sender, bytes memory data) internal returns (bool ok) {
        vm.prank(sender);
        (ok,) = address(target).call(data);
    }

    function testAllRealityPoolReportsAndDelivers() public {
        (R r, LsPilotPool p) = realityPair();
        vm.warp(3000);
        vm.prank(RELAY); r.reportReality(0, R.Outcome.Yes, EVIDENCE, "https://example.org/zero.json");
        vm.prank(RELAY); r.reportReality(1, R.Outcome.No, EVIDENCE, "https://example.org/one.json");
        r.deliver();
        assert(p.resolved());
        assert(p.resolvedState() == 1);
        assert(p.voidMask() == 0);
    }

    function testRealityReportOutsideWindowRejected() public {
        (R r,) = realityPair();
        bytes memory data = abi.encodeCall(R.reportReality, (0, R.Outcome.Yes, EVIDENCE, "https://example.org/zero.json"));
        vm.warp(2999);
        assert(!callOn(r, RELAY, data));
        vm.warp(3000 + 90 days);
        assert(!callOn(r, RELAY, data));
    }

    function testRealityMissingReportBecomesVoid() public {
        (R r,) = realityPair();
        vm.warp(3000 + 90 days);
        r.finalize(0);
        R.Case memory result = r.caseState(0);
        assert(result.phase == R.Phase.Finalized && result.result == R.Outcome.Void);
    }

    function testRealityReportedOnce() public {
        (R r,) = realityPair();
        vm.warp(3000);
        bytes memory data = abi.encodeCall(R.reportReality, (0, R.Outcome.Yes, EVIDENCE, "https://example.org/zero.json"));
        assert(callOn(r, RELAY, data));
        assert(!callOn(r, RELAY, data));
    }

    function testRealityReportOnlyByRelay() public {
        (R r,) = realityPair();
        vm.warp(3000);
        assert(!callOn(r, PROPOSER, abi.encodeCall(R.reportReality,
            (0, R.Outcome.Yes, EVIDENCE, "https://example.org/zero.json"))));
    }

    function testUnchallengedMechanicalAndRealityDeliver() public {
        vm.warp(3000);
        vm.prank(PROPOSER);
        resolver.propose(0, R.Outcome.Yes, EVIDENCE, "https://example.org/mechanical.json");
        vm.prank(RELAY);
        resolver.reportReality(1, R.Outcome.No, EVIDENCE, "https://example.org/reality.json");
        assert(!callAs(CHALLENGER, abi.encodeCall(R.deliver, ())));
        vm.warp(6600);
        resolver.finalize(0);
        assert(resolver.credits(PROPOSER) == 1e6);
        assert(resolver.lockedBonds() == 0);
        resolver.deliver();
        assert(pool.resolved());
        assert(pool.resolvedState() == 1);
        assert(pool.voidMask() == 0);
        vm.prank(PROPOSER); resolver.withdrawBond();
        assert(token.balanceOf(PROPOSER) == 10e6);
    }

    function testChallengeFreezesShortTimerUntilLinkedRuling() public {
        vm.warp(3000);
        vm.prank(PROPOSER);
        resolver.propose(0, R.Outcome.Yes, EVIDENCE, "https://example.org/proposal.json");
        vm.prank(CHALLENGER);
        resolver.challenge(0, R.Outcome.No, keccak256("counter"), "https://example.org/counter.json");
        assert(resolver.disputeRequestId(0) != 0);
        assert(resolver.lockedBonds() == 2e6);
        assert(!callAs(RELAY, abi.encodeCall(R.reportRuling,
            (0, CASE_ID, R.Outcome.No, EVIDENCE, "https://example.org/ruling.json"))));
        vm.warp(6600);
        assert(!callAs(CHALLENGER, abi.encodeCall(R.finalize, (0))));
        assert(!callAs(CHALLENGER, abi.encodeCall(R.linkSourceCase, (0, CASE_ID))));
        vm.prank(RELAY); resolver.linkSourceCase(0, CASE_ID);
        vm.prank(RELAY); resolver.reportRuling(0, CASE_ID, R.Outcome.No, EVIDENCE, "https://example.org/ruling.json");
        R.Case memory result = resolver.caseState(0);
        assert(result.phase == R.Phase.Finalized && result.result == R.Outcome.No);
        assert(resolver.credits(CHALLENGER) == 2e6);
        assert(resolver.credits(PROPOSER) == 0);
        assert(resolver.lockedBonds() == 0);
    }

    function testChallengeExpiresOnlyAfterArbitrationDeadline() public {
        vm.warp(3000);
        vm.prank(PROPOSER);
        resolver.propose(0, R.Outcome.Yes, EVIDENCE, "https://example.org/proposal.json");
        vm.prank(CHALLENGER);
        resolver.challenge(0, R.Outcome.No, keccak256("counter"), "https://example.org/counter.json");
        R.Case memory disputed = resolver.caseState(0);
        vm.warp(disputed.arbitrationUntil);
        resolver.finalize(0);
        R.Case memory result = resolver.caseState(0);
        assert(result.phase == R.Phase.Finalized && result.result == R.Outcome.Void);
        assert(resolver.credits(PROPOSER) == 1e6);
        assert(resolver.credits(CHALLENGER) == 1e6);
        assert(!callAs(RELAY, abi.encodeCall(R.linkSourceCase, (0, CASE_ID))));
    }

    function testLinkedKlerosCaseAwaitsRulingPastDeadline() public {
        vm.warp(3000);
        vm.prank(PROPOSER);
        resolver.propose(0, R.Outcome.Yes, EVIDENCE, "https://example.org/proposal.json");
        vm.prank(CHALLENGER);
        resolver.challenge(0, R.Outcome.No, keccak256("counter"), "https://example.org/counter.json");
        R.Case memory disputed = resolver.caseState(0);
        vm.prank(RELAY); resolver.linkSourceCase(0, CASE_ID);
        vm.warp(disputed.arbitrationUntil + 1);
        assert(!callAs(CHALLENGER, abi.encodeCall(R.finalize, (0))));
        vm.prank(RELAY);
        resolver.reportRuling(0, CASE_ID, R.Outcome.No, EVIDENCE, "https://example.org/ruling.json");
        R.Case memory result = resolver.caseState(0);
        assert(result.phase == R.Phase.Finalized && result.result == R.Outcome.No);
    }

    function testWrongRouteAndUnauthorizedReportsCannotSettle() public {
        vm.warp(3000);
        assert(!callAs(PROPOSER, abi.encodeCall(R.propose,
            (1, R.Outcome.Yes, EVIDENCE, "https://example.org/proposal.json"))));
        assert(!callAs(RELAY, abi.encodeCall(R.reportReality,
            (0, R.Outcome.Yes, EVIDENCE, "https://example.org/reality.json"))));
        assert(!callAs(CHALLENGER, abi.encodeCall(R.reportReality,
            (1, R.Outcome.Yes, EVIDENCE, "https://example.org/reality.json"))));
        assert(!callAs(PROPOSER, abi.encodeCall(R.propose,
            (0, R.Outcome.Unset, EVIDENCE, "https://example.org/proposal.json"))));
        assert(!callAs(PROPOSER, abi.encodeCall(R.propose,
            (0, R.Outcome.Yes, EVIDENCE, "http://example.org/proposal.json"))));
    }

    function testThirtyTwoQuestionPoolSettlesWithoutStateEnumeration() public {
        R.Config memory c;
        c.collateral = address(token);
        c.draftHash = keccak256("thirty-two-question-fixture");
        c.closesAt = 2000;
        c.eventHashes = new bytes32[](32);
        c.observationEnds = new uint64[](32);
        c.routes = new R.Route[](32);
        uint8[] memory order = new uint8[](32);
        for (uint8 i; i < 32; ++i) {
            c.eventHashes[i] = bytes32(uint256(i) + 1);
            c.observationEnds[i] = 3000;
            c.routes[i] = R.Route.Reality;
            order[i] = i;
        }
        c.proposer = PROPOSER;
        c.relay = RELAY;
        c.bond = 1e6;
        c.assertionPeriod = 3600;
        c.challengePeriod = 3600;
        c.reportPeriod = 90 days;
        c.arbitrationPeriod = 90 days;
        R many = new R(c);
        LsPilotPool wide = new LsPilotPool(address(token), 32, 10e6, 500, 2000,
            order, address(many), many.rulesHash());
        many.bindPool(address(wide));
        token.mint(address(this), wide.requiredFunding());
        token.approve(address(wide), wide.requiredFunding());
        wide.fund();
        vm.warp(3000);
        for (uint8 i; i < 32; ++i) {
            vm.prank(RELAY);
            many.reportReality(i, i == 31 ? R.Outcome.Yes : R.Outcome.No,
                EVIDENCE, "https://example.org/source.json");
        }
        many.deliver();
        assert(wide.resolved());
        assert(wide.resolvedState() == uint32(1) << 31);
    }

    function testBindPoolRejectsFixedDepthPool() public {
        R.Config memory c;
        c.collateral = address(token);
        c.draftHash = keccak256("fixed depth rejected");
        c.closesAt = 2000;
        c.eventHashes = new bytes32[](2);
        c.eventHashes[0] = bytes32(uint256(1));
        c.eventHashes[1] = bytes32(uint256(2));
        c.observationEnds = new uint64[](2);
        c.observationEnds[0] = 3000;
        c.observationEnds[1] = 3000;
        c.routes = new R.Route[](2);
        c.proposer = PROPOSER;
        c.relay = RELAY;
        c.bond = 1e6;
        c.assertionPeriod = 3600;
        c.challengePeriod = 3600;
        c.reportPeriod = 90 days;
        c.arbitrationPeriod = 90 days;
        R fresh = new R(c);
        uint8[] memory order = new uint8[](2);
        order[1] = 1;
        WidePilotPool fixedDepth = new WidePilotPool(address(token), 2, 10e6, 2000, order, address(fresh), fresh.rulesHash());
        try fresh.bindPool(address(fixedDepth)) {
            assert(false);
        } catch (bytes memory reason) {
            assert(reason.length == 4 && bytes4(reason) == R.InvalidConfig.selector);
        }
        assert(address(fresh.pool()) == address(0));
    }

    function testBindPoolAcceptsLsPool() public view {
        assert(address(resolver.pool()) == address(pool));
        assert(pool.protocolVersion() == 5);
    }

    function testSurplusReturnsAtCloseAndAfterDeliveryWithoutBlockingSettlement() public {
        address trader = address(0x7EAD);
        token.mint(trader, 100e6);
        vm.prank(trader); token.approve(address(pool), type(uint256).max);
        vm.prank(trader); uint128 paid = pool.buy(1, 2, 4e6, type(uint128).max, block.timestamp);
        vm.prank(trader); paid += pool.buy(2, 1, 1e6, type(uint128).max, block.timestamp);
        uint256 sponsorBefore = token.balanceOf(address(this));
        vm.warp(2000);
        assert(pool.sponsor() == address(this));
        vm.prank(RELAY); uint128 atClose = pool.withdrawSurplus();
        assert(token.balanceOf(address(pool)) == pool.requiredCollateral());
        vm.warp(3000);
        vm.prank(PROPOSER);
        resolver.propose(0, R.Outcome.Yes, EVIDENCE, "https://example.org/mechanical.json");
        vm.prank(RELAY);
        resolver.reportReality(1, R.Outcome.Yes, EVIDENCE, "https://example.org/reality.json");
        vm.warp(6600);
        resolver.finalize(0);
        resolver.deliver();
        assert(pool.resolved());
        uint128 atSettlement = pool.withdrawSurplus();
        assert(pool.requiredCollateral() == 4e6);
        vm.prank(trader); assert(pool.redeem(1, 2, 4e6) == 4e6);
        vm.prank(trader); assert(pool.redeem(2, 1, 1e6) == 0);
        assert(token.balanceOf(address(pool)) == 0);
        assert(token.balanceOf(address(this)) - sponsorBefore == uint256(atClose) + atSettlement);
        assert(uint256(atClose) + atSettlement == pool.requiredFunding() + paid - 4e6);
        assert(atClose == 11697257 && atSettlement == 1000000);
    }

    function testConditionalPoolSettlesThroughHybridResolver() public {
        R.Config memory c;
        c.collateral = address(token);
        c.draftHash = keccak256("conditional reality fixture");
        c.closesAt = 2000;
        c.eventHashes = new bytes32[](2);
        c.eventHashes[0] = bytes32(uint256(1));
        c.eventHashes[1] = bytes32(uint256(2));
        c.observationEnds = new uint64[](2);
        c.observationEnds[0] = 3000;
        c.observationEnds[1] = 3000;
        c.routes = new R.Route[](2);
        c.routes[0] = R.Route.Reality;
        c.routes[1] = R.Route.Reality;
        c.proposer = PROPOSER;
        c.relay = RELAY;
        c.bond = 1e6;
        c.assertionPeriod = 3600;
        c.challengePeriod = 3600;
        c.reportPeriod = 90 days;
        c.arbitrationPeriod = 90 days;
        R r = new R(c);
        uint8[] memory order = new uint8[](2);
        order[1] = 1;
        CondPilotPool p = new CondPilotPool(address(token), 2, 10e6, 500, 2000, order, address(r), r.rulesHash(), new LsPricer());
        r.bindPool(address(p));
        assert(address(r.pool()) == address(p));
        token.mint(address(this), p.requiredFunding());
        token.approve(address(p), p.requiredFunding());
        p.fund();
        address normal = address(0x7EAD);
        address conditional = address(0xC0DE);
        token.mint(normal, 100e6);
        token.mint(conditional, 100e6);
        vm.prank(normal); token.approve(address(p), type(uint256).max);
        vm.prank(conditional); token.approve(address(p), type(uint256).max);
        vm.prank(normal); p.buy(1, 2, 2e6, type(uint128).max, block.timestamp);
        S.Shape memory shape = S.Shape(1, 2, 2, 2);
        vm.prank(conditional); p.buyConditional(shape, 1e6, 8e5, block.timestamp);
        uint256 sponsorBefore = token.balanceOf(address(this));
        vm.warp(3000);
        vm.prank(RELAY); r.reportReality(0, R.Outcome.Yes, EVIDENCE, "https://example.org/zero.json");
        vm.prank(RELAY); r.reportReality(1, R.Outcome.Yes, EVIDENCE, "https://example.org/one.json");
        r.deliver();
        assert(p.resolved() && p.resolvedState() == 3 && p.voidMask() == 0);
        assert(p.requiredCollateral() == 3e6);
        vm.prank(normal); assert(p.redeem(1, 2, 2e6) == 2e6);
        vm.prank(conditional); assert(p.redeemConditional(shape) == 1e6);
        assert(p.requiredCollateral() == 0);
        uint128 returned = p.withdrawSurplus();
        assert(returned > 0 && token.balanceOf(address(p)) == 0);
        assert(token.balanceOf(address(this)) - sponsorBefore == returned);
    }
}
