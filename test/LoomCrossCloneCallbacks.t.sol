// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase, LoomCollection, LoomFactory} from "./helpers/LoomTestBase.sol";
import {CallbackActor} from "./helpers/CallbackActor.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract LoomCrossCloneCallbacksTest is LoomTestBase {
    function test_ReceiverCanMintAnotherCloneWithoutSharingTheReentrancyGuard() public {
        LoomCollection second = _create(bob, "Nested", "N", 100, 1, 2, bob, 0);
        CallbackActor receiver = new CallbackActor();
        vm.deal(address(receiver), 2 * (1 + FEE));
        receiver.configureAttack(address(second), abi.encodeCall(LoomCollection.mint, (1)), 1 + FEE, false, true);
        uint256 platformBefore = platform.balance;
        uint256 bobBefore = bob.balance;
        receiver.execute{value: 2 * (PRICE + FEE)}(address(collection), abi.encodeCall(LoomCollection.mint, (2)));
        assertTrue(receiver.lastReentrySucceeded());
        assertEq(receiver.attempts(), 2);
        assertEq(receiver.nftCallbacks(), 4);
        assertEq(collection.totalSupply(), 2);
        assertEq(second.totalSupply(), 2);
        assertEq(collection.mintedPerWallet(address(receiver)), 2);
        assertEq(second.mintedPerWallet(address(receiver)), 2);
        assertEq(collection.ownerOf(2), address(receiver));
        assertEq(second.ownerOf(2), address(receiver));
        assertEq(creator.balance, 2 * (PRICE + 0.0002 ether));
        assertEq(bob.balance - bobBefore, 2 * (1 + 0.0002 ether));
        assertEq(platform.balance - platformBefore, 4 * 0.0002 ether);
        assertEq(reserve.balance, 4 * 0.0001 ether);
        assertEq(address(receiver).balance, 0);
        assertEq(address(collection).balance, 0);
        assertEq(address(second).balance, 0);
    }

    function test_LateFailureRollsBackNestedCloneMintsAndAllEarlierPayments() public {
        CallbackActor rejectingCreator = new CallbackActor();
        LoomCollection outer = _create(collectionOwner, "Outer", "O", 100, PRICE, 10, address(rejectingCreator), 0);
        LoomCollection nested = _create(bob, "Nested", "N", 100, 1, 10, creator, 0);
        CallbackActor receiver = new CallbackActor();
        vm.deal(address(receiver), 1 + FEE);
        receiver.configureAttack(address(nested), abi.encodeCall(LoomCollection.mint, (1)), 1 + FEE, false, true);
        rejectingCreator.setRejectETH(true);
        uint256 platformBefore = platform.balance;
        uint256 payerBefore = address(this).balance;
        vm.expectRevert(
            abi.encodeWithSelector(
                LoomCollection.PaymentFailed.selector, address(rejectingCreator), PRICE + 0.0002 ether
            )
        );
        receiver.execute{value: PRICE + FEE}(address(outer), abi.encodeCall(LoomCollection.mint, (1)));
        assertEq(outer.totalSupply(), 0);
        assertEq(nested.totalSupply(), 0);
        assertEq(outer.mintedPerWallet(address(receiver)), 0);
        assertEq(nested.mintedPerWallet(address(receiver)), 0);
        assertEq(outer.balanceOf(address(receiver)), 0);
        assertEq(nested.balanceOf(address(receiver)), 0);
        assertEq(address(receiver).balance, 1 + FEE);
        assertEq(address(this).balance, payerBefore);
        assertEq(creator.balance, 0);
        assertEq(platform.balance, platformBefore);
        assertEq(reserve.balance, 0);
        assertEq(receiver.nftCallbacks(), 0);
        assertEq(receiver.attempts(), 0);
        // Retrying the same operation succeeds after the real failure condition is removed.
        rejectingCreator.setRejectETH(false);
        receiver.execute{value: PRICE + FEE}(address(outer), abi.encodeCall(LoomCollection.mint, (1)));
        assertTrue(receiver.lastReentrySucceeded());
        assertEq(outer.ownerOf(1), address(receiver));
        assertEq(nested.ownerOf(1), address(receiver));
        assertEq(creator.balance, 1 + 0.0002 ether);
        assertEq(address(rejectingCreator).balance, PRICE + 0.0002 ether);
        assertEq(platform.balance - platformBefore, 2 * 0.0002 ether);
        assertEq(reserve.balance, 2 * 0.0001 ether);
    }

    function test_CreateFeeCallbackSeesAlreadyInitializedClone() public {
        CallbackActor feeRecipient = new CallbackActor();
        LoomCollection logic = new LoomCollection(address(feeRecipient), reserve);
        LoomFactory subject = new LoomFactory(address(logic), address(feeRecipient), pauser);
        for (uint256 i; i < 2; ++i) {
            address predicted = vm.computeCreateAddress(address(subject), vm.getNonce(address(subject)));
            feeRecipient.configureAttack(
                predicted,
                abi.encodeCall(
                    LoomCollection.initialize,
                    ("Stolen", "BAD", 1, 0, 1, address(feeRecipient), 0, address(feeRecipient))
                ),
                0,
                true,
                false
            );
            vm.prank(i == 0 ? alice : bob);
            address deployed =
                subject.createCollection{value: CREATE_FEE}("Original", "OK", 100, PRICE, 10, creator, 500);
            assertEq(deployed, predicted);
            assertFalse(feeRecipient.lastReentrySucceeded());
            assertEq(
                feeRecipient.lastReentryResult(), abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
            );
            assertEq(LoomCollection(deployed).owner(), i == 0 ? alice : bob);
            assertEq(LoomCollection(deployed).creator(), creator);
            assertEq(LoomCollection(deployed).name(), "Original");
            assertEq(subject.collections(i), deployed);
        }
        assertEq(feeRecipient.attempts(), 2);
        assertEq(address(feeRecipient).balance, 2 * CREATE_FEE);
        assertEq(subject.collectionCount(), 2);
    }

    function test_ReleaseRecipientTopologyConservesBothCreationAndMintFees() public {
        // The approved release binds platform, reserve and pauser to the same launch owner.
        address launchOwner = makeAddr("release launch owner");
        LoomCollection logic = new LoomCollection(launchOwner, launchOwner);
        LoomFactory subject = new LoomFactory(address(logic), launchOwner, launchOwner);
        LoomCollection[2] memory clones;
        for (uint256 i; i < 2; ++i) {
            vm.prank(i == 0 ? alice : bob);
            clones[i] = LoomCollection(
                subject.createCollection{value: CREATE_FEE}(
                    "Release", "R", 100, i, 2, i == 0 ? creator : launchOwner, 500
                )
            );
            vm.prank(alice);
            clones[i].mint{value: 2 * (i + FEE)}(2);
            assertEq(clones[i].PLATFORM(), launchOwner);
            assertEq(clones[i].RESERVE(), launchOwner);
            assertEq(clones[i].owner(), i == 0 ? alice : bob);
            assertEq(address(clones[i]).balance, 0);
        }
        assertEq(creator.balance, 2 * 0.0002 ether);
        assertEq(launchOwner.balance, 2 * CREATE_FEE + 2 * 0.0003 ether + 2 * (1 + FEE));
        assertEq(subject.pauser(), launchOwner);
        assertEq(address(subject).balance, 0);
    }
}
