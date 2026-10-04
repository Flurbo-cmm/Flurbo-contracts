// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {MechanicalKlerosCase} from "../src/MechanicalKlerosCase.sol";

interface KlerosVm {
    function chainId(uint256) external;
    function deal(address, uint256) external;
    function prank(address) external;
}

interface IRuleTarget {
    function rule(uint256 disputeId, uint256 ruling) external;
}

contract MockKlerosArbitrator {
    uint256 public nextId = 1;
    uint256 public constant COST = 0.01 ether;
    mapping(uint256 => address) public requester;

    function arbitrationCost(bytes calldata) external pure returns (uint256) { return COST; }

    function createDispute(uint256 choices, bytes calldata) external payable returns (uint256 id) {
        require(choices == 3 && msg.value == COST);
        id = nextId++;
        requester[id] = msg.sender;
    }

    function decide(uint256 id, uint256 ruling) external {
        IRuleTarget(requester[id]).rule(id, ruling);
    }
}

contract MechanicalKlerosCaseTest {
    KlerosVm constant vm = KlerosVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant REQUEST = keccak256("monad challenge");
    bytes32 constant QUESTION = keccak256("official source rule");
    MockKlerosArbitrator arbitrator;
    MechanicalKlerosCase adapter;

    function setUp() public {
        vm.chainId(11155111);
        vm.deal(address(this), 1 ether);
        arbitrator = new MockKlerosArbitrator();
        adapter = new MechanicalKlerosCase(address(arbitrator), address(this), hex"01",
            "https://example.org/kleros-policy.json");
    }

    function testOpenEvidenceAndRuling() public {
        uint256 disputeId = adapter.openCase{value: 0.01 ether}(REQUEST, QUESTION,
            "https://example.org/initial-evidence.json");
        assert(disputeId == 1);
        assert(adapter.requestForDispute(disputeId) == REQUEST);
        assert(adapter.sourceCaseId(REQUEST) == keccak256(abi.encode(uint256(11155111), address(adapter), disputeId, REQUEST)));
        adapter.submitEvidence(REQUEST, "https://example.org/counter-evidence.json");
        arbitrator.decide(disputeId, 2);
        MechanicalKlerosCase.Case memory c = adapter.caseState(REQUEST);
        assert(c.ruled && c.ruling == 2 && c.questionHash == QUESTION);
        (bool extraEvidence,) = address(adapter).call(abi.encodeCall(MechanicalKlerosCase.submitEvidence,
            (REQUEST, "https://example.org/too-late.json")));
        assert(!extraEvidence);
    }

    function testUnauthorizedOrDuplicateCaseRejected() public {
        vm.deal(address(0xB0B), 0.01 ether);
        vm.prank(address(0xB0B));
        (bool outsider,) = address(adapter).call{value: 0.01 ether}(abi.encodeCall(MechanicalKlerosCase.openCase,
            (REQUEST, QUESTION, "https://example.org/evidence.json")));
        assert(!outsider);
        adapter.openCase{value: 0.01 ether}(REQUEST, QUESTION, "https://example.org/evidence.json");
        (bool duplicate,) = address(adapter).call{value: 0.01 ether}(abi.encodeCall(MechanicalKlerosCase.openCase,
            (REQUEST, QUESTION, "https://example.org/evidence.json")));
        assert(!duplicate);
        (bool spoof,) = address(adapter).call(abi.encodeCall(MechanicalKlerosCase.rule, (1, 1)));
        assert(!spoof);
        (bool badRuling,) = address(arbitrator).call(abi.encodeCall(MockKlerosArbitrator.decide, (1, 4)));
        assert(!badRuling);
        arbitrator.decide(1, 0);
        assert(adapter.caseState(REQUEST).ruling == 3);
    }
}
