// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {FactoredTrading} from "./FactoredTrading.sol";
import {FactoredPositions as P} from "./FactoredPositions.sol";
import {FactoredBaseToken} from "./FactoredBaseToken.sol";
import {FactoredBaseTokenFactory} from "./FactoredBaseTokenFactory.sol";

/// @notice Separate Monad testnet pool for up to 32 base events with uniform-void settlement.
/// @dev Pricing remains factored (width <= 2). VOID settlement examines only each local factor (at most 3 events).
contract WidePilotPool is FactoredTrading {
    using P for P.Book;
    error InvalidSettlement();
    error UnauthorizedResolver();
    error NotResolved();
    error InvalidBaseEvent();
    error BaseTokenNotCreated();

    address public immutable resolver;
    bytes32 public immutable settlementRulesHash;
    bool public resolved;
    uint32 public resolvedState;
    uint32 public voidMask;
    uint128 private remainingPayout;
    FactoredBaseTokenFactory public immutable baseTokenFactory;
    mapping(uint32 => mapping(uint8 => FactoredBaseToken)) public baseTokens;

    event Resolved(uint32 indexed yesMask, uint32 indexed voidMask, bytes32 indexed rulesHash);
    event Redeemed(address indexed owner, uint32 indexed scope, uint256 indexed mask, uint128 quantity, uint128 collateralAmount);
    event BaseTokenCreated(uint8 indexed eventIndex, bool outcome, uint32 indexed scope, uint8 mask, address indexed token);
    event BaseWrapped(address indexed owner, uint32 indexed scope, uint8 indexed mask, uint128 quantity);
    event BaseUnwrapped(address indexed owner, uint32 indexed scope, uint8 indexed mask, uint128 quantity);

    constructor(address token, uint8 events_, uint128 b, uint64 closeTime, uint8[] memory order_, address resolver_, bytes32 rulesHash)
        FactoredTrading(token, events_, b, closeTime, order_)
    {
        if (block.chainid != 10143 || events_ < 2 || events_ > 32 || resolver_.code.length == 0 || rulesHash == bytes32(0)) {
            revert InvalidConfiguration();
        }
        resolver = resolver_;
        settlementRulesHash = rulesHash;
        baseTokenFactory = new FactoredBaseTokenFactory();
    }

    function protocolVersion() external pure returns (uint8) { return 3; }

    function requiredCollateral() public view override returns (uint128) {
        return resolved ? remainingPayout : maximumLiability;
    }

    /// @notice Resolve all events; VOID bits receive an independent uniform prior.
    /// @dev Every stored factor covers at most three events, so this never scans 2^eventCount states.
    function resolve(uint32 yesMask, uint32 invalidMask) external nonReentrant {
        if (msg.sender != resolver) revert UnauthorizedResolver();
        if (!funded || resolved || block.timestamp < closesAt || (yesMask & invalidMask) != 0
            || (uint256(yesMask | invalidMask) >> eventCount) != 0) revert InvalidSettlement();
        uint256 scaledTotal;
        for (uint256 i; i < storedFactors.length; ++i) {
            uint32 scope = storedFactors[i].scope;
            uint256 localYes = project(scope, yesMask);
            uint256 localVoid = project(scope, invalidMask);
            uint256 known = (storedFactors[i].values.length - 1) ^ localVoid;
            uint256 possible = uint256(1) << popcount(localVoid);
            uint256 localSum;
            for (uint256 state; state < storedFactors[i].values.length; ++state) {
                if ((state & known) == (localYes & known)) localSum += storedFactors[i].values[state];
            }
            // The common denominator is eight because a factor contains at most three questions.
            scaledTotal += localSum * (8 / possible);
        }
        uint256 payout = (scaledTotal + 7) / 8;
        if (payout > type(uint128).max || payout > maximumLiability) revert InvalidSettlement();
        remainingPayout = uint128(payout);
        resolvedState = yesMask;
        voidMask = invalidMask;
        resolved = true;
        emit Resolved(yesMask, invalidMask, settlementRulesHash);
    }

    function payoutFraction(uint32 scope, uint256 mask) public view returns (uint256 numerator, uint256 denominator) {
        if (!resolved) revert NotResolved();
        P.key(scope, mask);
        if (uint256(scope) >> eventCount != 0) revert P.InvalidClaim();
        uint256 localYes = project(scope, resolvedState);
        uint256 localVoid = project(scope, voidMask);
        uint256 states = uint256(1) << popcount(scope);
        uint256 known = (states - 1) ^ localVoid;
        for (uint256 state; state < states; ++state) {
            if ((state & known) != (localYes & known)) continue;
            denominator++;
            if ((mask & (uint256(1) << state)) != 0) numerator++;
        }
    }
    function redeem(uint32 scope, uint256 mask, uint128 quantity) external nonReentrant returns (uint128 paid) {
        (uint256 numerator, uint256 denominator) = payoutFraction(scope, mask);
        requireCovered();
        positions.debit(msg.sender, scope, mask, quantity);
        for (uint256 i; i < storedFactors.length; ++i) {
            if (storedFactors[i].scope != scope) continue;
            for (uint256 j; j < storedFactors[i].values.length; ++j) {
                if ((mask & (uint256(1) << j)) != 0) storedFactors[i].values[j] -= quantity;
            }
            break;
        }
        // Round individual payouts DOWN. Split redemption cannot increase a payout.
        paid = uint128(uint256(quantity) * numerator / denominator);
        remainingPayout -= paid;
        if (paid != 0) transferExact(msg.sender, paid, false);
        requireCovered();
        emit Redeemed(msg.sender, scope, mask, quantity, paid);
    }

    function baseClaim(uint8 eventIndex, bool outcome) public view returns (uint32 scope, uint8 mask) {
        if (eventIndex >= eventCount) revert InvalidBaseEvent();
        return (uint32(1) << eventIndex, outcome ? 2 : 1);
    }

    function createBaseToken(uint8 eventIndex, bool outcome) external nonReentrant returns (FactoredBaseToken token) {
        (uint32 scope, uint8 mask) = baseClaim(eventIndex, outcome);
        token = baseTokens[scope][mask];
        if (address(token) != address(0)) return token;
        token = baseTokenFactory.create(eventIndex, outcome, collateralDecimals);
        baseTokens[scope][mask] = token;
        emit BaseTokenCreated(eventIndex, outcome, scope, mask, address(token));
    }

    function wrapBase(uint8 eventIndex, bool outcome, uint128 quantity) external nonReentrant {
        (uint32 scope, uint8 mask) = baseClaim(eventIndex, outcome);
        FactoredBaseToken token = baseTokens[scope][mask];
        if (address(token) == address(0)) revert BaseTokenNotCreated();
        positions.debit(msg.sender, scope, mask, quantity);
        positions.credit(address(token), scope, mask, quantity);
        token.mint(msg.sender, quantity);
        emit BaseWrapped(msg.sender, scope, mask, quantity);
    }

    function unwrapBase(uint8 eventIndex, bool outcome, uint128 quantity) external nonReentrant {
        (uint32 scope, uint8 mask) = baseClaim(eventIndex, outcome);
        FactoredBaseToken token = baseTokens[scope][mask];
        if (address(token) == address(0)) revert BaseTokenNotCreated();
        if (quantity == 0) revert P.InvalidQuantity();
        token.burn(msg.sender, quantity);
        positions.debit(address(token), scope, mask, quantity);
        positions.credit(msg.sender, scope, mask, quantity);
        emit BaseUnwrapped(msg.sender, scope, mask, quantity);
    }

    function project(uint32 scope, uint32 state) private pure returns (uint256 local) {
        uint256 index;
        while (scope != 0) {
            uint32 bit = scope & (~scope + 1);
            if ((state & bit) != 0) local |= uint256(1) << index;
            index++;
            scope &= scope - 1;
        }
    }
    function popcount(uint256 value) private pure returns (uint256 count) {
        while (value != 0) { value &= value - 1; count++; }
    }}
