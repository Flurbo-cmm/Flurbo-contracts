// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @notice Shape of a conditional claim: "if condition, then target" over at most three questions.
/// @dev Local bit j of a scope is its jth set bit, ascending, as for claims.
library ConditionalShape {
    error InvalidShape();

    struct Shape {
        uint32 conditionScope;
        uint256 conditionMask;
        uint32 targetScope;
        uint256 targetMask;
    }

    function validate(Shape memory s, uint8 events) internal pure returns (uint32 scope) {
        uint256 c = popcount(s.conditionScope);
        uint256 t = popcount(s.targetScope);
        scope = s.conditionScope | s.targetScope;
        if (c == 0 || t == 0 || c > 2 || t > 2 || s.conditionScope & s.targetScope != 0 || c + t > 3
            || uint256(scope) >> events != 0 || !validMask(s.conditionMask, c) || !validMask(s.targetMask, t)) {
            revert InvalidShape();
        }
    }

    function key(Shape memory s) internal pure returns (bytes32) {
        return keccak256(abi.encode(s.conditionScope, s.conditionMask, s.targetScope, s.targetMask));
    }

    /// @dev Pays shares where condition and target hold, nothing where only the condition holds, refund elsewhere.
    function vector(Shape memory s, uint128 shares, uint128 refund)
        internal
        pure
        returns (uint32 scope, uint128[] memory values)
    {
        if (shares == 0 && refund == 0) revert InvalidShape();
        scope = s.conditionScope | s.targetScope;
        values = new uint128[](uint256(1) << popcount(scope));
        for (uint256 state; state < values.length; ++state) {
            values[state] = valueAt(s, scope, state, shares, refund);
        }
    }

    /// @dev Void questions count both answers equally, as in WidePilotPool.payoutFraction. Rounds down.
    function payout(Shape memory s, uint128 shares, uint128 refund, uint32 yesMask, uint32 voidMask)
        internal
        pure
        returns (uint128)
    {
        uint32 scope = s.conditionScope | s.targetScope;
        uint256 states = uint256(1) << popcount(scope);
        uint256 localYes = projectLocal(type(uint32).max, scope, yesMask);
        uint256 known = (states - 1) ^ projectLocal(type(uint32).max, scope, voidMask);
        uint256 total;
        uint256 count;
        for (uint256 state; state < states; ++state) {
            if ((state & known) != (localYes & known)) continue;
            total += valueAt(s, scope, state, shares, refund);
            count++;
        }
        return uint128(total / count);
    }

    function valueAt(Shape memory s, uint32 scope, uint256 state, uint128 shares, uint128 refund)
        private
        pure
        returns (uint128)
    {
        if ((s.conditionMask >> projectLocal(scope, s.conditionScope, state)) & 1 == 0) return refund;
        return (s.targetMask >> projectLocal(scope, s.targetScope, state)) & 1 == 0 ? 0 : shares;
    }

    function validMask(uint256 mask, uint256 size) private pure returns (bool) {
        return mask != 0 && mask < (uint256(1) << (uint256(1) << size)) - 1;
    }

    function popcount(uint256 value) private pure returns (uint256 count) {
        while (value != 0) {
            value &= value - 1;
            count++;
        }
    }

    /// @dev Projects a state local to `from` onto `to`, a subset of `from`.
    function projectLocal(uint32 from, uint32 to, uint256 state) private pure returns (uint256 local) {
        uint256 index;
        uint256 out;
        while (from != 0) {
            uint32 bit = from & (~from + 1);
            if (to & bit != 0) {
                if ((state >> index) & 1 != 0) local |= uint256(1) << out;
                out++;
            }
            index++;
            from &= from - 1;
        }
    }
}
