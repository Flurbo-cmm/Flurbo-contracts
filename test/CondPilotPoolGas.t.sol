// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;
import {CondPilotPool} from "../src/CondPilotPool.sol";
import {LsPricer} from "../src/LsPricer.sol";
import {ConditionalShape as S} from "../src/ConditionalShape.sol";
import {MockCollateral} from "./helpers/MockCollateral.sol";

interface CondGasVm {
    function chainId(uint256) external;
}

contract CondPilotPoolGasTest {
    CondGasVm constant vm = CondGasVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    event log_named_uint(string name, uint256 value);
    MockCollateral private token;
    CondPilotPool private pool;

    function setUp() public {
        vm.chainId(10143);
        token = new MockCollateral(6);
        uint8[] memory order = new uint8[](8);
        for (uint8 i; i < 8; i++) {
            order[i] = i;
        }
        pool = new CondPilotPool(
            address(token),
            8,
            100e6,
            500,
            uint64(block.timestamp + 100),
            order,
            address(this),
            keccak256("synthetic gas fixture"),
            new LsPricer()
        );
        token.mint(address(this), 10000e6);
        token.approve(address(pool), type(uint256).max);
        pool.fund();
        for (uint32 scope = 3; scope <= 192; scope <<= 2) {
            pool.buy(scope, 8, 10e6, 10e6, block.timestamp);
        }
    }

    function testConditionalBuyGas() public {
        S.Shape memory shape = S.Shape(1, 2, 2, 2);
        uint256 start = gasleft();
        pool.buyConditional(shape, 1e6, 8e5, block.timestamp);
        uint256 used = start - gasleft();
        assert(pool.shapeCount() == 1);
        assert(used <= 1_400_000);
        emit log_named_uint("conditional buy execution gas", used);
    }

    function testConditionalSellGas() public {
        S.Shape memory shape = S.Shape(1, 2, 2, 2);
        pool.buyConditional(shape, 1e6, 8e5, block.timestamp);
        uint256 start = gasleft();
        pool.sellConditional(shape, 1e6, 1, block.timestamp);
        uint256 used = start - gasleft();
        assert(used <= 1_400_000);
        emit log_named_uint("conditional sell execution gas", used);
    }

    function testNormalBuyThroughPricerGas() public {
        uint256 start = gasleft();
        uint128 paid = pool.buy(3, 8, 1e6, 1e6, block.timestamp);
        uint256 used = start - gasleft();
        assert(pool.holdings(address(this), 3, 8) == 11e6 && pool.requiredCollateral() == 41e6);
        assert(used <= 1_400_000);
        emit log_named_uint("normal buy execution gas", used);
        emit log_named_uint("normal buy collateral atoms", paid);
    }
}
