// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase, LoomCollection, LoomFactory} from "./helpers/LoomTestBase.sol";
import {CallbackActor, NoNFTReceiver} from "./helpers/CallbackActor.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract AdversarialTest is LoomTestBase {
    function test_RejectingCreatorRollsBackTokensCountersAndMoney() public {
        CallbackActor payee = new CallbackActor();
        collection = _create(collectionOwner, "Reject", "REJ", SUPPLY, PRICE, WALLET_CAP, address(payee), 750);
        payee.setRejectETH(true);
        uint256 aliceBefore = alice.balance;
        uint256 platformBefore = platform.balance;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.PaymentFailed.selector, address(payee), 0.0204 ether));
        collection.mint{value: 2 * (PRICE + FEE)}(2);
        _assertMintRolledBack(collection, aliceBefore, platformBefore);
        assertEq(address(payee).balance, 0);
        payee.setRejectETH(false);
        _mint(alice, 2);
        assertEq(collection.ownerOf(1), alice);
        assertEq(address(payee).balance, 0.0204 ether);
    }

    function test_RejectingPlatformRollsBackEarlierCreatorPayment() public {
        CallbackActor payee = new CallbackActor();
        LoomCollection logic = new LoomCollection(address(payee), reserve);
        LoomCollection subject = LoomCollection(Clones.clone(address(logic)));
        subject.initialize("Reject", "REJ", SUPPLY, PRICE, WALLET_CAP, creator, 750, collectionOwner);
        payee.setRejectETH(true);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.PaymentFailed.selector, address(payee), 0.0004 ether));
        subject.mint{value: 2 * (PRICE + FEE)}(2);
        assertEq(creator.balance, 0);
        assertEq(reserve.balance, 0);
        assertEq(address(payee).balance, 0);
        assertEq(alice.balance, aliceBefore);
        assertEq(subject.totalSupply(), 0);
        assertEq(subject.mintedPerWallet(alice), 0);
        payee.setRejectETH(false);
        vm.prank(alice);
        subject.mint{value: PRICE + FEE}(1);
        assertEq(subject.totalSupply(), 1);
    }

    function test_RejectingReserveRollsBackBothEarlierPayments() public {
        CallbackActor payee = new CallbackActor();
        LoomCollection logic = new LoomCollection(platform, address(payee));
        LoomCollection subject = LoomCollection(Clones.clone(address(logic)));
        subject.initialize("Reject", "REJ", SUPPLY, PRICE, WALLET_CAP, creator, 750, collectionOwner);
        payee.setRejectETH(true);
        uint256 aliceBefore = alice.balance;
        uint256 platformBefore = platform.balance;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.PaymentFailed.selector, address(payee), 0.0002 ether));
        subject.mint{value: 2 * (PRICE + FEE)}(2);
        _assertMintRolledBack(subject, aliceBefore, platformBefore);
        assertEq(address(payee).balance, 0);
    }

    function test_MintToContractWithoutReceiverReverts() public {
        NoNFTReceiver receiver = new NoNFTReceiver();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        receiver.mint{value: PRICE + FEE}(collection, 1);
        assertEq(collection.totalSupply(), 0);
        assertEq(collection.mintedPerWallet(address(receiver)), 0);
        assertEq(creator.balance, 0);
    }

    function test_SecondNFTReceiverRejectionRollsBackWholeBatch() public {
        CallbackActor receiver = new CallbackActor();
        receiver.setRejectNFTAt(2);
        uint256 before = address(this).balance;
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        receiver.execute{value: 3 * (PRICE + FEE)}(address(collection), abi.encodeCall(LoomCollection.mint, (3)));
        assertEq(address(this).balance, before);
        assertEq(receiver.nftCallbacks(), 0);
        assertEq(collection.totalSupply(), 0);
        assertEq(collection.mintedPerWallet(address(receiver)), 0);
        assertEq(collection.balanceOf(address(receiver)), 0);
        assertEq(creator.balance, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        collection.ownerOf(1);
        receiver.setRejectNFTAt(0);
        receiver.execute{value: 3 * (PRICE + FEE)}(address(collection), abi.encodeCall(LoomCollection.mint, (3)));
        assertEq(receiver.nftCallbacks(), 3);
        assertEq(collection.ownerOf(3), address(receiver));
    }

    function test_ReserveMintRejectingOwnerRollsBackAllowance() public {
        CallbackActor receiver = new CallbackActor();
        vm.deal(address(receiver), CREATE_FEE);
        collection = _create(address(receiver), "Owner", "OWN", SUPPLY, PRICE, WALLET_CAP, creator, 0);
        receiver.setRejectNFTAt(2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        receiver.execute(address(collection), abi.encodeCall(LoomCollection.reserveMint, (2)));
        assertEq(collection.totalSupply(), 0);
        assertEq(collection.reserveMinted(), 0);
        receiver.setRejectNFTAt(0);
        receiver.execute(address(collection), abi.encodeCall(LoomCollection.reserveMint, (2)));
        assertEq(collection.reserveMinted(), 2);
    }

    function test_ERC721CallbackCannotReenterMintAndSeesReservedCounters() public {
        CallbackActor receiver = new CallbackActor();
        vm.deal(address(receiver), 10 ether);
        receiver.configureAttack(
            address(collection), abi.encodeCall(LoomCollection.mint, (1)), PRICE + FEE, false, true
        );
        receiver.execute{value: 2 * (PRICE + FEE)}(address(collection), abi.encodeCall(LoomCollection.mint, (2)));
        assertEq(receiver.attempts(), 2);
        assertFalse(receiver.lastReentrySucceeded());
        assertEq(
            receiver.lastReentryResult(),
            abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(receiver.observedSupply(), 2);
        assertEq(receiver.observedWalletMints(), 2);
        assertEq(collection.totalSupply(), 2);
        assertEq(collection.mintedPerWallet(address(receiver)), 2);
        assertEq(creator.balance, 0.0204 ether);
    }

    function test_ETHRecipientCannotReenterMint() public {
        CallbackActor payee = new CallbackActor();
        collection = _create(collectionOwner, "Callback", "CB", SUPPLY, PRICE, WALLET_CAP, address(payee), 0);
        vm.deal(address(payee), 10 ether);
        payee.configureAttack(address(collection), abi.encodeCall(LoomCollection.mint, (1)), PRICE + FEE, true, false);
        _mint(alice, 2);
        assertEq(payee.attempts(), 1);
        assertFalse(payee.lastReentrySucceeded());
        assertEq(
            payee.lastReentryResult(),
            abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(collection.totalSupply(), 2);
        assertEq(collection.mintedPerWallet(address(payee)), 0);
        assertEq(address(payee).balance, 10 ether + 0.0204 ether);
    }

    function test_PublicMintCallbackCannotCrossReenterReserveMint() public {
        CallbackActor owner = new CallbackActor();
        vm.deal(address(owner), CREATE_FEE);
        collection = _create(address(owner), "Cross", "CR", SUPPLY, PRICE, WALLET_CAP, creator, 0);
        owner.configureAttack(address(collection), abi.encodeCall(LoomCollection.reserveMint, (1)), 0, false, true);
        owner.execute{value: PRICE + FEE}(address(collection), abi.encodeCall(LoomCollection.mint, (1)));
        assertFalse(owner.lastReentrySucceeded());
        assertEq(
            owner.lastReentryResult(),
            abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(collection.reserveMinted(), 0);
        assertEq(collection.totalSupply(), 1);
        owner.execute(address(collection), abi.encodeCall(LoomCollection.reserveMint, (1)));
        assertEq(collection.reserveMinted(), 1);
    }

    function test_ReserveMintCallbackCannotCrossReenterPublicMint() public {
        CallbackActor owner = new CallbackActor();
        vm.deal(address(owner), 10 ether);
        collection = _create(address(owner), "Cross", "CR", SUPPLY, PRICE, WALLET_CAP, creator, 0);
        owner.configureAttack(address(collection), abi.encodeCall(LoomCollection.mint, (1)), PRICE + FEE, false, true);
        owner.execute(address(collection), abi.encodeCall(LoomCollection.reserveMint, (1)));
        assertFalse(owner.lastReentrySucceeded());
        assertEq(
            owner.lastReentryResult(),
            abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(collection.mintedPerWallet(address(owner)), 0);
        assertEq(collection.totalSupply(), 1);
    }

    function test_RejectingCreateFeeRollsBackRegistryAndClone() public {
        CallbackActor payee = new CallbackActor();
        LoomCollection logic = new LoomCollection(address(payee), reserve);
        LoomFactory subject = new LoomFactory(address(logic), address(payee), pauser);
        payee.setRejectETH(true);
        address predicted = vm.computeCreateAddress(address(subject), vm.getNonce(address(subject)));
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.PaymentFailed.selector, address(payee), CREATE_FEE));
        subject.createCollection{value: CREATE_FEE}("Fail", "F", 100, PRICE, 5, creator, 0);
        assertEq(alice.balance, aliceBefore);
        assertEq(subject.collectionCount(), 0);
        assertFalse(subject.isCollection(predicted));
        assertEq(predicted.code.length, 0);
        assertEq(address(subject).balance, 0);
        assertEq(address(payee).balance, 0);
        payee.setRejectETH(false);
        vm.prank(alice);
        address deployed = subject.createCollection{value: CREATE_FEE}("Works", "W", 100, PRICE, 5, creator, 0);
        assertEq(deployed, predicted);
        assertEq(subject.collectionCount(), 1);
        assertEq(address(payee).balance, CREATE_FEE);
    }

    function test_CreateFeeCallbackCannotReenterCreation() public {
        CallbackActor payee = new CallbackActor();
        LoomCollection logic = new LoomCollection(address(payee), reserve);
        LoomFactory subject = new LoomFactory(address(logic), address(payee), pauser);
        vm.deal(address(payee), CREATE_FEE);
        payee.configureAttack(
            address(subject),
            abi.encodeCall(LoomFactory.createCollection, ("Nested", "N", 100, PRICE, 5, creator, 0)),
            CREATE_FEE,
            true,
            false
        );
        vm.prank(alice);
        address deployed = subject.createCollection{value: CREATE_FEE}("Outer", "O", 100, PRICE, 5, creator, 0);
        assertEq(payee.attempts(), 1);
        assertFalse(payee.lastReentrySucceeded());
        assertEq(
            payee.lastReentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(subject.collectionCount(), 1);
        assertEq(subject.collections(0), deployed);
        assertEq(LoomCollection(deployed).owner(), alice);
        assertEq(address(payee).balance, 2 * CREATE_FEE);
    }

    function test_UnexpectedETHTransfersRevert() public {
        (bool collectionAccepted,) = address(collection).call{value: 1}("");
        (bool factoryAccepted,) = address(factory).call{value: 1}("");
        (bool logicAccepted,) = address(implementation).call{value: 1}("");
        assertFalse(collectionAccepted);
        assertFalse(factoryAccepted);
        assertFalse(logicAccepted);
    }

    function _assertMintRolledBack(LoomCollection subject, uint256 aliceBefore, uint256 platformBefore) private view {
        assertEq(subject.totalSupply(), 0);
        assertEq(subject.mintedPerWallet(alice), 0);
        assertEq(subject.balanceOf(alice), 0);
        assertEq(alice.balance, aliceBefore);
        assertEq(platform.balance, platformBefore);
        assertEq(creator.balance, 0);
        assertEq(reserve.balance, 0);
        assertEq(address(subject).balance, 0);
    }
}
