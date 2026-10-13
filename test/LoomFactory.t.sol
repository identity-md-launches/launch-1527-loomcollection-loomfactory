// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase, LoomCollection, LoomFactory} from "./helpers/LoomTestBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LoomFactoryTest is LoomTestBase {
    event CollectionCreated(address indexed collection, address indexed owner, string name, uint256 maxSupply);

    function test_CreateChargesFeeInitializesAndEnumerates() public {
        assertEq(factory.collectionCount(), 1);
        assertEq(factory.collections(0), address(collection));
        assertTrue(factory.isCollection(address(collection)));
        assertFalse(factory.isCollection(address(implementation)));
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.PLATFORM(), platform);
        assertEq(factory.pauser(), pauser);
        assertEq(factory.CREATE_FEE(), CREATE_FEE);

        uint256 platformBefore = platform.balance;
        uint256 bobBefore = bob.balance;
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(true, true, false, true, address(factory));
        emit CollectionCreated(predicted, bob, "Second", 250);
        LoomCollection second = _create(bob, "Second", "TWO", 250, 0.1 ether, 5, alice, 1_000);
        assertEq(address(second), predicted);
        assertEq(platform.balance - platformBefore, CREATE_FEE);
        assertEq(bobBefore - bob.balance, CREATE_FEE);
        assertEq(address(factory).balance, 0);
        assertEq(factory.collectionCount(), 2);
        assertEq(factory.collections(1), address(second));
        assertTrue(factory.isCollection(address(second)));
        assertEq(second.owner(), bob);
        assertEq(second.creator(), alice);
        assertEq(second.mintPrice(), 0.1 ether);
        assertEq(second.name(), "Second");
        assertEq(second.symbol(), "TWO");
        assertEq(second.maxSupply(), 250);
        assertEq(second.maxPerWallet(), 5);
        assertEq(second.royaltyBps(), 1_000);
        assertEq(second.baseURI(), "");
        vm.expectRevert();
        factory.collections(2);
    }

    function test_CloneHasCanonicalMinimalProxyCode() public view {
        bytes memory expected =
            abi.encodePacked(hex"363d3d373d3d3d363d73", address(implementation), hex"5af43d82803e903d91602b57fd5bf3");
        assertEq(address(collection).code, expected);
        assertEq(address(collection).code.length, 45);
    }

    function test_CreateRejectsMissingShortAndExcessFee() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.IncorrectCreationFee.selector, CREATE_FEE, 0));
        factory.createCollection("Fail", "F", 100, 0, 1, creator, 0);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.IncorrectCreationFee.selector, CREATE_FEE, CREATE_FEE - 1));
        factory.createCollection{value: CREATE_FEE - 1}("Fail", "F", 100, 0, 1, creator, 0);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.IncorrectCreationFee.selector, CREATE_FEE, CREATE_FEE + 1));
        factory.createCollection{value: CREATE_FEE + 1}("Fail", "F", 100, 0, 1, creator, 0);
        vm.stopPrank();
        assertEq(factory.collectionCount(), 1);
        assertEq(platform.balance, CREATE_FEE);
    }

    function testFuzz_CreateRequiresExactFee(uint96 supplied) public {
        vm.assume(uint256(supplied) != CREATE_FEE);
        vm.deal(alice, supplied);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LoomFactory.IncorrectCreationFee.selector, CREATE_FEE, uint256(supplied))
        );
        factory.createCollection{value: supplied}("Fail", "F", 100, 0, 1, creator, 0);
        assertEq(factory.collectionCount(), 1);
        assertEq(alice.balance, supplied);
    }

    function test_InvalidCollectionRollsBackCreationAndFee() public {
        uint256 before = alice.balance;
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.prank(alice);
        vm.expectRevert(LoomCollection.InvalidSupply.selector);
        factory.createCollection{value: CREATE_FEE}("Fail", "F", 0, PRICE, 1, creator, 0);
        assertEq(alice.balance, before);
        assertEq(platform.balance, CREATE_FEE);
        assertEq(factory.collectionCount(), 1);
        assertFalse(factory.isCollection(predicted));
        assertEq(predicted.code.length, 0);
        LoomCollection valid = _create(alice, "Valid", "V", 100, 0, 1, creator, 0);
        assertEq(address(valid), predicted);
    }

    function test_OnlyPauserCanPauseAndResumeCreation() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.UnauthorizedPauser.selector, alice));
        factory.pause();
        vm.prank(pauser);
        factory.pause();
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createCollection{value: CREATE_FEE}("Blocked", "B", 100, 0, 1, creator, 0);
        // Factory pauses have no effect on existing collections.
        _mint(alice, 1);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.UnauthorizedPauser.selector, platform));
        factory.unpause();
        vm.prank(pauser);
        factory.unpause();
        _create(bob, "Works", "W", 100, 0, 1, creator, 0);
        assertEq(factory.collectionCount(), 2);
    }

    function test_PauserHasNoCollectionPrivileges() public {
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, pauser));
        collection.pause();
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(factory))
        );
        collection.setBaseURI("bad");
    }

    function test_ConstructorRejectsZeroArguments() public {
        vm.expectRevert(LoomFactory.InvalidAddress.selector);
        new LoomFactory(address(0), platform, pauser);
        vm.expectRevert(LoomFactory.InvalidAddress.selector);
        new LoomFactory(address(implementation), address(0), pauser);
        vm.expectRevert(LoomFactory.InvalidAddress.selector);
        new LoomFactory(address(implementation), platform, address(0));
    }

    function test_ConstructorDoesNotCallUndeployedDependency() public {
        address futureImplementation = makeAddr("future implementation");
        LoomFactory early = new LoomFactory(futureImplementation, platform, pauser);
        assertEq(early.implementation(), futureImplementation);
        vm.prank(alice);
        vm.expectRevert(LoomFactory.InvalidImplementation.selector);
        early.createCollection{value: CREATE_FEE}("Not live", "NL", 100, 0, 1, creator, 0);
        assertEq(early.collectionCount(), 0);
    }

    function test_RejectsPlatformMismatchAtFirstUse() public {
        LoomFactory mismatched = new LoomFactory(address(implementation), reserve, pauser);
        vm.prank(alice);
        vm.expectRevert(LoomFactory.PlatformMismatch.selector);
        mismatched.createCollection{value: CREATE_FEE}("Mismatch", "M", 100, 0, 1, creator, 0);
        assertEq(mismatched.collectionCount(), 0);
    }

    function test_TwoClonesShareNoMutableState() public {
        LoomCollection second = _create(bob, "Other", "OTH", 200, 0, 2, bob, 250);
        assertNotEq(address(collection), address(second));
        assertEq(second.PLATFORM(), collection.PLATFORM());
        assertEq(second.RESERVE(), collection.RESERVE());

        vm.startPrank(collectionOwner);
        collection.setProvenanceHash(keccak256("first provenance"));
        collection.setRevealSeed(keccak256("first seed"));
        collection.setBaseURI("ipfs://first/");
        collection.setUnrevealedURI("ipfs://first-preview");
        collection.reserveMint(1);
        collection.freezeMetadata();
        collection.transferOwnership(alice);
        vm.stopPrank();
        _mint(alice, 3);
        vm.prank(collectionOwner);
        collection.pause();
        vm.prank(alice);
        collection.approve(bob, 2);
        vm.prank(alice);
        collection.setApprovalForAll(bob, true);

        assertEq(second.name(), "Other");
        assertEq(second.symbol(), "OTH");
        assertEq(second.owner(), bob);
        assertEq(second.pendingOwner(), address(0));
        assertEq(second.creator(), bob);
        assertEq(second.maxSupply(), 200);
        assertEq(second.maxPerWallet(), 2);
        assertEq(second.mintPrice(), 0);
        assertEq(second.royaltyBps(), 250);
        assertEq(second.totalSupply(), 0);
        assertEq(second.balanceOf(alice), 0);
        assertEq(second.mintedPerWallet(alice), 0);
        assertEq(second.reserveMinted(), 0);
        assertEq(second.baseURI(), "");
        assertEq(second.unrevealedURI(), "");
        assertEq(second.provenanceHash(), bytes32(0));
        assertEq(second.revealSeed(), bytes32(0));
        assertFalse(second.provenanceSet());
        assertFalse(second.revealSeedSet());
        assertFalse(second.metadataFrozen());
        assertFalse(second.paused());
        assertFalse(second.isApprovedForAll(alice, bob));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        second.getApproved(2);
        (address receiver, uint256 amount) = second.royaltyInfo(1, 1 ether);
        assertEq(receiver, bob);
        assertEq(amount, 0.025 ether);

        vm.prank(alice);
        second.mint{value: 2 * FEE}(2);
        vm.startPrank(bob);
        second.setRevealSeed(keccak256("second seed"));
        second.setBaseURI("ipfs://second/");
        second.reserveMint(2);
        vm.stopPrank();
        assertEq(second.ownerOf(1), alice);
        assertEq(second.tokenURI(1), "ipfs://second/1.json");
        assertEq(collection.ownerOf(1), collectionOwner);
        assertEq(collection.totalSupply(), 4);
        assertEq(collection.mintedPerWallet(alice), 3);
        assertEq(collection.reserveMinted(), 1);
        assertEq(collection.tokenURI(1), "ipfs://first/1.json");
        assertEq(collection.revealSeed(), keccak256("first seed"));
        assertTrue(collection.paused());
        assertEq(implementation.totalSupply(), 0);
        assertEq(implementation.baseURI(), "");
        assertEq(implementation.owner(), address(0));
    }
}
