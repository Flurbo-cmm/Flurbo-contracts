// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {LsPilotPool} from "./LsPilotPool.sol";
import {LsPricer} from "./LsPricer.sol";
import {ConditionalShape as S} from "./ConditionalShape.sol";
import {FactoredQuote as Q} from "./FactoredQuote.sol";
import {LsQuote as L} from "./LsQuote.sol";

/// @notice LS pool that also sells conditional claims: pays shares if condition and target hold, refunds the price if
/// the condition fails. Every quote comes from one stateless LsPricer, so the factored math is not part of this
/// contract's runtime code. protocolVersion() stays 5, so the unchanged HybridPilotResolver binds it.
contract CondPilotPool is LsPilotPool {
    using S for S.Shape;

    error InvalidPricer();
    error InvalidPrice();
    error PriceBelowCost();
    error NoConditionalHolding();
    error TooManyShapes();

    struct Holding {
        uint128 shares;
        uint128 refund;
    }

    uint16 public constant MAX_SHAPES = 256;
    LsPricer public immutable pricer;
    bytes32[] private shapeKeys;
    mapping(bytes32 => S.Shape) private shapes;
    mapping(address => mapping(bytes32 => Holding)) private conditional;

    event ConditionalTraded(
        address indexed trader, bytes32 indexed key, bool isBuy, uint128 shares, uint128 refund, uint128 collateralAmount
    );
    event ConditionalRedeemed(
        address indexed owner, bytes32 indexed key, uint128 shares, uint128 refund, uint128 collateralAmount
    );

    constructor(
        address token,
        uint8 events_,
        uint128 initialDepth,
        uint16 commissionBps_,
        uint64 closeTime,
        uint8[] memory order_,
        address resolver_,
        bytes32 rulesHash,
        LsPricer pricer_
    ) LsPilotPool(token, events_, initialDepth, commissionBps_, closeTime, order_, resolver_, rulesHash) {
        if (address(pricer_).code.length == 0 || pricer_.version() != 1) revert InvalidPricer();
        pricer = pricer_;
    }

    function conditionalVersion() external pure returns (uint8) { return 1; }

    function shapeCount() external view returns (uint256) {
        return shapeKeys.length;
    }

    function shapeAt(uint256 index) external view returns (bytes32 key, S.Shape memory shape) {
        key = shapeKeys[index];
        shape = shapes[key];
    }

    function conditionalHolding(address owner, bytes32 key) external view returns (uint128 shares, uint128 refund) {
        Holding storage h = conditional[owner][key];
        return (h.shares, h.refund);
    }

    function quoteConditionalBuy(S.Shape calldata shape, uint128 shares, uint128 price)
        external
        view
        returns (uint128 cost)
    {
        requireOpen();
        requireCovered();
        S.Shape memory s = shape;
        s.validate(eventCount);
        (uint32 scope, uint128[] memory values) = s.vector(shares, price);
        (cost,) = pricer.quoteVector(market_(), scope, values, true);
    }

    function quoteConditionalSell(S.Shape calldata shape, address owner, uint128 shares)
        external
        view
        returns (uint128 proceeds, uint128 refundRemoved)
    {
        requireOpen();
        requireCovered();
        S.Shape memory s = shape;
        s.validate(eventCount);
        uint32 scope;
        uint128[] memory values;
        (scope, values, refundRemoved) = sellVector(s, conditional[owner][s.key()], shares);
        (proceeds,) = pricer.quoteVector(market_(), scope, values, false);
    }

    function conditionalPayout(S.Shape calldata shape, address owner) external view returns (uint128) {
        if (!resolved) revert NotResolved();
        S.Shape memory s = shape;
        s.validate(eventCount);
        Holding storage h = conditional[owner][s.key()];
        return h.shares == 0 ? 0 : s.payout(h.shares, h.refund, resolvedState, voidMask);
    }

    function buyConditional(S.Shape calldata shape, uint128 shares, uint128 price, uint256 deadline)
        external
        nonReentrant
        returns (bytes32 key)
    {
        requireOpen();
        if (block.timestamp > deadline) revert ExpiredDeadline();
        requireCovered();
        S.Shape memory s = shape;
        s.validate(eventCount);
        if (shares == 0 || price == 0 || price > shares) revert InvalidPrice();
        (uint32 scope, uint128[] memory values) = s.vector(shares, price);
        (uint128 cost, uint128 maxAfter) = pricer.quoteVector(market_(), scope, values, true);
        if (cost > price) revert PriceBelowCost();
        applyVector(scope, values, true, maxAfter);
        key = register(s);
        Holding storage h = conditional[msg.sender][key];
        h.shares += shares;
        h.refund += price;
        transferExact(msg.sender, price, true);
        requireCovered();
        emit ConditionalTraded(msg.sender, key, true, shares, price, price);
    }

    function sellConditional(S.Shape calldata shape, uint128 shares, uint128 minProceeds, uint256 deadline)
        external
        nonReentrant
        returns (uint128 received)
    {
        requireOpen();
        if (block.timestamp > deadline) revert ExpiredDeadline();
        requireCovered();
        S.Shape memory s = shape;
        s.validate(eventCount);
        bytes32 key = s.key();
        Holding storage h = conditional[msg.sender][key];
        (uint32 scope, uint128[] memory values, uint128 refundRemoved) = sellVector(s, h, shares);
        uint128 maxAfter;
        (received, maxAfter) = pricer.quoteVector(market_(), scope, values, false);
        if (received < minProceeds) revert Q.MinProceedsNotMet();
        applyVector(scope, values, false, maxAfter);
        h.shares -= shares;
        h.refund -= refundRemoved;
        transferExact(msg.sender, received, false);
        requireCovered();
        emit ConditionalTraded(msg.sender, key, false, shares, refundRemoved, received);
    }

    function redeemConditional(S.Shape calldata shape) external nonReentrant returns (uint128 paid) {
        if (!resolved) revert NotResolved();
        S.Shape memory s = shape;
        s.validate(eventCount);
        bytes32 key = s.key();
        Holding memory h = conditional[msg.sender][key];
        if (h.shares == 0) revert NoConditionalHolding();
        paid = s.payout(h.shares, h.refund, resolvedState, voidMask);
        requireCovered();
        (uint32 scope, uint128[] memory values) = s.vector(h.shares, h.refund);
        applyVector(scope, values, false, maximumLiability);
        delete conditional[msg.sender][key];
        remainingPayout -= paid;
        if (paid != 0) transferExact(msg.sender, paid, false);
        requireCovered();
        emit ConditionalRedeemed(msg.sender, key, h.shares, h.refund, paid);
    }

    function priceTrade(uint32 scope, uint256 mask, uint128 quantity, uint128 limit, bool isBuy)
        internal
        view
        override
        returns (Q.Quote memory quote, uint128 reserve)
    {
        quote = pricer.quoteClaim(market_(), scope, mask, quantity, limit, isBuy);
        reserve = 0;
    }

    /// @dev Selling part of a holding removes the refund in proportion, rounded down; the last share removes the rest.
    function sellVector(S.Shape memory s, Holding storage h, uint128 shares)
        private
        view
        returns (uint32 scope, uint128[] memory values, uint128 refundRemoved)
    {
        if (shares == 0 || shares > h.shares) revert NoConditionalHolding();
        refundRemoved = shares == h.shares ? h.refund : uint128(uint256(h.refund) * shares / h.shares);
        (scope, values) = s.vector(shares, refundRemoved);
    }

    function register(S.Shape memory s) private returns (bytes32 key) {
        key = s.key();
        if (shapes[key].conditionScope != 0) return key;
        if (shapeKeys.length >= MAX_SHAPES) revert TooManyShapes();
        shapeKeys.push(key);
        shapes[key] = s;
    }

    /// @dev Merges the vector into the stored table of its scope, never reordering stored tables.
    function applyVector(uint32 scope, uint128[] memory values, bool isBuy, uint128 maxAfter) private {
        uint256 index = storedFactors.length;
        for (uint256 i; i < storedFactors.length; ++i) {
            if (storedFactors[i].scope == scope) {
                index = i;
                break;
            }
        }
        if (index == storedFactors.length) {
            storedFactors.push();
            storedFactors[index].scope = scope;
            storedFactors[index].values = values;
        } else {
            uint128[] storage stored = storedFactors[index].values;
            for (uint256 j; j < values.length; ++j) {
                if (values[j] != 0) stored[j] = isBuy ? stored[j] + values[j] : stored[j] - values[j];
            }
        }
        maximumLiability = maxAfter;
    }

    function market_() private view returns (L.Market memory) {
        return L.Market(eventCount, liquidity, depthRate, collateralDecimals, storedFactors, order);
    }
}
