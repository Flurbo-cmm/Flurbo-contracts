// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ConditionalShape as S} from "../src/ConditionalShape.sol";
import {ConditionalFixtureValues as FX} from "./ConditionalFixtures.t.sol";

contract ConditionalShapeHarness {
    function validate(S.Shape memory s, uint8 events) external pure returns (uint32) {
        return S.validate(s, events);
    }

    function key(S.Shape memory s) external pure returns (bytes32) {
        return S.key(s);
    }

    function vector(S.Shape memory s, uint128 shares, uint128 refund)
        external
        pure
        returns (uint32 scope, uint128[] memory values)
    {
        return S.vector(s, shares, refund);
    }

    function payout(S.Shape memory s, uint128 shares, uint128 refund, uint32 yesMask, uint32 voidMask)
        external
        pure
        returns (uint128)
    {
        return S.payout(s, shares, refund, yesMask, voidMask);
    }
}

contract ConditionalShapeTest {
    ConditionalShapeHarness private h;

    function setUp() public {
        h = new ConditionalShapeHarness();
    }

    function shape(uint32 cs, uint256 cm, uint32 ts, uint256 tm) private pure returns (S.Shape memory) {
        return S.Shape(cs, cm, ts, tm);
    }

    function rejects(S.Shape memory s, uint8 events) private view {
        try h.validate(s, events) returns (uint32) {
            assert(false);
        } catch (bytes memory reason) {
            assert(reason.length == 4 && bytes4(reason) == S.InvalidShape.selector);
        }
    }

    function testValidateAcceptsOneAndTwoQuestionLegs() public view {
        assert(h.validate(shape(1, 2, 2, 2), 3) == 3);
        assert(h.validate(shape(1, 2, 6, 8), 3) == 7);
        assert(h.validate(shape(3, 8, 4, 2), 3) == 7);
        assert(h.validate(shape(4, 1, 1, 2), 3) == 5);
    }

    function testValidateRejects() public view {
        rejects(shape(1, 2, 1, 2), 4);
        rejects(shape(3, 8, 2, 2), 4);
        rejects(shape(0, 1, 2, 2), 4);
        rejects(shape(1, 2, 0, 1), 4);
        rejects(shape(7, 128, 8, 2), 4);
        rejects(shape(3, 8, 12, 8), 4);
        rejects(shape(1, 2, 8, 2), 3);
        rejects(shape(1, 0, 2, 2), 4);
        rejects(shape(1, 2, 2, 0), 4);
        rejects(shape(1, 3, 2, 2), 4);
        rejects(shape(3, 15, 4, 2), 4);
        rejects(shape(1, 4, 2, 2), 4);
    }

    function testVectorLayout() public view {
        (uint32 scope, uint128[] memory values) = h.vector(shape(1, 2, 2, 2), 5, 3);
        assert(scope == 3 && values.length == 4);
        assert(values[0] == 3 && values[1] == 0 && values[2] == 3 && values[3] == 5);
        (scope, values) = h.vector(shape(1, 1, 2, 2), 5, 3);
        assert(scope == 3);
        assert(values[0] == 0 && values[1] == 3 && values[2] == 5 && values[3] == 3);
        (scope, values) = h.vector(shape(1, 2, 6, 8), 7, 2);
        assert(scope == 7 && values.length == 8);
        for (uint256 t; t < 8; ++t) {
            uint256 expected = t & 1 == 0 ? 2 : t == 7 ? 7 : 0;
            assert(values[t] == expected);
        }
    }

    function testVectorRefusesEmptyAmounts() public view {
        try h.vector(shape(1, 2, 2, 2), 0, 0) returns (uint32, uint128[] memory) {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == S.InvalidShape.selector);
        }
    }

    function testKeyIsAbiEncodedHash() public view {
        assert(h.key(shape(1, 2, 2, 2)) == keccak256(abi.encode(uint32(1), uint256(2), uint32(2), uint256(2))));
        assert(h.key(shape(1, 2, 2, 2)) != h.key(shape(2, 2, 1, 2)));
    }

    function testPayoutCases() public view {
        S.Shape memory s = shape(1, 2, 2, 2);
        uint128 price = FX.STATE_FIVE_B_GIVEN_A_PRICE_ATOMS;
        assert(h.payout(s, 5e6, price, 3, 0) == FX.PAYOUT_A_YES_B_YES);
        assert(h.payout(s, 5e6, price, 1, 0) == FX.PAYOUT_A_YES_B_NO);
        assert(h.payout(s, 5e6, price, 2, 0) == FX.PAYOUT_A_NO);
        assert(h.payout(s, 5e6, price, 2, 1) == FX.PAYOUT_A_VOID_B_YES);
        assert(h.payout(s, 5e6, price, 0, 1) == FX.PAYOUT_A_VOID_B_NO);
        assert(FX.PAYOUT_A_YES_B_YES == 5e6 && FX.PAYOUT_A_YES_B_NO == 0 && FX.PAYOUT_A_NO == price);
        assert(h.payout(s, 5e6, price, 0, 3) == (5e6 + 2 * uint256(price)) / 4);
        assert(h.payout(shape(1, 2, 6, 8), 8, 4, 7, 0) == 8);
        assert(h.payout(shape(1, 2, 6, 8), 8, 4, 3, 0) == 0);
        assert(h.payout(shape(1, 2, 6, 8), 8, 4, 7, 4) == 4);
    }
}
