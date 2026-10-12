// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {WidePilotPool} from "./WidePilotPool.sol";
import {FactoredQuote as Q} from "./FactoredQuote.sol";
import {LsQuote as L} from "./LsQuote.sol";

/// @notice Wide pool priced by a liquidity-sensitive LMSR. Settlement, positions and funding are inherited unchanged.
/// @dev liquidity() is the initial depth. requiredFunding equals a fixed-depth pool's for the same initial depth.
contract LsPilotPool is WidePilotPool {
    uint16 public immutable commissionBps;
    uint256 public immutable depthRate;

    constructor(
        address token,
        uint8 events_,
        uint128 initialDepth,
        uint16 commissionBps_,
        uint64 closeTime,
        uint8[] memory order_,
        address resolver_,
        bytes32 rulesHash
    ) WidePilotPool(token, events_, initialDepth, closeTime, order_, resolver_, rulesHash) {
        if (commissionBps_ < L.MIN_COMMISSION_BPS || commissionBps_ > L.MAX_COMMISSION_BPS) {
            revert InvalidConfiguration();
        }
        commissionBps = commissionBps_;
        depthRate = L.depthRate(events_, commissionBps_);
    }

    function protocolVersion() external pure override returns (uint8) { return 5; }

    /// @notice Current depth in collateral WAD. Meaningful only while trading is open.
    function depth() external view returns (uint256) {
        return L.currentDepth(lsMarket());
    }

    function priceTrade(uint32 scope, uint256 mask, uint128 quantity, uint128 limit, bool isBuy)
        internal
        view
        override
        returns (Q.Quote memory quote, uint128 reserve)
    {
        L.Market memory m = lsMarket();
        quote = isBuy ? L.buy(m, scope, mask, quantity, limit) : L.sell(m, scope, mask, quantity, limit);
        reserve = 0;
    }

    function lsMarket() private view returns (L.Market memory) {
        return L.Market(eventCount, liquidity, depthRate, collateralDecimals, storedFactors, order);
    }
}
