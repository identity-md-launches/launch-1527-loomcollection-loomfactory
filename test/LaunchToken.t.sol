// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer;
    address internal alice;
    address internal bob;

    function setUp() public {
        deployer = makeAddr("launch factory");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_PolicySupplyAndIdentity() public view {
        assertEq(token.name(), "Loom");
        assertEq(token.symbol(), "LOOM");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(deployer), 1e27);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function testFuzz_PlainTransferConservesSupply(uint256 input) public {
        uint256 amount = bound(input, 0, 1e27);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_AllowanceTransferAndFailure() public {
        vm.prank(deployer);
        token.approve(alice, 7 ether);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 7 ether);
        assertEq(token.balanceOf(bob), 7 ether);
        assertEq(token.allowance(deployer, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_NoMintAdminOrUpgradeSurface() public {
        string[11] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory payload = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(deployer);
            (bool ownerSucceeded,) = address(token).call(payload);
            assertFalse(ownerSucceeded);
            vm.prank(alice);
            (bool strangerSucceeded,) = address(token).call(payload);
            assertFalse(strangerSucceeded);
            assertEq(token.totalSupply(), 1e27);
            assertEq(token.balanceOf(deployer), 1e27);
        }
    }
}
