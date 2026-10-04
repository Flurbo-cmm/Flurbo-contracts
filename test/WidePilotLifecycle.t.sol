// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {WidePilotPool} from "../src/WidePilotPool.sol";
import {PilotPool} from "../src/PilotPool.sol";
import {WidePilotResolver as R} from "../src/WidePilotResolver.sol";
import {PilotResolver} from "../src/PilotResolver.sol";
import {MockCollateral} from "./helpers/MockCollateral.sol";

interface WideVm {
    function chainId(uint256) external;
    function warp(uint256) external;
    function prank(address) external;
}

contract WidePilotLifecycleTest {
    WideVm constant vm = WideVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant ALICE = address(0xA11CE);
    address constant RELAY = address(0xBEEF);
    MockCollateral token;
    R resolver;
    WidePilotPool pool;

    function setUp() public {
        vm.chainId(10143);
        vm.warp(1000);
        token = new MockCollateral(6);
    }

    function deploy(uint8 count) internal {
        R.Config memory c;
        c.collateral = address(token);
        c.draftHash = keccak256("wide synthetic fixture");
        c.closesAt = 2000;
        c.eventHashes = new bytes32[](count);
        c.observationEnds = new uint64[](count);
        for (uint8 i; i < count; ++i) {
            c.eventHashes[i] = bytes32(uint256(i) + 1);
            c.observationEnds[i] = 3000;
        }
        c.relay = RELAY;
        c.reportPeriod = 3600;
        resolver = new R(c);
        uint8[] memory order = new uint8[](count);
        for (uint8 i; i < count; ++i) order[i] = i;
        pool = new WidePilotPool(address(token), count, 10e6, 2000, order, address(resolver), resolver.rulesHash());
        resolver.bindPool(address(pool));
        token.mint(address(this), pool.requiredFunding());
        token.approve(address(pool), pool.requiredFunding());
        pool.fund();
        token.mint(ALICE, 100e6);
        vm.prank(ALICE); token.approve(address(pool), type(uint256).max);
    }

    function test32EventsHighestBitAndUniformVoid() public {
        deploy(32);
        uint32 high = uint32(1) << 31;
        uint32 joined = high | 1;
        vm.prank(ALICE); pool.buy(1, 2, 8e6, 100e6, 1999);
        vm.prank(ALICE); pool.buy(high, 2, 8e6, 100e6, 1999);
        vm.prank(ALICE); pool.buy(joined, 14, 8e6, 100e6, 1999);
        vm.warp(3000);
        vm.prank(RELAY);
        resolver.reportFinal(0, R.Outcome.Yes, keccak256("capture"), "https://example.org/capture.json");
        vm.warp(6600);
        for (uint8 i = 1; i < 32; ++i) resolver.finalizeMissing(i);
        resolver.deliver();
        assert(pool.resolved());
        assert(pool.resolvedState() == 1);
        assert(pool.voidMask() == type(uint32).max ^ uint32(1));
        assert(pool.requiredCollateral() == 20e6);
        vm.prank(ALICE); assert(pool.redeem(1, 2, 8e6) == 8e6);
        vm.prank(ALICE); assert(pool.redeem(high, 2, 8e6) == 4e6);
        vm.prank(ALICE); assert(pool.redeem(joined, 14, 8e6) == 8e6);
        assert(pool.requiredCollateral() == 0);
    }
    function testOnlyTrustedRelayCanReportAndCannotReplaceFinalResult() public {
        deploy(2);
        vm.warp(3000);
        bytes memory callData = abi.encodeCall(R.reportFinal,
            (0, R.Outcome.Yes, keccak256("capture"), "https://example.org/capture.json"));
        vm.prank(ALICE);
        (bool outsiderAccepted,) = address(resolver).call(callData);
        assert(!outsiderAccepted);
        vm.prank(RELAY);
        resolver.reportFinal(0, R.Outcome.Yes, keccak256("capture"), "https://example.org/capture.json");
        vm.prank(RELAY);
        (bool replacementAccepted,) = address(resolver).call(callData);
        assert(!replacementAccepted);
        R.Case memory result = resolver.caseState(0);
        assert(result.phase == R.Phase.Finalized && result.result == R.Outcome.Yes);
    }

    function testFourEventVoidAccountingMatchesDeployedVersion() public {
        deploy(4);
        PilotResolver.Config memory c;
        c.collateral = address(token);
        c.draftHash = keccak256("wide synthetic fixture");
        c.closesAt = 2000;
        c.eventHashes = new bytes32[](4);
        c.observationEnds = new uint64[](4);
        for (uint8 i; i < 4; ++i) {
            c.eventHashes[i] = bytes32(uint256(i) + 1);
            c.observationEnds[i] = 3000;
        }
        c.reviewers = new address[](3);
        c.reviewers[0] = address(100);
        c.reviewers[1] = address(101);
        c.reviewers[2] = address(102);
        c.bond = 1e6;
        c.assertionPeriod = 3600;
        c.challengePeriod = 3600;
        c.votingPeriod = 3600;
        PilotResolver oldResolver = new PilotResolver(c);
        uint8[] memory order = new uint8[](4);
        for (uint8 i; i < 4; ++i) order[i] = i;
        PilotPool oldPool = new PilotPool(address(token), 4, 10e6, 2000, order, address(oldResolver), oldResolver.rulesHash());
        oldResolver.bindPool(address(oldPool));
        token.mint(address(this), oldPool.requiredFunding());
        token.approve(address(oldPool), oldPool.requiredFunding());
        oldPool.fund();
        vm.prank(ALICE); token.approve(address(oldPool), type(uint256).max);
        vm.prank(ALICE); pool.buy(1, 2, 7e6, 100e6, 1999);
        vm.prank(ALICE); oldPool.buy(1, 2, 7e6, 100e6, 1999);
        vm.prank(ALICE); pool.buy(12, 14, 5e6, 100e6, 1999);
        vm.prank(ALICE); oldPool.buy(12, 14, 5e6, 100e6, 1999);
        vm.warp(3000);
        vm.prank(address(resolver)); pool.resolve(1, 12);
        vm.prank(address(oldResolver)); oldPool.resolve(1, 12);
        assert(pool.requiredCollateral() == oldPool.requiredCollateral());
        (uint256 a, uint256 b) = pool.payoutFraction(12, 14);
        (uint256 cNum, uint256 cDen) = oldPool.payoutFraction(12, 14);
        assert(a * cDen == cNum * b);
        vm.prank(ALICE); uint128 widePaid = pool.redeem(12, 14, 5e6);
        vm.prank(ALICE); uint128 oldPaid = oldPool.redeem(12, 14, 5e6);
        assert(widePaid == oldPaid);
        assert(pool.requiredCollateral() == oldPool.requiredCollateral());
    }

    function testAll32VoidResolvesWithBoundedWork() public {
        deploy(32);
        uint32 high = uint32(1) << 31;
        vm.prank(ALICE); pool.buy(high, 2, 7e6, 100e6, 1999);
        vm.warp(6600);
        for (uint8 i; i < 32; ++i) resolver.finalizeMissing(i);
        resolver.deliver();
        assert(pool.voidMask() == type(uint32).max);
        (uint256 numerator, uint256 denominator) = pool.payoutFraction(high, 2);
        assert(numerator == 1 && denominator == 2);
        vm.prank(ALICE); assert(pool.redeem(high, 2, 7e6) == 3_500_000);
        assert(pool.requiredCollateral() == 0);
    }
}
