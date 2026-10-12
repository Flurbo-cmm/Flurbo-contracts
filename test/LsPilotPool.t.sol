// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {LsPilotPool} from "../src/LsPilotPool.sol";
import {WidePilotPool} from "../src/WidePilotPool.sol";
import {FactoredFunding} from "../src/FactoredFunding.sol";
import {FactoredQuote as Q} from "../src/FactoredQuote.sol";
import {MockCollateral} from "./helpers/MockCollateral.sol";

interface LsPoolVm {
    function chainId(uint256) external;
    function warp(uint256) external;
    function prank(address) external;
}

contract LsPilotPoolTest {
    LsPoolVm constant vm = LsPoolVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    bytes32 constant RULES = keccak256("ls fixture");

    MockCollateral token;

    function setUp() public {
        vm.chainId(10143);
        vm.warp(1000);
        token = new MockCollateral(6);
    }

    function order(uint8 events) private pure returns (uint8[] memory result) {
        result = new uint8[](events);
        for (uint8 i; i < events; ++i) result[i] = i;
    }

    function deploy(uint8 events, uint128 initialDepth, uint16 bps) private returns (LsPilotPool pool) {
        pool = new LsPilotPool(address(token), events, initialDepth, bps, 2000, order(events), address(this), RULES);
        uint128 funding = pool.requiredFunding();
        token.mint(address(this), funding);
        token.approve(address(pool), funding);
        pool.fund();
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

    function sellAs(address trader, LsPilotPool pool, uint32 scope, uint256 mask, uint128 quantity)
        private
        returns (uint128)
    {
        vm.prank(trader);
        return pool.sell(scope, mask, quantity, 0, block.timestamp);
    }

    function testFundingEqualsFixedDepthPool() public {
        uint8[3] memory sizes = [uint8(2), 4, 32];
        for (uint256 i; i < sizes.length; ++i) {
            LsPilotPool ls = new LsPilotPool(address(token), sizes[i], 10e6, 500, 2000, order(sizes[i]), address(this), RULES);
            WidePilotPool wide = new WidePilotPool(address(token), sizes[i], 10e6, 2000, order(sizes[i]), address(this), RULES);
            assert(ls.requiredFunding() == wide.requiredFunding());
            if (sizes[i] == 2) assert(ls.requiredFunding() == 13862944);
        }
    }

    function testConstructorRejectsCommissionOutsideRange() public {
        uint16[2] memory invalid = [uint16(99), 2001];
        for (uint256 i; i < invalid.length; ++i) {
            try new LsPilotPool(address(token), 2, 10e6, invalid[i], 2000, order(2), address(this), RULES) returns (LsPilotPool) {
                assert(false);
            } catch (bytes memory reason) {
                assert(reason.length == 4 && bytes4(reason) == FactoredFunding.InvalidConfiguration.selector);
            }
        }
    }

    function testVersionAndViews() public {
        LsPilotPool pool = deploy(2, 10e6, 500);
        assert(pool.protocolVersion() == 5);
        assert(pool.commissionBps() == 500);
        assert(pool.depthRate() == 36067376022224085);
        assert(pool.liquidity() == 10e6);
        assert(pool.depth() == 10e18);
    }

    function testDepthTracksStoredFactors() public {
        LsPilotPool pool = deploy(2, 10e6, 500);
        buyAs(ALICE, pool, 1, 2, 1e6);
        assert(pool.depth() == 10018033688011112042);
        sellAs(ALICE, pool, 1, 2, 1e6);
        assert(pool.depth() == 10e18);
        Q.Factor[] memory stored = pool.factors();
        for (uint256 i; i < stored.length; ++i) {
            for (uint256 j; j < stored[i].values.length; ++j) assert(stored[i].values[j] == 0);
        }
    }

    function testPathIndependence() public {
        LsPilotPool a = deploy(2, 10e6, 500);
        LsPilotPool b = deploy(2, 10e6, 500);
        uint256 paidA = buyAs(ALICE, a, 1, 2, 3e6);
        paidA += buyAs(ALICE, a, 3, 8, 2e6);
        paidA -= sellAs(ALICE, a, 1, 2, 1e6);
        uint256 paidB = buyAs(ALICE, b, 3, 8, 2e6);
        paidB += buyAs(ALICE, b, 1, 2, 2e6);
        assert(a.depth() == b.depth());
        assert(a.requiredCollateral() == b.requiredCollateral());
        assert(paidA > paidB ? paidA - paidB <= 3 : paidB - paidA <= 3);
    }

    function testRoundTripNeverProfits() public {
        LsPilotPool pool = deploy(2, 10e6, 500);
        uint128 paid = buyAs(ALICE, pool, 1, 2, 5e6);
        uint128 received = sellAs(ALICE, pool, 1, 2, 5e6);
        assert(received <= paid && paid - received <= 2);
    }

    function testSplittingNeverCheaper() public {
        LsPilotPool a = deploy(2, 10e6, 500);
        LsPilotPool b = deploy(2, 10e6, 500);
        uint256 costA = buyAs(ALICE, a, 1, 2, 10e6);
        uint256 sumB;
        for (uint256 i; i < 10; ++i) sumB += buyAs(ALICE, b, 1, 2, 1e6);
        assert(sumB >= costA && sumB - costA <= 10);
        assert(a.depth() == b.depth());
    }

    function testBalancedVolumeKeepsTheCommission() public {
        LsPilotPool pool = deploy(2, 10e6, 500);
        uint256 total = buyAs(ALICE, pool, 1, 2, 10e6);
        total += buyAs(BOB, pool, 1, 1, 10e6);
        assert(total >= 10_499_999 && total <= 10_500_002);
        vm.warp(2000);
        pool.resolve(1, 0);
        vm.prank(ALICE);
        assert(pool.redeem(1, 2, 10e6) == 10e6);
        vm.prank(BOB);
        assert(pool.redeem(1, 1, 10e6) == 0);
        uint256 kept = token.balanceOf(address(pool)) - pool.requiredFunding();
        assert(kept >= 499_999 && kept <= 500_002);
        assert(pool.requiredCollateral() == 0);
    }

    function testInformedBuyerTakesAtMostTheFunding() public {
        LsPilotPool pool = deploy(2, 10e6, 500);
        uint256 paid;
        uint128 held;
        uint256 accepted;
        for (uint256 i; i < 8; ++i) {
            uint128 quantity = uint128(pool.depth() / 1e12);
            vm.prank(ALICE);
            try pool.buy(1, 2, quantity, type(uint128).max, block.timestamp) returns (uint128 cost) {
                assert(cost < quantity);
                paid += cost;
                held += quantity;
                accepted++;
            } catch (bytes memory reason) {
                // The other question's entropy keeps a near-certain Yes above one per share, so the buy is refused.
                assert(reason.length == 4 && bytes4(reason) == Q.UnquotableTrade.selector);
                break;
            }
        }
        assert(accepted == 5);
        vm.warp(2000);
        pool.resolve(1, 0);
        vm.prank(ALICE);
        uint256 redeemed = pool.redeem(1, 2, held);
        uint256 funding = pool.requiredFunding();
        uint256 balance = token.balanceOf(address(pool));
        assert(redeemed == held);
        assert(balance == funding + paid - redeemed);
        assert(balance < funding && funding - balance <= funding);
    }

    function testFuzzTradesStaySolvent(uint256 seed) public {
        LsPilotPool pool = deploy(2, 10e6, 500);
        token.mint(address(this), 1000e6);
        token.approve(address(pool), type(uint256).max);
        for (uint256 step; step < 12; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint32 scope = uint32(1 + r % 3);
            uint256 mask = scope == 3 ? 1 + (r >> 8) % 14 : 1 + (r >> 8) % 2;
            uint256 limit = pool.depth() / 1e12;
            uint128 quantity = uint128(1 + (r >> 16) % limit);
            uint128 held = pool.holdings(address(this), scope, mask);
            if ((r >> 128) % 3 == 0 && held != 0) {
                if (quantity > held) quantity = held;
                try pool.sell(scope, mask, quantity, 0, block.timestamp) {} catch {}
            } else {
                try pool.buy(scope, mask, quantity, type(uint128).max, block.timestamp) {} catch {}
            }
            assert(token.balanceOf(address(pool)) >= pool.requiredCollateral());
        }
        vm.warp(2000);
        uint32 yesMask = uint32(seed % 4);
        uint32 voidMask = uint32((seed >> 2) % 4) & ~yesMask;
        pool.resolve(yesMask, voidMask);
        for (uint32 scope = 1; scope <= 3; ++scope) {
            uint256 last = scope == 3 ? 14 : 2;
            for (uint256 mask = 1; mask <= last; ++mask) {
                uint128 held = pool.holdings(address(this), scope, mask);
                if (held != 0) pool.redeem(scope, mask, held);
            }
        }
        assert(token.balanceOf(address(pool)) >= pool.requiredCollateral());
    }
}
