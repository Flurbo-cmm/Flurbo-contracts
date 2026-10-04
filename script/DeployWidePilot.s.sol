// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {WidePilotResolver} from "../src/WidePilotResolver.sol";
import {WidePilotPool} from "../src/WidePilotPool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface WideDeployVm {
    function envAddress(string calldata) external returns (address);
    function exists(string calldata) external returns (bool);
    function readFile(string calldata) external view returns (string memory);
    function parseJsonBytes(string calldata, string calldata) external pure returns (bytes memory);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonBytes32(string calldata, string calldata) external pure returns (bytes32);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function startBroadcast(address) external;
    function stopBroadcast() external;
    function serializeAddress(string calldata, string calldata, address) external returns (string memory);
    function serializeBytes32(string calldata, string calldata, bytes32) external returns (string memory);
    function serializeUint(string calldata, string calldata, uint256) external returns (string memory);
    function serializeString(string calldata, string calldata, string calldata) external returns (string memory);
    function writeJson(string calldata, string calldata) external;
}

contract DeployWidePilot {
    WideDeployVm private constant vm = WideDeployVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant AUSD = 0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC;
    string private constant PREPARED = "target/deployments/wide-pilot-prepared.json";
    string private constant OUTPUT = "target/deployments/wide-pilot-unverified.json";

    function run() external returns (WidePilotPool pool, WidePilotResolver resolver) {
        require(block.chainid == 10143 && !vm.exists(OUTPUT), "new Monad testnet deployment only");
        string memory prepared = vm.readFile(PREPARED);
        require(
            keccak256(bytes(vm.parseJsonString(prepared, ".schema")))
                == keccak256(bytes("flurbo.wide-prepared.v3")),
            "wrong preparation version"
        );
        address creator = vm.envAddress("FLURBO_DEPLOYER");
        require(creator == vm.parseJsonAddress(prepared, ".creator"), "creator mismatch");
        bytes memory encoded = vm.parseJsonBytes(prepared, ".resolverConfig");
        bytes32 configHash = vm.parseJsonBytes32(prepared, ".configHash");
        require(keccak256(encoded) == configHash, "config hash mismatch");
        WidePilotResolver.Config memory c = abi.decode(encoded, (WidePilotResolver.Config));
        uint256 depth = vm.parseJsonUint(prepared, ".liquidityAtoms");
        require(c.collateral == AUSD && c.relay != creator && c.eventHashes.length >= 2 && c.eventHashes.length <= 32
            && c.closesAt > block.timestamp + 1 hours && c.closesAt <= block.timestamp + 30 days
            && depth >= 10e6 && depth <= 1e12, "invalid wide configuration");
        require(IERC20Metadata(AUSD).decimals() == 6, "collateral precision mismatch");
        uint8[] memory order = new uint8[](c.eventHashes.length);
        for (uint8 i; i < order.length; ++i) order[i] = i;
        vm.startBroadcast(creator);
        resolver = new WidePilotResolver(c);
        pool = new WidePilotPool(AUSD, uint8(order.length), uint128(depth), c.closesAt,
            order, address(resolver), resolver.rulesHash());
        resolver.bindPool(address(pool));
        uint128 funding = pool.requiredFunding();
        require(IERC20Metadata(AUSD).balanceOf(creator) >= funding, "insufficient test AUSD");
        require(IERC20Metadata(AUSD).approve(address(pool), funding), "approve failed");
        pool.fund();
        require(IERC20Metadata(AUSD).approve(address(pool), 0), "approval reset failed");
        vm.stopBroadcast();
        vm.serializeString("wide", "schema", "flurbo.wide-manifest.v3");
        vm.serializeString("wide", "status", "unverified_deployment");
        vm.serializeAddress("wide", "creator", creator);
        vm.serializeAddress("wide", "relay", c.relay);
        vm.serializeAddress("wide", "pool", address(pool));
        vm.serializeAddress("wide", "resolver", address(resolver));
        vm.serializeBytes32("wide", "draftHash", c.draftHash);
        vm.serializeBytes32("wide", "configHash", configHash);
        vm.serializeBytes32("wide", "rulesHash", resolver.rulesHash());
        string memory output = vm.serializeUint("wide", "eventCount", order.length);
        vm.writeJson(output, OUTPUT);
    }
}
