// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LoomCollection} from "../src/LoomCollection.sol";
import {LoomFactory} from "../src/LoomFactory.sol";

contract DeploymentTest is Test {
    /// @dev Replicates the provided project floor without environment reads or external RPC.
    function test_DeployableRuntimeAndUnchangedPolicySupply() public {
        address launchOwner = makeAddr("launch owner");
        address launchFactory = makeAddr("launch factory");
        vm.prank(launchFactory);
        LaunchToken token = new LaunchToken();
        vm.prank(launchFactory);
        LoomCollection logic = new LoomCollection(launchOwner, launchOwner);
        vm.prank(launchFactory);
        LoomFactory factory = new LoomFactory(address(logic), launchOwner, launchOwner);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(launchFactory), 1e27);
        assertEq(token.balanceOf(address(logic)), 0);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(factory.pauser(), launchOwner);
        assertEq(logic.PLATFORM(), launchOwner);
        assertEq(logic.RESERVE(), launchOwner);
        _checkRuntime(address(token));
        _checkRuntime(address(logic));
        _checkRuntime(address(factory));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden top-level runtime opcode");
        }
    }
}
