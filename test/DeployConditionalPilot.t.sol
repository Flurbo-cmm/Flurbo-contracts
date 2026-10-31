// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;
import {DeployConditionalPilot} from "../script/DeployConditionalPilot.s.sol";
import {HybridPilotResolver as R} from "../src/HybridPilotResolver.sol";

interface ConditionalScriptVm { function warp(uint256) external; }
contract ConditionalDeploymentHarness is DeployConditionalPilot {
    function check(address creator, R.Config memory c, uint256 depth, uint256 commission) external view {
        checkConfig(creator, c, depth, commission);
    }
}
contract DeployConditionalPilotTest {
    ConditionalScriptVm constant vm = ConditionalScriptVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant AUSD = 0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC;
    address constant CREATOR = address(0xA11CE);
    uint256 constant NOW = 1_793_500_000;
    ConditionalDeploymentHarness script;
    function setUp() public { vm.warp(NOW); script = new ConditionalDeploymentHarness(); }
    function config(uint256 closesIn) internal pure returns (R.Config memory c) {
        c.collateral = AUSD; c.closesAt = uint64(NOW + closesIn);
        c.eventHashes = new bytes32[](3); c.proposer = address(0xB0B); c.relay = address(0xCAFE);
    }
    function refused(R.Config memory c, uint256 depth, uint256 commission) internal view returns (bool) {
        try script.check(CREATOR, c, depth, commission) { return false; }
        catch Error(string memory reason) { return keccak256(bytes(reason)) == keccak256("invalid conditional configuration"); }
    }
    function testAcceptsCloseUpToOneYearAhead() public view {
        script.check(CREATOR, config(2 hours), 50e6, 500);
        script.check(CREATOR, config(168 days), 50e6, 500);
        script.check(CREATOR, config(365 days), 50e6, 500);
    }
    function testRejectsCloseOutsideTheWindow() public view {
        assert(refused(config(1 hours), 50e6, 500));
        assert(refused(config(365 days + 1), 50e6, 500));
    }
    function testKeepsTheOtherLimits() public view {
        assert(refused(config(168 days), 5e6, 500));
        assert(refused(config(168 days), 50e6, 50));
        R.Config memory c = config(168 days);
        c.relay = c.proposer;
        assert(refused(c, 50e6, 500));
    }
}
