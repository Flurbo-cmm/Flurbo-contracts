// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;
import {LsPilotPool} from "../src/LsPilotPool.sol";
import {MockCollateral} from "./helpers/MockCollateral.sol";

interface LsGasVm {
    function chainId(uint256) external;
}

contract LsPilotPoolGasTest {
    LsGasVm constant vm = LsGasVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    event log_named_uint(string name, uint256 value);
    MockCollateral private token;
    LsPilotPool private pool;

    function setUp() public {
        vm.chainId(10143);
        token = new MockCollateral(6);
        uint8[] memory order = new uint8[](8);
        for (uint8 i; i < 8; i++) {
            order[i] = i;
        }
        pool = new LsPilotPool(
            address(token),
            8,
            100e6,
            500,
            uint64(block.timestamp + 100),
            order,
            address(this),
            keccak256("synthetic gas fixture")
        );
        token.mint(address(this), 10000e6);
        token.approve(address(pool), type(uint256).max);
        pool.fund();
        for (uint32 scope = 3; scope <= 192; scope <<= 2) {
            pool.buy(scope, 8, 10e6, 10e6, block.timestamp);
        }
    }

    function testExistingFirstFactorBuyGas() public {
        uint256 start = gasleft();
        uint128 paid = pool.buy(3, 8, 1e6, 1e6, block.timestamp);
        uint256 used = start - gasleft();
        assert(pool.holdings(address(this), 3, 8) == 11e6 && pool.requiredCollateral() == 41e6);
        assert(used <= 1_100_000);
        emit log_named_uint("buy execution gas", used);
        emit log_named_uint("buy collateral atoms", paid);
    }

    function testExistingMiddleFactorSellGas() public {
        uint256 start = gasleft();
        uint128 paid = pool.sell(48, 8, 1e6, 1, block.timestamp);
        uint256 used = start - gasleft();
        assert(pool.holdings(address(this), 48, 8) == 9e6 && pool.requiredCollateral() == 39e6);
        assert(used <= 1_100_000);
        emit log_named_uint("sell execution gas", used);
        emit log_named_uint("sell collateral atoms", paid);
    }
}
