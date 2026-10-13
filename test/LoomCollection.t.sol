// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase, LoomCollection} from "./helpers/LoomTestBase.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LoomCollectionTest is LoomTestBase {
    event Minted(address indexed minter, uint256 indexed firstTokenId, uint256 quantity, bool reserved);
    event FeesDistributed(address indexed payer, uint256 creatorAmount, uint256 platformAmount, uint256 reserveAmount);
    event ProvenanceSet(bytes32 indexed provenanceHash);
    event Revealed(bytes32 indexed revealSeed);
    event BaseURISet(string baseURI);
    event UnrevealedURISet(string unrevealedURI);
    event MetadataFrozen();

    function test_InitializationAndInterfaces() public view {
        assertEq(collection.name(), "First");
        assertEq(collection.symbol(), "ONE");
        assertEq(collection.owner(), collectionOwner);
        assertEq(collection.creator(), creator);
        assertEq(collection.maxSupply(), SUPPLY);
        assertEq(collection.maxPerWallet(), WALLET_CAP);
        assertEq(collection.mintPrice(), PRICE);
        assertEq(collection.royaltyBps(), 750);
        assertEq(collection.PLATFORM_FEE(), FEE);
        assertEq(collection.PLATFORM(), platform);
        assertEq(collection.RESERVE(), reserve);
        assertEq(collection.totalSupply(), 0);
        assertEq(collection.reserveMinted(), 0);
        assertEq(collection.baseURI(), "");
        assertEq(collection.unrevealedURI(), "");
        assertFalse(collection.provenanceSet());
        assertFalse(collection.revealSeedSet());
        assertFalse(collection.metadataFrozen());
        assertFalse(collection.paused());
        assertTrue(collection.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(collection.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(collection.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(collection.supportsInterface(0x2a55205a)); // ERC-2981
        assertFalse(collection.supportsInterface(0xffffffff));
    }

    function test_ImplementationCannotInitializeOrMint() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize("Hijack", "BAD", SUPPLY, PRICE, WALLET_CAP, alice, 0, alice);
        vm.expectRevert(LoomCollection.MaxSupplyExceeded.selector);
        implementation.mint{value: PRICE + FEE}(1);
        assertEq(implementation.owner(), address(0));
        assertEq(implementation.totalSupply(), 0);
    }

    function test_CloneCannotReinitializeByOwnerOrAttacker() public {
        vm.startPrank(collectionOwner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        collection.initialize("Hijack", "BAD", SUPPLY, PRICE, WALLET_CAP, alice, 0, alice);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        collection.initialize("Hijack", "BAD", SUPPLY, PRICE, WALLET_CAP, alice, 0, alice);
        vm.stopPrank();
        assertEq(collection.owner(), collectionOwner);
    }

    function test_ConstructorRejectsZeroRecipients() public {
        vm.expectRevert(LoomCollection.InvalidAddress.selector);
        new LoomCollection(address(0), reserve);
        vm.expectRevert(LoomCollection.InvalidAddress.selector);
        new LoomCollection(platform, address(0));
    }

    function test_InvalidInitializationRevertsAndDoesNotConsumeInitializer() public {
        LoomCollection fresh = LoomCollection(Clones.clone(address(implementation)));
        vm.expectRevert(LoomCollection.InvalidAddress.selector);
        fresh.initialize("Art", "ART", 100, PRICE, 5, address(0), 750, collectionOwner);
        vm.expectRevert(LoomCollection.InvalidAddress.selector);
        fresh.initialize("Art", "ART", 100, PRICE, 5, creator, 750, address(0));
        vm.expectRevert(LoomCollection.InvalidSupply.selector);
        fresh.initialize("Art", "ART", 0, PRICE, 5, creator, 750, collectionOwner);
        vm.expectRevert(LoomCollection.InvalidWalletCap.selector);
        fresh.initialize("Art", "ART", 100, PRICE, 0, creator, 750, collectionOwner);
        vm.expectRevert(LoomCollection.InvalidWalletCap.selector);
        fresh.initialize("Art", "ART", 100, PRICE, 101, creator, 750, collectionOwner);
        vm.expectRevert(LoomCollection.InvalidRoyalty.selector);
        fresh.initialize("Art", "ART", 100, PRICE, 5, creator, 10_001, collectionOwner);
        vm.expectRevert(LoomCollection.InvalidMintPrice.selector);
        fresh.initialize("Art", "ART", 100, type(uint256).max, 5, creator, 750, collectionOwner);
        vm.expectRevert(LoomCollection.InvalidMintPrice.selector);
        fresh.initialize("Art", "ART", type(uint256).max, 0, 5, creator, 750, collectionOwner);
        fresh.initialize("Art", "ART", 100, PRICE, 5, creator, 750, collectionOwner);
        assertEq(fresh.owner(), collectionOwner);
    }

    function test_MintPaysExactSharesAndEmitsEvents() public {
        uint256 platformBefore = platform.balance;
        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(collection));
        emit Minted(alice, 1, 3, false);
        vm.expectEmit(true, false, false, true, address(collection));
        emit FeesDistributed(alice, 0.0306 ether, 0.0006 ether, 0.0003 ether);
        _mint(alice, 3);
        assertEq(creator.balance, 0.0306 ether);
        assertEq(platform.balance - platformBefore, 0.0006 ether);
        assertEq(reserve.balance, 0.0003 ether);
        assertEq(aliceBefore - alice.balance, 0.0315 ether);
        assertEq(address(collection).balance, 0);
        assertEq(collection.totalSupply(), 3);
        assertEq(collection.mintedPerWallet(alice), 3);
        assertEq(collection.balanceOf(alice), 3);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(collection.ownerOf(id), alice);
        }
    }

    function testFuzz_FeeConservation(uint96 priceInput, uint8 quantityInput) public {
        uint256 price = bound(uint256(priceInput), 0, 100 ether);
        uint256 quantity = bound(uint256(quantityInput), 1, 25);
        LoomCollection subject = _create(collectionOwner, "Fuzz", "FZ", 100, price, 100, creator, 500);
        uint256 expected = (price + FEE) * quantity;
        vm.deal(alice, expected);
        uint256 platformBefore = platform.balance;
        vm.prank(alice);
        subject.mint{value: expected}(quantity);
        assertEq(creator.balance, (price + 0.0002 ether) * quantity);
        assertEq(platform.balance - platformBefore, 0.0002 ether * quantity);
        assertEq(reserve.balance, 0.0001 ether * quantity);
        assertEq(creator.balance + platform.balance - platformBefore + reserve.balance, expected);
        assertEq(address(subject).balance, 0);
        assertEq(alice.balance, 0);
        assertEq(subject.totalSupply(), quantity);
    }

    function testFuzz_InexactPaymentAlwaysReverts(uint96 supplied, uint8 qty) public {
        uint256 quantity = bound(uint256(qty), 1, WALLET_CAP);
        uint256 expected = (PRICE + FEE) * quantity;
        vm.assume(uint256(supplied) != expected);
        vm.deal(alice, supplied);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, expected, uint256(supplied)));
        collection.mint{value: supplied}(quantity);
        assertEq(collection.totalSupply(), 0);
        assertEq(collection.mintedPerWallet(alice), 0);
        assertEq(alice.balance, supplied);
    }

    function test_MintRejectsUnderpaymentOverpaymentAndZero() public {
        uint256 cost = PRICE + FEE;
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, cost, cost - 1));
        collection.mint{value: cost - 1}(1);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, cost, cost + 1));
        collection.mint{value: cost + 1}(1);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, cost, 0));
        collection.mint(1);
        vm.expectRevert(LoomCollection.ZeroQuantity.selector);
        collection.mint(0);
        vm.stopPrank();
        assertEq(collection.totalSupply(), 0);
    }

    function test_FreeCreatorPriceStillPaysPlatformFee() public {
        LoomCollection free = _create(collectionOwner, "Free", "FREE", 100, 0, 5, creator, 0);
        vm.prank(alice);
        free.mint{value: FEE}(1);
        assertEq(creator.balance, 0.0002 ether);
        assertEq(reserve.balance, 0.0001 ether);
        assertEq(address(free).balance, 0);
    }

    function test_CoincidentRecipientsReceiveAllOfTheirShares() public {
        LoomCollection logic = new LoomCollection(creator, creator);
        LoomCollection same = LoomCollection(Clones.clone(address(logic)));
        same.initialize("Same", "SAME", 100, PRICE, 10, creator, 750, collectionOwner);
        vm.prank(alice);
        same.mint{value: 3 * (PRICE + FEE)}(3);
        assertEq(creator.balance, 3 * (PRICE + FEE));
        assertEq(address(same).balance, 0);
    }

    function test_WalletCapIsCumulativeAndNotResetByTransfer() public {
        _mint(alice, 4);
        _mint(alice, 6);
        vm.prank(alice);
        collection.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(LoomCollection.WalletCapExceeded.selector);
        collection.mint{value: PRICE + FEE}(1);
        _mint(bob, WALLET_CAP);
        assertEq(collection.mintedPerWallet(alice), WALLET_CAP);
        assertEq(collection.balanceOf(alice), WALLET_CAP - 1);
        assertEq(collection.mintedPerWallet(bob), WALLET_CAP);
        assertEq(collection.balanceOf(bob), WALLET_CAP + 1);
    }

    function test_HardSupplyCapIncludesReserveAndPublicMints() public {
        collection = _create(collectionOwner, "Small", "SML", 100, PRICE, 100, creator, 0);
        vm.prank(collectionOwner);
        collection.reserveMint(1);
        _mint(alice, 99);
        vm.prank(bob);
        vm.expectRevert(LoomCollection.MaxSupplyExceeded.selector);
        collection.mint{value: PRICE + FEE}(1);
        vm.prank(collectionOwner);
        vm.expectRevert(LoomCollection.MaxSupplyExceeded.selector);
        collection.reserveMint(1);
        assertEq(collection.totalSupply(), 100);
        assertEq(collection.ownerOf(100), alice);
    }

    function test_ReserveMintCapIsOnePercentAndSeparateFromWalletCap() public {
        uint256 before = collectionOwner.balance;
        vm.prank(collectionOwner);
        collection.reserveMint(4);
        vm.prank(collectionOwner);
        collection.reserveMint(6);
        assertEq(collection.reserveMinted(), SUPPLY / 100);
        assertEq(collection.balanceOf(collectionOwner), SUPPLY / 100);
        assertEq(collection.mintedPerWallet(collectionOwner), 0);
        assertEq(collectionOwner.balance, before);
        assertEq(creator.balance, 0);
        assertEq(reserve.balance, 0);
        vm.prank(collectionOwner);
        vm.expectRevert(LoomCollection.ReserveCapExceeded.selector);
        collection.reserveMint(1);
        _mint(collectionOwner, WALLET_CAP);
        assertEq(collection.balanceOf(collectionOwner), SUPPLY / 100 + WALLET_CAP);
    }

    function test_ReserveCapRoundsDownAndMayBeZero() public {
        LoomCollection small = _create(collectionOwner, "Tiny", "TNY", 99, 0, 1, creator, 0);
        vm.prank(collectionOwner);
        vm.expectRevert(LoomCollection.ReserveCapExceeded.selector);
        small.reserveMint(1);
        LoomCollection odd = _create(collectionOwner, "Odd", "ODD", 199, 0, 1, creator, 0);
        vm.startPrank(collectionOwner);
        odd.reserveMint(1);
        vm.expectRevert(LoomCollection.ReserveCapExceeded.selector);
        odd.reserveMint(1);
        vm.expectRevert(LoomCollection.ZeroQuantity.selector);
        odd.reserveMint(0);
        vm.stopPrank();
    }

    function test_PublicSaleCanConsumeUnmintedReserve() public {
        collection = _create(collectionOwner, "Sold out", "SOLD", 100, PRICE, 100, creator, 0);
        _mint(alice, 100);
        vm.prank(collectionOwner);
        vm.expectRevert(LoomCollection.MaxSupplyExceeded.selector);
        collection.reserveMint(1);
    }

    function test_MintAndReservePauseButTransfersContinue() public {
        _mint(alice, 1);
        vm.prank(collectionOwner);
        collection.pause();
        vm.startPrank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        collection.mint{value: PRICE + FEE}(1);
        collection.transferFrom(alice, bob, 1);
        vm.stopPrank();
        vm.prank(collectionOwner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        collection.reserveMint(1);
        vm.prank(collectionOwner);
        collection.unpause();
        _mint(alice, 1);
        assertEq(collection.ownerOf(1), bob);
    }

    function test_MetadataLifecycleAndEvents() public {
        vm.startPrank(collectionOwner);
        vm.expectEmit(true, false, false, true, address(collection));
        emit ProvenanceSet(keccak256("art manifest"));
        collection.setProvenanceHash(keccak256("art manifest"));
        vm.expectEmit(false, false, false, true, address(collection));
        emit UnrevealedURISet("ipfs://preview.json");
        collection.setUnrevealedURI("ipfs://preview.json");
        vm.stopPrank();
        _mint(alice, 2);
        assertEq(collection.tokenURI(1), "ipfs://preview.json");
        vm.startPrank(collectionOwner);
        vm.expectEmit(true, false, false, true, address(collection));
        emit Revealed(keccak256("off-chain seed"));
        collection.setRevealSeed(keccak256("off-chain seed"));
        vm.expectEmit(false, false, false, true, address(collection));
        emit BaseURISet("ipfs://art/");
        collection.setBaseURI("ipfs://art/");
        vm.stopPrank();
        assertEq(collection.tokenURI(1), "ipfs://art/1.json");
        assertEq(collection.tokenURI(2), "ipfs://art/2.json");
        vm.prank(collectionOwner);
        vm.expectEmit(false, false, false, true, address(collection));
        emit MetadataFrozen();
        collection.freezeMetadata();
        assertTrue(collection.metadataFrozen());
        assertEq(collection.provenanceHash(), keccak256("art manifest"));
        assertEq(collection.revealSeed(), keccak256("off-chain seed"));
    }

    function test_URIUsesBasePresenceAndRequiresExistingToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        collection.tokenURI(1);
        _mint(alice, 1);
        assertEq(collection.tokenURI(1), "");
        vm.startPrank(collectionOwner);
        collection.setBaseURI("ipfs://a/");
        assertEq(collection.tokenURI(1), "ipfs://a/1.json");
        collection.setUnrevealedURI("ipfs://unrevealed");
        collection.setBaseURI("");
        assertEq(collection.tokenURI(1), "ipfs://unrevealed");
        collection.setRevealSeed(bytes32(uint256(1)));
        assertEq(collection.tokenURI(1), "ipfs://unrevealed");
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        collection.tokenURI(0);
    }

    function test_ProvenanceOnlyOnceEvenForZeroHash() public {
        vm.startPrank(collectionOwner);
        collection.setProvenanceHash(bytes32(0));
        vm.expectRevert(LoomCollection.ProvenanceAlreadySet.selector);
        collection.setProvenanceHash(bytes32(uint256(1)));
        vm.stopPrank();
        assertTrue(collection.provenanceSet());
    }

    function test_ProvenanceCannotBeSetAfterPublicMint() public {
        _mint(alice, 1);
        vm.prank(collectionOwner);
        vm.expectRevert(LoomCollection.MintingAlreadyStarted.selector);
        collection.setProvenanceHash(keccak256("late"));
    }

    function test_ProvenanceCannotBeSetAfterReserveMint() public {
        vm.startPrank(collectionOwner);
        collection.reserveMint(1);
        vm.expectRevert(LoomCollection.MintingAlreadyStarted.selector);
        collection.setProvenanceHash(keccak256("late"));
        vm.stopPrank();
    }

    function test_RevealOnlyOnceEvenForZeroSeed() public {
        vm.startPrank(collectionOwner);
        collection.setRevealSeed(bytes32(0));
        vm.expectRevert(LoomCollection.RevealSeedAlreadySet.selector);
        collection.setRevealSeed(bytes32(uint256(1)));
        vm.stopPrank();
        assertTrue(collection.revealSeedSet());
    }

    function test_FreezePermanentlyLocksEveryMetadataSetter() public {
        vm.startPrank(collectionOwner);
        collection.freezeMetadata();
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.setBaseURI("new");
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.setUnrevealedURI("new");
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.setRevealSeed(bytes32(uint256(1)));
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.setProvenanceHash(bytes32(uint256(1)));
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.freezeMetadata();
        vm.stopPrank();
        _mint(alice, 1);
        assertEq(collection.totalSupply(), 1);
    }

    function test_AllAdministrativeCallsRequireCollectionOwner() public {
        bytes memory denied = abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(denied);
        collection.reserveMint(1);
        vm.expectRevert(denied);
        collection.pause();
        vm.expectRevert(denied);
        collection.unpause();
        vm.expectRevert(denied);
        collection.setBaseURI("bad");
        vm.expectRevert(denied);
        collection.setUnrevealedURI("bad");
        vm.expectRevert(denied);
        collection.setProvenanceHash(bytes32(0));
        vm.expectRevert(denied);
        collection.setRevealSeed(bytes32(0));
        vm.expectRevert(denied);
        collection.freezeMetadata();
        vm.expectRevert(denied);
        collection.transferOwnership(alice);
        vm.expectRevert(denied);
        collection.renounceOwnership();
        vm.stopPrank();
    }

    function test_OwnershipHandoverDoesNotResetReserveOrChangeCreator() public {
        vm.startPrank(collectionOwner);
        collection.reserveMint(10);
        collection.transferOwnership(alice);
        vm.stopPrank();
        assertEq(collection.owner(), collectionOwner);
        assertEq(collection.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bob));
        collection.acceptOwnership();
        vm.prank(alice);
        collection.acceptOwnership();
        assertEq(collection.owner(), alice);
        assertEq(collection.pendingOwner(), address(0));
        vm.prank(alice);
        vm.expectRevert(LoomCollection.ReserveCapExceeded.selector);
        collection.reserveMint(1);
        vm.prank(collectionOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, collectionOwner));
        collection.pause();
        (address receiver, uint256 amount) = collection.royaltyInfo(1, 1 ether);
        assertEq(receiver, creator);
        assertEq(amount, 0.075 ether);
    }

    function test_ApprovalsAndTransfersHaveStandardAuthorization() public {
        _mint(alice, 2);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, 1));
        collection.transferFrom(alice, bob, 1);
        vm.prank(alice);
        collection.approve(bob, 1);
        assertEq(collection.getApproved(1), bob);
        vm.prank(bob);
        collection.transferFrom(alice, bob, 1);
        assertEq(collection.getApproved(1), address(0));
        vm.prank(alice);
        collection.setApprovalForAll(bob, true);
        vm.prank(bob);
        collection.safeTransferFrom(alice, bob, 2);
        assertEq(collection.balanceOf(bob), 2);
        assertEq(collection.totalSupply(), 2);
    }

    function testFuzz_RoyaltyInfo(uint128 salePrice, uint16 bpsInput) public {
        uint96 bps = uint96(bound(uint256(bpsInput), 0, 10_000));
        LoomCollection subject = _create(collectionOwner, "Royalty", "ROY", 100, 0, 1, creator, bps);
        (address receiver, uint256 amount) = subject.royaltyInfo(123, salePrice);
        assertEq(receiver, creator);
        assertEq(amount, uint256(salePrice) * bps / 10_000);
    }
}
