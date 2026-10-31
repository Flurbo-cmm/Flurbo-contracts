// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {HybridPilotResolver} from "../src/HybridPilotResolver.sol";
import {CondPilotPool} from "../src/CondPilotPool.sol";
import {LsPricer} from "../src/LsPricer.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ConditionalDeployVm {
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

contract DeployConditionalPilot {
    ConditionalDeployVm private constant vm =
        ConditionalDeployVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant AUSD = 0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC;
    string private constant PREPARED = "target/deployments/conditional-pilot-prepared.json";
    string private constant PRICER = "target/deployments/ls-pricer.json";
    string private constant OUTPUT = "target/deployments/conditional-pilot-unverified.json";
    uint256 private constant MAX_CLOSE = 365 days;

    function run() external returns (CondPilotPool pool, HybridPilotResolver resolver) {
        require(block.chainid == 10143 && !vm.exists(OUTPUT), "new Monad testnet deployment only");
        string memory prepared = vm.readFile(PREPARED);
        require(keccak256(bytes(vm.parseJsonString(prepared, ".schema")))
            == keccak256(bytes("flurbo.hybrid-prepared.v5")), "wrong preparation version");
        LsPricer pricer = LsPricer(vm.parseJsonAddress(vm.readFile(PRICER), ".pricer"));
        require(address(pricer).code.length != 0 && pricer.version() == 1, "pricer version mismatch");
        address creator = vm.envAddress("FLURBO_DEPLOYER");
        require(creator == vm.parseJsonAddress(prepared, ".creator"), "creator mismatch");
        bytes memory encoded = vm.parseJsonBytes(prepared, ".resolverConfig");
        bytes32 configHash = vm.parseJsonBytes32(prepared, ".configHash");
        require(keccak256(encoded) == configHash, "config hash mismatch");
        HybridPilotResolver.Config memory c = abi.decode(encoded, (HybridPilotResolver.Config));
        uint256 depth = vm.parseJsonUint(prepared, ".liquidityAtoms");
        uint256 commission = vm.parseJsonUint(prepared, ".commissionBps");
        checkConfig(creator, c, depth, commission);
        require(IERC20Metadata(AUSD).decimals() == 6, "collateral precision mismatch");
        (pool, resolver) = deploy(creator, c, depth, commission, pricer);
        vm.serializeString("hybrid", "schema", "flurbo.hybrid-manifest.v5");
        vm.serializeString("hybrid", "status", "unverified_deployment");
        vm.serializeAddress("hybrid", "creator", creator);
        vm.serializeAddress("hybrid", "proposer", c.proposer);
        vm.serializeAddress("hybrid", "relay", c.relay);
        vm.serializeAddress("hybrid", "pool", address(pool));
        vm.serializeAddress("hybrid", "resolver", address(resolver));
        vm.serializeAddress("hybrid", "pricer", address(pricer));
        vm.serializeBytes32("hybrid", "draftHash", c.draftHash);
        vm.serializeBytes32("hybrid", "configHash", configHash);
        vm.serializeBytes32("hybrid", "rulesHash", resolver.rulesHash());
        vm.serializeUint("hybrid", "commissionBps", commission);
        vm.serializeUint("hybrid", "initialDepthAtoms", depth);
        vm.serializeUint("hybrid", "depthRate", pool.depthRate());
        vm.serializeUint("hybrid", "conditionalVersion", 1);
        string memory output = vm.serializeUint("hybrid", "eventCount", c.eventHashes.length);
        vm.writeJson(output, OUTPUT);
    }

    function checkConfig(address creator, HybridPilotResolver.Config memory c, uint256 depth, uint256 commission) internal view {
        require(c.collateral == AUSD && c.proposer != creator && c.relay != creator
            && c.proposer != c.relay && c.eventHashes.length >= 2 && c.eventHashes.length <= 32
            && c.closesAt > block.timestamp + 1 hours && c.closesAt <= block.timestamp + MAX_CLOSE
            && depth >= 10e6 && depth <= 1e12 && commission >= 100 && commission <= 2000, "invalid conditional configuration");
    }

    function deploy(address creator, HybridPilotResolver.Config memory c, uint256 depth, uint256 commission, LsPricer pricer)
        private
        returns (CondPilotPool pool, HybridPilotResolver resolver)
    {
        uint8[] memory order = new uint8[](c.eventHashes.length);
        for (uint8 i; i < order.length; ++i) order[i] = i;
        vm.startBroadcast(creator);
        resolver = new HybridPilotResolver(c);
        pool = new CondPilotPool(AUSD, uint8(order.length), uint128(depth), uint16(commission), c.closesAt,
            order, address(resolver), resolver.rulesHash(), pricer);
        resolver.bindPool(address(pool));
        uint128 funding = pool.requiredFunding();
        require(IERC20Metadata(AUSD).balanceOf(creator) >= funding, "insufficient test AUSD");
        require(IERC20Metadata(AUSD).approve(address(pool), funding), "approve failed");
        pool.fund();
        require(pool.depth() == depth * 1e12 && pool.commissionBps() == commission, "pricing mismatch");
        require(pool.sponsor() == creator, "sponsor mismatch");
        require(pool.conditionalVersion() == 1 && address(pool.pricer()) == address(pricer), "conditional mismatch");
        require(IERC20Metadata(AUSD).approve(address(pool), 0), "approval reset failed");
        vm.stopBroadcast();
    }
}
