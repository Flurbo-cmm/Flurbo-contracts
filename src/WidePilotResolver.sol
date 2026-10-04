// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WidePilotPool} from "./WidePilotPool.sol";

/// @notice Testnet resolver with one explicitly trusted cross-chain relay.
/// @dev Kleros arbitration happens inside Reality.eth before the relay reports a final answer.
contract WidePilotResolver is ReentrancyGuard {
    error InvalidConfig();
    error Unauthorized();
    error WrongPhase();
    error InvalidEvidence();
    error InvalidOutcome();

    enum Outcome { Unset, No, Yes, Void }
    enum Phase { Pending, Finalized }

    struct Config {
        address collateral;
        bytes32 draftHash;
        uint64 closesAt;
        bytes32[] eventHashes;
        uint64[] observationEnds;
        address relay;
        uint32 reportPeriod;
    }

    struct Case {
        Phase phase;
        Outcome result;
        bytes32 evidenceHash;
    }

    address public immutable creator;
    IERC20 public immutable collateral;
    bytes32 public immutable draftHash;
    bytes32 public immutable rulesHash;
    uint64 public immutable closesAt;
    address public immutable relay;
    uint32 public immutable reportPeriod;
    uint8 public immutable eventCount;
    bytes32[] public eventHashes;
    uint64[] public observationEnds;
    Case[] private cases;
    WidePilotPool public pool;
    bool public delivered;

    event PoolBound(address indexed pool, bytes32 indexed rulesHash);
    event FinalReported(uint8 indexed eventIndex, Outcome outcome, bytes32 evidenceHash, string evidenceURI);
    event MissingFinalized(uint8 indexed eventIndex);
    event Delivered(address indexed pool, uint32 yesMask, uint32 voidMask);

    constructor(Config memory c) {
        if (block.chainid != 10143 || c.collateral.code.length == 0 || c.draftHash == 0
            || c.closesAt <= block.timestamp || c.relay == address(0)
            || c.eventHashes.length < 2 || c.eventHashes.length > 32
            || c.eventHashes.length != c.observationEnds.length
            || c.reportPeriod < 1 hours || c.reportPeriod > 90 days) revert InvalidConfig();
        for (uint256 i; i < c.eventHashes.length; ++i) {
            if (c.eventHashes[i] == 0 || c.observationEnds[i] <= c.closesAt
                || uint256(c.observationEnds[i]) + c.reportPeriod > type(uint64).max) revert InvalidConfig();
            for (uint256 j; j < i; ++j) if (c.eventHashes[i] == c.eventHashes[j]) revert InvalidConfig();
            cases.push();
        }
        creator = msg.sender;
        collateral = IERC20(c.collateral);
        draftHash = c.draftHash;
        closesAt = c.closesAt;
        relay = c.relay;
        reportPeriod = c.reportPeriod;
        eventCount = uint8(c.eventHashes.length);
        eventHashes = c.eventHashes;
        observationEnds = c.observationEnds;
        rulesHash = keccak256(abi.encode("flurbo.pilot.trusted-relay.v3", block.chainid, address(this), msg.sender, c));
    }

    function protocolVersion() external pure returns (uint8) { return 3; }

    function bindPool(address target) external {
        if (msg.sender != creator) revert Unauthorized();
        if (address(pool) != address(0) || target.code.length == 0) revert InvalidConfig();
        WidePilotPool candidate = WidePilotPool(target);
        if (candidate.protocolVersion() != 3 || candidate.resolver() != address(this)
            || candidate.settlementRulesHash() != rulesHash
            || address(candidate.collateral()) != address(collateral)
            || candidate.eventCount() != eventCount || candidate.closesAt() != closesAt) revert InvalidConfig();
        pool = candidate;
        emit PoolBound(target, rulesHash);
    }

    function caseState(uint8 eventIndex) external view returns (Case memory) { return cases[eventIndex]; }
    function reportDeadline(uint8 eventIndex) public view returns (uint64) { return observationEnds[eventIndex] + reportPeriod; }

    function reportFinal(uint8 eventIndex, Outcome outcome, bytes32 evidenceHash, string calldata evidenceURI) external {
        requireActive();
        if (msg.sender != relay) revert Unauthorized();
        if (outcome == Outcome.Unset) revert InvalidOutcome();
        checkEvidence(evidenceHash, evidenceURI);
        Case storage c = cases[eventIndex];
        if (c.phase != Phase.Pending || block.timestamp < observationEnds[eventIndex]
            || block.timestamp >= reportDeadline(eventIndex)) revert WrongPhase();
        c.phase = Phase.Finalized;
        c.result = outcome;
        c.evidenceHash = evidenceHash;
        emit FinalReported(eventIndex, outcome, evidenceHash, evidenceURI);
    }

    function finalizeMissing(uint8 eventIndex) external {
        requireActive();
        Case storage c = cases[eventIndex];
        if (c.phase != Phase.Pending || block.timestamp < reportDeadline(eventIndex)) revert WrongPhase();
        c.phase = Phase.Finalized;
        c.result = Outcome.Void;
        emit MissingFinalized(eventIndex);
    }

    function deliver() external nonReentrant {
        requireActive();
        uint32 yesMask;
        uint32 invalidMask;
        for (uint8 i; i < eventCount; ++i) {
            if (cases[i].phase != Phase.Finalized) revert WrongPhase();
            if (cases[i].result == Outcome.Yes) yesMask |= uint32(1) << i;
            if (cases[i].result == Outcome.Void) invalidMask |= uint32(1) << i;
        }
        delivered = true;
        pool.resolve(yesMask, invalidMask);
        emit Delivered(address(pool), yesMask, invalidMask);
    }

    function checkEvidence(bytes32 hash, string calldata uri) private pure {
        if (hash == 0 || bytes(uri).length < 8 || bytes(uri).length > 512) revert InvalidEvidence();
        bytes memory value = bytes(uri);
        if (bytes8(value) != bytes8("https://") && bytes7(value) != bytes7("ipfs://")) revert InvalidEvidence();
    }

    function requireActive() private view {
        if (address(pool) == address(0) || !pool.funded() || delivered) revert WrongPhase();
    }
}
