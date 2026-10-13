// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {LsPilotPool} from "../src/LsPilotPool.sol";
import {MockCollateral} from "./helpers/MockCollateral.sol";

interface LsSurplusVm {
    function chainId(uint256) external;
    function warp(uint256) external;
    function prank(address) external;
}

contract LsPilotPoolSurplusTest {
    LsSurplusVm constant vm = LsSurplusVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant SPONSOR = address(0x5905);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    bytes32 constant RULES = keccak256("ls surplus fixture");

    MockCollateral token;

    function setUp() public {
        vm.chainId(10143);
        vm.warp(1000);
        token = new MockCollateral(6);
    }

    function order() private pure returns (uint8[] memory result) {
        result = new uint8[](2);
        result[1] = 1;
    }

    function deploy(bool funded) private returns (LsPilotPool pool) {
        vm.prank(SPONSOR);
        pool = new LsPilotPool(address(token), 2, 10e6, 500, 2000, order(), address(this), RULES);
        if (funded) {
            uint128 funding = pool.requiredFunding();
            token.mint(SPONSOR, funding);
            vm.prank(SPONSOR);
            token.approve(address(pool), funding);
            vm.prank(SPONSOR);
            pool.fund();
        }
        token.mint(ALICE, 1000e6);
        token.mint(BOB, 1000e6);
        vm.prank(ALICE);
        token.approve(address(pool), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(pool), type(uint256).max);
    }

    function buyAs(address trader, LsPilotPool pool, uint32 scope, uint256 mask, uint128 quantity)
        private
        returns (uint128)
    {
        vm.prank(trader);
        return pool.buy(scope, mask, quantity, type(uint128).max, block.timestamp);
    }

    function redeemAs(address holder, LsPilotPool pool, uint32 scope, uint256 mask, uint128 quantity)
        private
        returns (uint128)
    {
        vm.prank(holder);
        return pool.redeem(scope, mask, quantity);
    }

    function withdrawAs(address caller, LsPilotPool pool) private returns (uint128) {
        vm.prank(caller);
        return pool.withdrawSurplus();
    }

    function expectRevert(LsPilotPool pool, bytes4 selector) private {
        try pool.withdrawSurplus() returns (uint128) {
            assert(false);
        } catch (bytes memory reason) {
            assert(reason.length == 4 && bytes4(reason) == selector);
        }
    }

    function testSponsorIsTheDeployer() public {
        LsPilotPool pool = deploy(true);
        assert(pool.sponsor() == SPONSOR);
        LsPilotPool own = new LsPilotPool(address(token), 2, 10e6, 500, 2000, order(), address(this), RULES);
        assert(own.sponsor() == address(this));
    }

    function testNoWithdrawalWhileTradingIsOpen() public {
        LsPilotPool pool = deploy(true);
        buyAs(ALICE, pool, 1, 2, 5e6);
        vm.warp(1999);
        assert(pool.surplus() == 0);
        expectRevert(pool, LsPilotPool.StillOpen.selector);
    }

    function testUntradedPoolReturnsTheWholeFundingAtClose() public {
        LsPilotPool pool = deploy(true);
        vm.warp(2000);
        assert(pool.surplus() == 13862944);
        uint256 bobBefore = token.balanceOf(BOB);
        assert(withdrawAs(BOB, pool) == 13862944);
        assert(token.balanceOf(SPONSOR) == 13862944);
        assert(token.balanceOf(BOB) == bobBefore);
        assert(token.balanceOf(address(pool)) == 0);
        expectRevert(pool, LsPilotPool.NoSurplus.selector);
        pool.resolve(1, 0);
        assert(pool.surplus() == 0);
        expectRevert(pool, LsPilotPool.NoSurplus.selector);
    }

    function testCloseAndSettlementWithdrawalsLeaveExactlyTheWinningPayouts() public {
        LsPilotPool pool = deploy(true);
        uint256 paid = buyAs(ALICE, pool, 1, 2, 5e6);
        paid += buyAs(BOB, pool, 1, 1, 3e6);
        paid += buyAs(ALICE, pool, 3, 8, 2e6);
        vm.warp(2000);
        uint256 balance = token.balanceOf(address(pool));
        uint128 atClose = pool.surplus();
        assert(atClose == balance - pool.requiredCollateral());
        assert(withdrawAs(ALICE, pool) == atClose);
        assert(token.balanceOf(address(pool)) == pool.requiredCollateral());
        pool.resolve(1, 0);
        uint128 atSettlement = pool.surplus();
        assert(atSettlement == token.balanceOf(address(pool)) - pool.requiredCollateral());
        assert(withdrawAs(BOB, pool) == atSettlement);
        assert(pool.requiredCollateral() == 5e6);
        assert(redeemAs(ALICE, pool, 1, 2, 5e6) == 5e6);
        assert(redeemAs(BOB, pool, 1, 1, 3e6) == 0);
        assert(redeemAs(ALICE, pool, 3, 8, 2e6) == 0);
        assert(token.balanceOf(address(pool)) == 0 && pool.requiredCollateral() == 0);
        assert(token.balanceOf(SPONSOR) == atClose + atSettlement);
        assert(atClose + atSettlement == pool.requiredFunding() + paid - 5e6);
        assert(paid == 4863494 && atClose == 11726438 && atSettlement == 2000000);
    }

    function testVoidSettlementKeepsFractionalPayouts() public {
        LsPilotPool pool = deploy(true);
        uint256 paid = buyAs(ALICE, pool, 1, 2, 5e6);
        paid += buyAs(BOB, pool, 1, 1, 3e6);
        vm.warp(2000);
        uint128 atClose = withdrawAs(ALICE, pool);
        pool.resolve(0, 1);
        assert(pool.requiredCollateral() == 4e6);
        uint128 atSettlement = withdrawAs(ALICE, pool);
        assert(redeemAs(ALICE, pool, 1, 2, 5e6) == 2.5e6);
        assert(redeemAs(BOB, pool, 1, 1, 3e6) == 1.5e6);
        assert(token.balanceOf(address(pool)) == 0 && pool.requiredCollateral() == 0);
        assert(atClose + atSettlement == pool.requiredFunding() + paid - 4e6);
        assert(paid == 4249210 && atClose == 13112154 && atSettlement == 1000000);
    }

    function testDonationAfterWithdrawalReturnsToTheSponsor() public {
        LsPilotPool pool = deploy(true);
        buyAs(ALICE, pool, 1, 2, 5e6);
        vm.warp(2000);
        uint128 first = withdrawAs(BOB, pool);
        token.mint(address(pool), 7);
        assert(pool.surplus() == 7);
        assert(withdrawAs(BOB, pool) == 7);
        assert(token.balanceOf(SPONSOR) == uint256(first) + 7);
    }

    function testUnfundedPoolHasNoSurplus() public {
        LsPilotPool pool = deploy(false);
        vm.warp(2000);
        assert(pool.surplus() == 0);
        expectRevert(pool, LsPilotPool.NoSurplus.selector);
    }

    function testFuzzWinnersAlwaysRedeemAfterWithdrawals(uint256 seed) public {
        LsPilotPool pool = deploy(true);
        token.mint(address(this), 1000e6);
        token.approve(address(pool), type(uint256).max);
        uint256 paidIn;
        uint256 paidOut;
        for (uint256 step; step < 12; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint32 scope = uint32(1 + r % 3);
            uint256 mask = scope == 3 ? 1 + (r >> 8) % 14 : 1 + (r >> 8) % 2;
            uint256 limit = pool.depth() / 1e12;
            uint128 quantity = uint128(1 + (r >> 16) % limit);
            uint128 held = pool.holdings(address(this), scope, mask);
            if ((r >> 128) % 3 == 0 && held != 0) {
                if (quantity > held) quantity = held;
                try pool.sell(scope, mask, quantity, 0, block.timestamp) returns (uint128 got) { paidOut += got; } catch {}
            } else {
                try pool.buy(scope, mask, quantity, type(uint128).max, block.timestamp) returns (uint128 cost) { paidIn += cost; } catch {}
            }
        }
        vm.warp(2000);
        uint256 returned;
        if (pool.surplus() != 0) returned += pool.withdrawSurplus();
        assert(token.balanceOf(address(pool)) == pool.requiredCollateral());
        uint32 yesMask = uint32(seed % 4);
        uint32 voidMask = uint32((seed >> 2) % 4) & ~yesMask;
        pool.resolve(yesMask, voidMask);
        if (pool.surplus() != 0) returned += pool.withdrawSurplus();
        uint256 redeemed;
        uint256 count;
        for (uint32 scope = 1; scope <= 3; ++scope) {
            uint256 last = scope == 3 ? 14 : 2;
            for (uint256 mask = 1; mask <= last; ++mask) {
                uint128 held = pool.holdings(address(this), scope, mask);
                if (held == 0) continue;
                (uint256 numerator, uint256 denominator) = pool.payoutFraction(scope, mask);
                uint128 got = pool.redeem(scope, mask, held);
                assert(got == uint256(held) * numerator / denominator);
                redeemed += got;
                count++;
            }
        }
        uint256 left = token.balanceOf(address(pool));
        assert(left == pool.requiredCollateral() && left <= 1 + count);
        assert(token.balanceOf(SPONSOR) == returned);
        assert(returned + redeemed + left == pool.requiredFunding() + paidIn - paidOut);
    }
}
