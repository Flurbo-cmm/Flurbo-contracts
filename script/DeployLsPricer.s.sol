// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {LsPricer} from "../src/LsPricer.sol";

interface PricerDeployVm {
    function envAddress(string calldata) external returns (address);
    function exists(string calldata) external returns (bool);
    function startBroadcast(address) external;
    function stopBroadcast() external;
    function serializeAddress(string calldata, string calldata, address) external returns (string memory);
    function serializeString(string calldata, string calldata, string calldata) external returns (string memory);
    function serializeUint(string calldata, string calldata, uint256) external returns (string memory);
    function writeJson(string calldata, string calldata) external;
}

contract DeployLsPricer {
    PricerDeployVm private constant vm = PricerDeployVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    string private constant OUTPUT = "target/deployments/ls-pricer.json";

    function run() external returns (LsPricer pricer) {
        require(block.chainid == 10143 && !vm.exists(OUTPUT), "new Monad testnet deployment only");
        address deployer = vm.envAddress("FLURBO_DEPLOYER");
        vm.startBroadcast(deployer);
        pricer = new LsPricer();
        vm.stopBroadcast();
        require(pricer.version() == 1, "pricer version mismatch");
        vm.serializeString("pricer", "schema", "flurbo.ls-pricer.v1");
        vm.serializeAddress("pricer", "pricer", address(pricer));
        string memory output = vm.serializeUint("pricer", "version", 1);
        vm.writeJson(output, OUTPUT);
    }
}
