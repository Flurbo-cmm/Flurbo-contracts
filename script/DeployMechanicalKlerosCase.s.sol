// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {MechanicalKlerosCase} from "../src/MechanicalKlerosCase.sol";

interface CaseDeployVm {
    function envAddress(string calldata) external returns (address);
    function envBytes(string calldata) external returns (bytes memory);
    function envString(string calldata) external returns (string memory);
    function startBroadcast(address) external;
    function stopBroadcast() external;
}

contract DeployMechanicalKlerosCase {
    CaseDeployVm private constant vm = CaseDeployVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (MechanicalKlerosCase adapter) {
        require(block.chainid == 11155111, "Sepolia only");
        address creator = vm.envAddress("FLURBO_DEPLOYER");
        address arbitrator = vm.envAddress("FLURBO_KLEROS_ARBITRATOR");
        address manager = vm.envAddress("FLURBO_CASE_MANAGER");
        bytes memory extraData = vm.envBytes("FLURBO_KLEROS_EXTRA_DATA");
        string memory metaEvidenceURI = vm.envString("FLURBO_CASE_META_EVIDENCE_URI");
        require(creator != manager && arbitrator != manager, "separate case manager");
        vm.startBroadcast(creator);
        adapter = new MechanicalKlerosCase(arbitrator, manager, extraData, metaEvidenceURI);
        vm.stopBroadcast();
    }
}
