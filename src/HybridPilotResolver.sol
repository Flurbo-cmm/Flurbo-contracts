// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WidePilotPool} from "./WidePilotPool.sol";

contract HybridPilotResolver is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidConfig();
    error Unauthorized();
    error WrongPhase();
    error InvalidOutcome();
    error InvalidEvidence();
    error UnsupportedTransfer();

    enum Outcome { Unset, No, Yes, Void }
    enum Route { Mechanical, Reality }
    enum Phase { Pending, Proposed, Disputed, Finalized }

    struct Config {
        address collateral;
        bytes32 draftHash;
        uint64 closesAt;
        bytes32[] eventHashes;
        uint64[] observationEnds;
        Route[] routes;
        address proposer;
        address relay;
        uint128 bond;
        uint32 assertionPeriod;
        uint32 challengePeriod;
        uint32 reportPeriod;
        uint32 arbitrationPeriod;
    }

    struct Case {
        Phase phase;
        Outcome proposal;
        Outcome counter;
        Outcome result;
        address challenger;
        bytes32 evidenceHash;
        bytes32 counterEvidenceHash;
        bytes32 requestId;
        bytes32 sourceCaseId;
        uint64 challengeUntil;
        uint64 arbitrationUntil;
    }

    IERC20 public immutable collateral;
    bytes32 public immutable draftHash;
    bytes32 public immutable rulesHash;
    uint64 public immutable closesAt;
    address public immutable creator;
    address public immutable proposer;
    address public immutable relay;
    uint128 public immutable bond;
    uint32 public immutable assertionPeriod;
    uint32 public immutable challengePeriod;
    uint32 public immutable reportPeriod;
    uint32 public immutable arbitrationPeriod;
    uint8 public immutable eventCount;
    bytes32[] public eventHashes;
    uint64[] public observationEnds;
    Route[] public routes;
    Case[] private cases;
    WidePilotPool public pool;
    bool public delivered;
    mapping(address => uint256) public credits;
    uint256 public lockedBonds;
    uint256 public totalCredits;

    event PoolBound(address indexed pool, bytes32 indexed rulesHash);
    event Proposed(uint8 indexed eventIndex, Outcome outcome, bytes32 evidenceHash, string evidenceURI, uint64 challengeUntil);
    event Challenged(uint8 indexed eventIndex, address indexed challenger, bytes32 indexed requestId, Outcome counter, bytes32 evidenceHash, string evidenceURI, uint64 arbitrationUntil);
    event SourceCaseLinked(uint8 indexed eventIndex, bytes32 indexed sourceCaseId);
    event RulingReported(uint8 indexed eventIndex, bytes32 indexed sourceCaseId, Outcome outcome, bytes32 evidenceHash, string evidenceURI);
    event RealityReported(uint8 indexed eventIndex, Outcome outcome, bytes32 evidenceHash, string evidenceURI);
    event Finalized(uint8 indexed eventIndex, Outcome outcome, bool timedOut);
    event Delivered(address indexed pool, uint32 yesMask, uint32 voidMask);
    event BondWithdrawn(address indexed owner, uint256 amount);

    constructor(Config memory c) {
        if (block.chainid != 10143 || c.collateral.code.length == 0 || c.draftHash == 0
            || c.closesAt <= block.timestamp || c.proposer == address(0) || c.relay == address(0)
            || c.proposer == c.relay || c.eventHashes.length < 2 || c.eventHashes.length > 32
            || c.eventHashes.length != c.observationEnds.length || c.eventHashes.length != c.routes.length
            || c.bond == 0 || c.assertionPeriod < 1 hours || c.assertionPeriod > 30 days
            || c.challengePeriod < 1 hours || c.challengePeriod > 7 days
            || c.reportPeriod < 1 hours || c.reportPeriod > 90 days
            || c.arbitrationPeriod < 30 days || c.arbitrationPeriod > 365 days) revert InvalidConfig();
        for (uint256 i; i < c.eventHashes.length; ++i) {
            if (c.eventHashes[i] == 0 || c.observationEnds[i] <= c.closesAt
                || uint256(c.observationEnds[i]) + c.assertionPeriod + c.challengePeriod + c.arbitrationPeriod > type(uint64).max
                || uint256(c.observationEnds[i]) + c.reportPeriod > type(uint64).max) revert InvalidConfig();
            for (uint256 j; j < i; ++j) if (c.eventHashes[i] == c.eventHashes[j]) revert InvalidConfig();
            cases.push();
        }
        collateral = IERC20(c.collateral);
        draftHash = c.draftHash;
        closesAt = c.closesAt;
        creator = msg.sender;
        proposer = c.proposer;
        relay = c.relay;
        bond = c.bond;
        assertionPeriod = c.assertionPeriod;
        challengePeriod = c.challengePeriod;
        reportPeriod = c.reportPeriod;
        arbitrationPeriod = c.arbitrationPeriod;
        eventCount = uint8(c.eventHashes.length);
        eventHashes = c.eventHashes;
        observationEnds = c.observationEnds;
        routes = c.routes;
        rulesHash = keccak256(abi.encode("flurbo.pilot.hybrid.v4", block.chainid, address(this), msg.sender, c));
    }

    function protocolVersion() external pure returns (uint8) { return 4; }

    function bindPool(address target) external {
        if (msg.sender != creator) revert Unauthorized();
        if (address(pool) != address(0) || target.code.length == 0) revert InvalidConfig();
        WidePilotPool candidate = WidePilotPool(target);
        if (candidate.protocolVersion() != 3 || candidate.resolver() != address(this)
            || candidate.settlementRulesHash() != rulesHash || address(candidate.collateral()) != address(collateral)
            || candidate.eventCount() != eventCount || candidate.closesAt() != closesAt) revert InvalidConfig();
        pool = candidate;
        emit PoolBound(target, rulesHash);
    }

    function caseState(uint8 eventIndex) external view returns (Case memory) { return cases[eventIndex]; }
    function assertionDeadline(uint8 eventIndex) public view returns (uint64) { return observationEnds[eventIndex] + assertionPeriod; }
    function reportDeadline(uint8 eventIndex) public view returns (uint64) { return observationEnds[eventIndex] + reportPeriod; }

    function disputeRequestId(uint8 eventIndex) external view returns (bytes32) {
        Case storage c = cases[eventIndex];
        if (c.requestId == 0) revert WrongPhase();
        return c.requestId;
    }

    function propose(uint8 eventIndex, Outcome outcome, bytes32 evidenceHash, string calldata evidenceURI) external nonReentrant {
        requireActive();
        if (msg.sender != proposer) revert Unauthorized();
        if (routes[eventIndex] != Route.Mechanical) revert WrongPhase();
        checkEvidence(outcome, evidenceHash, evidenceURI);
        Case storage c = cases[eventIndex];
        if (c.phase != Phase.Pending || block.timestamp < observationEnds[eventIndex]
            || block.timestamp >= assertionDeadline(eventIndex)) revert WrongPhase();
        takeBond(msg.sender);
        c.phase = Phase.Proposed;
        c.proposal = outcome;
        c.evidenceHash = evidenceHash;
        c.challengeUntil = uint64(block.timestamp + challengePeriod);
        emit Proposed(eventIndex, outcome, evidenceHash, evidenceURI, c.challengeUntil);
    }

    function challenge(uint8 eventIndex, Outcome counter, bytes32 evidenceHash, string calldata evidenceURI) external nonReentrant {
        requireActive();
        if (routes[eventIndex] != Route.Mechanical || msg.sender == proposer) revert Unauthorized();
        checkEvidence(counter, evidenceHash, evidenceURI);
        Case storage c = cases[eventIndex];
        if (c.phase != Phase.Proposed || block.timestamp >= c.challengeUntil || counter == c.proposal) revert WrongPhase();
        takeBond(msg.sender);
        c.phase = Phase.Disputed;
        c.counter = counter;
        c.challenger = msg.sender;
        c.counterEvidenceHash = evidenceHash;
        c.arbitrationUntil = uint64(block.timestamp + arbitrationPeriod);
        c.requestId = keccak256(abi.encode(block.chainid, address(this), rulesHash, eventIndex, eventHashes[eventIndex],
            msg.sender, c.proposal, counter, c.evidenceHash, evidenceHash));
        emit Challenged(eventIndex, msg.sender, c.requestId, counter, evidenceHash, evidenceURI, c.arbitrationUntil);
    }

    function linkSourceCase(uint8 eventIndex, bytes32 sourceCaseId) external {
        if (msg.sender != relay) revert Unauthorized();
        Case storage c = cases[eventIndex];
        if (c.phase != Phase.Disputed || c.sourceCaseId != 0 || sourceCaseId == 0
            || block.timestamp >= c.arbitrationUntil) revert WrongPhase();
        c.sourceCaseId = sourceCaseId;
        emit SourceCaseLinked(eventIndex, sourceCaseId);
    }

    function reportRuling(uint8 eventIndex, bytes32 sourceCaseId, Outcome outcome,
        bytes32 evidenceHash, string calldata evidenceURI) external nonReentrant {
        requireActive();
        if (msg.sender != relay) revert Unauthorized();
        checkEvidence(outcome, evidenceHash, evidenceURI);
        Case storage c = cases[eventIndex];
        if (c.phase != Phase.Disputed || c.sourceCaseId == 0 || c.sourceCaseId != sourceCaseId) revert WrongPhase();
        emit RulingReported(eventIndex, sourceCaseId, outcome, evidenceHash, evidenceURI);
        finish(eventIndex, outcome, false);
    }

    function reportReality(uint8 eventIndex, Outcome outcome, bytes32 evidenceHash, string calldata evidenceURI) external nonReentrant {
        requireActive();
        if (msg.sender != relay) revert Unauthorized();
        if (routes[eventIndex] != Route.Reality) revert WrongPhase();
        checkEvidence(outcome, evidenceHash, evidenceURI);
        Case storage c = cases[eventIndex];
        if (c.phase != Phase.Pending || block.timestamp < observationEnds[eventIndex]
            || block.timestamp >= reportDeadline(eventIndex)) revert WrongPhase();
        c.phase = Phase.Finalized;
        c.result = outcome;
        c.evidenceHash = evidenceHash;
        emit RealityReported(eventIndex, outcome, evidenceHash, evidenceURI);
        emit Finalized(eventIndex, outcome, false);
    }

    function finalize(uint8 eventIndex) external nonReentrant {
        requireActive();
        Case storage c = cases[eventIndex];
        if (c.phase == Phase.Pending) {
            uint64 deadline = routes[eventIndex] == Route.Mechanical ? assertionDeadline(eventIndex) : reportDeadline(eventIndex);
            if (block.timestamp < deadline) revert WrongPhase();
            finish(eventIndex, Outcome.Void, true);
        } else if (c.phase == Phase.Proposed && block.timestamp >= c.challengeUntil) {
            finish(eventIndex, c.proposal, false);
        } else if (c.phase == Phase.Disputed && c.sourceCaseId == 0
            && block.timestamp >= c.arbitrationUntil) {
            finish(eventIndex, Outcome.Void, true);
        } else revert WrongPhase();
    }

    function deliver() external nonReentrant {
        requireActive();
        uint32 yesMask;
        uint32 voidMask;
        for (uint8 i; i < eventCount; ++i) {
            if (cases[i].phase != Phase.Finalized) revert WrongPhase();
            if (cases[i].result == Outcome.Yes) yesMask |= uint32(1) << i;
            if (cases[i].result == Outcome.Void) voidMask |= uint32(1) << i;
        }
        delivered = true;
        pool.resolve(yesMask, voidMask);
        emit Delivered(address(pool), yesMask, voidMask);
    }

    function withdrawBond() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert WrongPhase();
        credits[msg.sender] = 0;
        totalCredits -= amount;
        uint256 beforeSelf = collateral.balanceOf(address(this));
        uint256 beforeOwner = collateral.balanceOf(msg.sender);
        collateral.safeTransfer(msg.sender, amount);
        if (collateral.balanceOf(address(this)) + amount != beforeSelf
            || collateral.balanceOf(msg.sender) != beforeOwner + amount) revert UnsupportedTransfer();
        emit BondWithdrawn(msg.sender, amount);
    }

    function takeBond(address owner) private {
        uint256 beforeSelf = collateral.balanceOf(address(this));
        uint256 beforeOwner = collateral.balanceOf(owner);
        collateral.safeTransferFrom(owner, address(this), bond);
        if (collateral.balanceOf(address(this)) != beforeSelf + bond
            || collateral.balanceOf(owner) + bond != beforeOwner) revert UnsupportedTransfer();
        lockedBonds += bond;
    }

    function finish(uint8 eventIndex, Outcome outcome, bool timedOut) private {
        Case storage c = cases[eventIndex];
        if (c.phase == Phase.Proposed) credit(proposer, bond);
        else if (c.phase == Phase.Disputed) {
            if (outcome == c.proposal) credit(proposer, uint256(bond) * 2);
            else if (outcome == c.counter) credit(c.challenger, uint256(bond) * 2);
            else { credit(proposer, bond); credit(c.challenger, bond); }
        }
        c.phase = Phase.Finalized;
        c.result = outcome;
        emit Finalized(eventIndex, outcome, timedOut);
    }

    function credit(address owner, uint256 amount) private {
        lockedBonds -= amount;
        credits[owner] += amount;
        totalCredits += amount;
    }

    function checkEvidence(Outcome outcome, bytes32 hash, string calldata uri) private pure {
        if (outcome == Outcome.Unset) revert InvalidOutcome();
        bytes memory value = bytes(uri);
        if (hash == 0 || value.length < 8 || value.length > 512
            || (bytes8(value) != bytes8("https://") && bytes7(value) != bytes7("ipfs://"))) revert InvalidEvidence();
    }

    function requireActive() private view {
        if (address(pool) == address(0) || !pool.funded() || delivered) revert WrongPhase();
    }
}
