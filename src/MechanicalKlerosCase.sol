// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IKlerosArbitrator {
    function arbitrationCost(bytes calldata extraData) external view returns (uint256);
    function createDispute(uint256 choices, bytes calldata extraData) external payable returns (uint256);
}

contract MechanicalKlerosCase is ReentrancyGuard {
    error InvalidConfig();
    error Unauthorized();
    error WrongPhase();
    error InvalidEvidence();
    error InvalidRuling();
    error RefundFailed();

    struct Case {
        uint256 disputeId;
        bytes32 requestId;
        bytes32 questionHash;
        uint8 ruling;
        bool opened;
        bool ruled;
    }

    IKlerosArbitrator public immutable arbitrator;
    address public immutable manager;
    string public metaEvidenceURI;
    bytes public extraData;
    mapping(bytes32 => Case) private cases;
    mapping(uint256 => bytes32) public requestForDispute;

    event MetaEvidence(uint256 indexed metaEvidenceID, string evidence);
    event Dispute(address indexed arbitrator, uint256 indexed disputeID, uint256 metaEvidenceID, uint256 evidenceGroupID);
    event Evidence(address indexed arbitrator, uint256 indexed evidenceGroupID, address indexed party, string evidence);
    event CaseOpened(bytes32 indexed requestId, uint256 indexed disputeId, bytes32 indexed questionHash, bytes32 sourceCaseId);
    event Ruling(address indexed arbitrator, uint256 indexed disputeID, uint256 ruling);

    constructor(address arbitrator_, address manager_, bytes memory extraData_, string memory metaEvidenceURI_) {
        bytes memory uri = bytes(metaEvidenceURI_);
        if (block.chainid != 11155111 || arbitrator_.code.length == 0 || manager_ == address(0)
            || extraData_.length > 256 || uri.length < 8 || uri.length > 512
            || (bytes8(uri) != bytes8("https://") && bytes7(uri) != bytes7("ipfs://"))) revert InvalidConfig();
        arbitrator = IKlerosArbitrator(arbitrator_);
        manager = manager_;
        extraData = extraData_;
        metaEvidenceURI = metaEvidenceURI_;
        emit MetaEvidence(0, metaEvidenceURI_);
    }

    function arbitrationCost() external view returns (uint256) {
        return arbitrator.arbitrationCost(extraData);
    }

    function sourceCaseId(bytes32 requestId) public view returns (bytes32) {
        Case storage c = cases[requestId];
        if (!c.opened) revert WrongPhase();
        return keccak256(abi.encode(block.chainid, address(this), c.disputeId, requestId));
    }

    function caseState(bytes32 requestId) external view returns (Case memory) {
        return cases[requestId];
    }

    function openCase(bytes32 requestId, bytes32 questionHash, string calldata evidenceURI)
        external payable nonReentrant returns (uint256 disputeId) {
        if (msg.sender != manager) revert Unauthorized();
        if (requestId == 0 || questionHash == 0 || cases[requestId].opened) revert WrongPhase();
        checkEvidence(evidenceURI);
        uint256 cost = arbitrator.arbitrationCost(extraData);
        if (cost == 0 || msg.value < cost) revert WrongPhase();
        disputeId = arbitrator.createDispute{value: cost}(3, extraData);
        if (requestForDispute[disputeId] != 0) revert WrongPhase();
        cases[requestId] = Case(disputeId, requestId, questionHash, 0, true, false);
        requestForDispute[disputeId] = requestId;
        bytes32 id = sourceCaseId(requestId);
        emit Dispute(address(arbitrator), disputeId, 0, disputeId);
        emit Evidence(address(arbitrator), disputeId, msg.sender, evidenceURI);
        emit CaseOpened(requestId, disputeId, questionHash, id);
        if (msg.value > cost) {
            (bool ok,) = payable(msg.sender).call{value: msg.value - cost}("");
            if (!ok) revert RefundFailed();
        }
    }

    function submitEvidence(bytes32 requestId, string calldata evidenceURI) external {
        Case storage c = cases[requestId];
        if (!c.opened || c.ruled) revert WrongPhase();
        checkEvidence(evidenceURI);
        emit Evidence(address(arbitrator), c.disputeId, msg.sender, evidenceURI);
    }

    function rule(uint256 disputeId, uint256 ruling) external {
        if (msg.sender != address(arbitrator)) revert Unauthorized();
        if (ruling > 3) revert InvalidRuling();
        bytes32 requestId = requestForDispute[disputeId];
        Case storage c = cases[requestId];
        if (!c.opened || c.disputeId != disputeId || c.ruled) revert WrongPhase();
        c.ruled = true;
        c.ruling = uint8(ruling == 0 ? 3 : ruling);
        emit Ruling(msg.sender, disputeId, ruling);
    }

    function checkEvidence(string calldata uri) private pure {
        bytes memory value = bytes(uri);
        if (value.length < 8 || value.length > 512
            || (bytes8(value) != bytes8("https://") && bytes7(value) != bytes7("ipfs://"))) revert InvalidEvidence();
    }
}
