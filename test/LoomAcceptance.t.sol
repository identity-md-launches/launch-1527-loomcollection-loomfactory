// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase, LoomCollection} from "./helpers/LoomTestBase.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Independent acceptance properties supplement the existing example-based tests.
/// forge-config: default.fuzz.runs = 1000
contract LoomAcceptanceTest is LoomTestBase {
    event Minted(address indexed minter, uint256 indexed firstTokenId, uint256 quantity, bool reserved);
    event FeesDistributed(address indexed payer, uint256 creatorAmount, uint256 platformAmount, uint256 reserveAmount);

    function testFuzz_BatchingAndSplittingHaveIdenticalFees(uint96 priceSeed, uint8 quantitySeed, uint8 splitSeed)
        public
    {
        uint256 price = bound(priceSeed, 0, 100 ether);
        uint256 quantity = bound(quantitySeed, 2, 40);
        uint256 split = bound(splitSeed, 1, quantity - 1);
        LoomCollection batched = _create(collectionOwner, "Batch", "B", quantity, price, quantity, creator, 0);
        LoomCollection splitUp = _create(bob, "Split", "S", quantity, price, quantity, creator, 10_000);
        vm.deal(alice, 2 * (price + FEE) * quantity);

        _mintAndCheckShares(batched, alice, price, quantity);
        _mintAndCheckShares(splitUp, alice, price, split);
        _mintAndCheckShares(splitUp, alice, price, quantity - split);

        // Odd wei prices and arbitrary partitions cannot change the fee or leave rounding dust.
        assertEq(creator.balance, 2 * quantity * price + 2 * quantity * FEE * 40 / 100);
        assertEq(reserve.balance, 2 * quantity * FEE * 20 / 100);
        assertEq(alice.balance, 0);
        assertEq(batched.mintedPerWallet(alice), quantity);
        assertEq(splitUp.mintedPerWallet(alice), quantity);
        assertEq(batched.totalSupply(), quantity);
        assertEq(splitUp.totalSupply(), quantity);
        for (uint256 id = 1; id <= quantity; ++id) {
            assertEq(batched.ownerOf(id), alice);
            assertEq(splitUp.ownerOf(id), alice);
        }
        vm.prank(alice);
        vm.expectRevert(LoomCollection.MaxSupplyExceeded.selector);
        batched.mint(1);
        vm.prank(alice);
        vm.expectRevert(LoomCollection.MaxSupplyExceeded.selector);
        splitUp.mint(1);
    }

    function testFuzz_ReserveRoundingAndOwnershipAreIndependent(uint16 supplySeed, uint8 remainder) public {
        uint256 supplyA = bound(supplySeed, 1, 599);
        uint256 supplyB = (supplyA / 100 + 1) * 100 + uint256(remainder) % 100;
        LoomCollection[2] memory clones;
        clones[0] = _create(collectionOwner, "Reserve A", "RA", supplyA, 1, 1, creator, 0);
        clones[1] = _create(bob, "Reserve B", "RB", supplyB, 3, 1, creator, 0);
        address[2] memory owners = [collectionOwner, bob];
        uint256 creatorBefore = creator.balance;
        uint256 platformBefore = platform.balance;
        uint256 reserveBefore = reserve.balance;

        for (uint256 i; i < 2; ++i) {
            uint256 allowance = clones[i].maxSupply() / 100;
            uint256 ownerBefore = owners[i].balance;
            if (allowance > 0) {
                vm.expectEmit(true, true, false, true, address(clones[i]));
                emit Minted(owners[i], 1, allowance, true);
                vm.prank(owners[i]);
                clones[i].reserveMint(allowance);
            }
            vm.prank(owners[i]);
            clones[i].transferOwnership(alice);
            vm.prank(alice);
            clones[i].acceptOwnership();
            vm.prank(alice);
            vm.expectRevert(LoomCollection.ReserveCapExceeded.selector);
            clones[i].reserveMint(1);
            assertEq(clones[i].reserveMinted(), allowance);
            assertEq(clones[i].totalSupply(), allowance);
            assertEq(clones[i].balanceOf(owners[i]), allowance);
            assertEq(clones[i].mintedPerWallet(owners[i]), 0);
            assertEq(owners[i].balance, ownerBefore);
        }
        assertEq(creator.balance, creatorBefore);
        assertEq(platform.balance, platformBefore);
        assertEq(reserve.balance, reserveBefore);
    }

    function testFuzz_ReinitializationCannotChangeEitherLiveClone(address caller, bytes32 seed) public {
        LoomCollection second = _create(bob, "Second", "TWO", 299, 3, 20, bob, 9_999);
        LoomCollection[2] memory clones = [collection, second];
        address[2] memory owners = [collectionOwner, bob];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(owners[i]);
            clones[i].setProvenanceHash(seed);
            clones[i].setRevealSeed(~seed);
            clones[i].setBaseURI(i == 0 ? "ipfs://first/" : "ipfs://second/");
            clones[i].reserveMint(1);
            clones[i].freezeMetadata();
            clones[i].pause();
            clones[i].transferOwnership(alice);
            vm.stopPrank();
        }
        bytes32 firstBefore = _stateHash(collection);
        bytes32 secondBefore = _stateHash(second);
        bytes memory payload =
            abi.encodeCall(LoomCollection.initialize, ("Overwrite", "BAD", 1, 0, 1, alice, 10_000, alice));
        for (uint256 i; i < 2; ++i) {
            _rejectInitialization(address(clones[i]), caller, payload);
            _rejectInitialization(address(clones[i]), owners[i], payload);
            _rejectInitialization(address(clones[i]), address(factory), payload);
        }
        _rejectInitialization(address(implementation), caller, payload);
        assertEq(_stateHash(collection), firstBefore);
        assertEq(_stateHash(second), secondBefore);
        assertEq(collection.ownerOf(1), collectionOwner);
        assertEq(second.ownerOf(1), bob);
        assertEq(implementation.owner(), address(0));
        assertEq(implementation.totalSupply(), 0);
    }

    function testFuzz_InvalidFactoryInitializationIsAtomic(uint8 kindSeed, uint256 badSeed) public {
        uint256 kind = uint256(kindSeed) % 7;
        uint256 supply = 100;
        uint256 cap = 10;
        uint256 price = 1;
        address artist = creator;
        uint96 bps = 500;
        bytes4 errorSelector;
        if (kind == 0) {
            supply = 0;
            errorSelector = LoomCollection.InvalidSupply.selector;
        } else if (kind == 1) {
            cap = 0;
            errorSelector = LoomCollection.InvalidWalletCap.selector;
        } else if (kind == 2) {
            cap = bound(badSeed, 101, type(uint256).max);
            errorSelector = LoomCollection.InvalidWalletCap.selector;
        } else if (kind == 3) {
            artist = address(0);
            errorSelector = LoomCollection.InvalidAddress.selector;
        } else if (kind == 4) {
            bps = uint96(bound(badSeed, 10_001, type(uint96).max));
            errorSelector = LoomCollection.InvalidRoyalty.selector;
        } else if (kind == 5) {
            price = bound(badSeed, type(uint256).max - FEE + 1, type(uint256).max);
            errorSelector = LoomCollection.InvalidMintPrice.selector;
        } else {
            price = type(uint256).max / supply - FEE + 1;
            errorSelector = LoomCollection.InvalidMintPrice.selector;
        }
        uint64 nonceBefore = vm.getNonce(address(factory));
        address predicted = vm.computeCreateAddress(address(factory), nonceBefore);
        uint256 payerBefore = alice.balance;
        uint256 platformBefore = platform.balance;
        vm.prank(alice);
        vm.expectRevert(errorSelector);
        factory.createCollection{value: CREATE_FEE}("Invalid", "BAD", supply, price, cap, artist, bps);
        assertEq(factory.collectionCount(), 1);
        assertEq(vm.getNonce(address(factory)), nonceBefore);
        assertEq(predicted.code.length, 0);
        assertFalse(factory.isCollection(predicted));
        assertEq(alice.balance, payerBefore);
        assertEq(platform.balance, platformBefore);
        assertEq(address(factory).balance, 0);
        LoomCollection valid = _create(alice, "Valid", "V", 100, 1, 10, creator, 500);
        assertEq(address(valid), predicted);
        assertEq(factory.collections(0), address(collection));
        assertEq(factory.collections(1), predicted);
        assertEq(valid.owner(), alice);
    }

    function testFuzz_InitializerPriceBoundary(uint16 supplySeed) public {
        uint256 supply = bound(supplySeed, 1, 1_000);
        uint256 highestPrice = type(uint256).max / supply - FEE;
        LoomCollection lastValid = _create(collectionOwner, "Limit", "L", supply, highestPrice, 1, creator, 0);
        assertEq(lastValid.mintPrice(), highestPrice);
        assertLe((highestPrice + FEE) * supply, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(LoomCollection.InvalidMintPrice.selector);
        factory.createCollection{value: CREATE_FEE}("Overflow", "O", supply, highestPrice + 1, 1, creator, 0);
        assertEq(factory.collectionCount(), 2);
    }

    function test_InitializerSupplyBoundaryAtZeroPrice() public {
        uint256 highestSupply = type(uint256).max / FEE;
        LoomCollection lastValid = _create(collectionOwner, "Limit", "L", highestSupply, 0, 1, creator, 0);
        assertEq(lastValid.maxSupply(), highestSupply);
        vm.prank(bob);
        vm.expectRevert(LoomCollection.InvalidMintPrice.selector);
        factory.createCollection{value: CREATE_FEE}("Overflow", "O", highestSupply + 1, 0, 1, creator, 0);
    }

    function testFuzz_RoyaltyRoundingAcrossClones(uint256 salePriceSeed, uint16 bpsSeed) public {
        uint96 bps = uint96(bound(bpsSeed, 0, 10_000));
        uint256 largestRate = bps >= 5_000 ? bps : 10_000 - bps;
        // Larger quotes expose the separately reported inherited multiplication overflow.
        uint256 salePrice = bound(salePriceSeed, 0, type(uint256).max / largestRate);
        LoomCollection a = _create(collectionOwner, "A", "A", 100, 0, 1, alice, bps);
        LoomCollection b = _create(bob, "B", "B", 100, 0, 1, bob, 10_000 - bps);
        LoomCollection[2] memory clones = [a, b];
        address[2] memory artists = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            uint256 rate = i == 0 ? bps : 10_000 - bps;
            (address receiver, uint256 amount) = clones[i].royaltyInfo(type(uint256).max, salePrice);
            assertEq(receiver, artists[i]);
            // Quotient/remainder oracle avoids mirroring the implementation's multiplication order.
            uint256 expected = uint256(salePrice) / 10_000 * rate + (uint256(salePrice) % 10_000) * rate / 10_000;
            assertEq(amount, expected);
            assertLe(amount, salePrice);
            assertLe(amount * 10_000, uint256(salePrice) * rate);
            assertLt(uint256(salePrice) * rate - amount * 10_000, 10_000);
        }
    }

    function test_ZeroAndOneBpsRoyaltyAtMaximumSalePrice() public {
        LoomCollection zero = _create(collectionOwner, "Zero", "Z", 100, 0, 1, alice, 0);
        LoomCollection one = _create(bob, "One", "O", 100, 0, 1, bob, 1);
        (address zeroReceiver, uint256 zeroAmount) = zero.royaltyInfo(1, type(uint256).max);
        (address oneReceiver, uint256 oneAmount) = one.royaltyInfo(1, type(uint256).max);
        assertEq(zeroReceiver, alice);
        assertEq(zeroAmount, 0);
        assertEq(oneReceiver, bob);
        assertEq(oneAmount, type(uint256).max / 10_000);
    }

    function test_FreezePersistsAcrossOwnershipHandoverOnBothClones() public {
        LoomCollection second = _create(bob, "Second", "TWO", 100, 0, 2, creator, 0);
        LoomCollection[2] memory clones = [collection, second];
        address[2] memory owners = [collectionOwner, bob];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(owners[i]);
            clones[i].setUnrevealedURI("ipfs://placeholder.json");
            if (i == 0) clones[i].setBaseURI("ipfs://final/");
            clones[i].reserveMint(1);
            clones[i].freezeMetadata();
            clones[i].transferOwnership(alice);
            vm.stopPrank();
            vm.startPrank(alice);
            clones[i].acceptOwnership();
            vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
            clones[i].setBaseURI("changed");
            vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
            clones[i].setUnrevealedURI("changed");
            vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
            clones[i].setRevealSeed(keccak256("changed"));
            vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
            clones[i].setProvenanceHash(keccak256("changed"));
            vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
            clones[i].freezeMetadata();
            vm.stopPrank();
            assertEq(clones[i].tokenURI(1), i == 0 ? "ipfs://final/1.json" : "ipfs://placeholder.json");
            assertTrue(clones[i].metadataFrozen());
        }
    }

    function test_ApprovalsDoNotAuthorizeTheOtherClone() public {
        LoomCollection second = _create(bob, "Second", "TWO", 100, PRICE, 10, creator, 0);
        _mint(alice, 2);
        vm.prank(alice);
        second.mint{value: 2 * (PRICE + FEE)}(2);
        vm.startPrank(alice);
        collection.approve(bob, 1);
        collection.setApprovalForAll(bob, true);
        vm.stopPrank();
        vm.prank(bob);
        collection.transferFrom(alice, bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, 1));
        second.transferFrom(alice, bob, 1);
        assertEq(second.ownerOf(1), alice);
        assertEq(second.getApproved(1), address(0));
        assertFalse(second.isApprovedForAll(alice, bob));
        vm.prank(alice);
        collection.setApprovalForAll(bob, false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, 2));
        collection.transferFrom(alice, bob, 2);
        // Collection ownership does not authorize transfers of holders' NFTs, either.
        vm.prank(collectionOwner);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, collectionOwner, 2));
        collection.transferFrom(alice, collectionOwner, 2);
    }

    function test_TokenURIDecimalBoundariesAndNoImplicitSlash() public {
        LoomCollection second = _create(bob, "Second", "TWO", 110, 0, 110, creator, 0);
        vm.prank(alice);
        second.mint{value: 110 * FEE}(110);
        vm.prank(bob);
        second.setBaseURI("prefix");
        assertEq(second.tokenURI(9), "prefix9.json");
        assertEq(second.tokenURI(10), "prefix10.json");
        assertEq(second.tokenURI(99), "prefix99.json");
        assertEq(second.tokenURI(100), "prefix100.json");
        assertEq(collection.baseURI(), "");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 111));
        second.tokenURI(111);
    }

    function _mintAndCheckShares(LoomCollection subject, address minter, uint256 price, uint256 quantity) private {
        uint256 creatorBefore = creator.balance;
        uint256 platformBefore = platform.balance;
        uint256 reserveBefore = reserve.balance;
        uint256 payment = (price + FEE) * quantity;
        vm.expectEmit(true, true, false, true, address(subject));
        emit Minted(minter, subject.totalSupply() + 1, quantity, false);
        vm.expectEmit(true, false, false, true, address(subject));
        emit FeesDistributed(
            minter, price * quantity + FEE * quantity * 40 / 100, FEE * quantity * 40 / 100, FEE * quantity * 20 / 100
        );
        vm.prank(minter);
        subject.mint{value: payment}(quantity);
        uint256 creatorDelta = creator.balance - creatorBefore;
        uint256 platformDelta = platform.balance - platformBefore;
        uint256 reserveDelta = reserve.balance - reserveBefore;
        assertEq(creatorDelta, price * quantity + FEE * quantity * 40 / 100);
        assertEq(platformDelta, FEE * quantity * 40 / 100);
        assertEq(reserveDelta, FEE * quantity * 20 / 100);
        assertEq(creatorDelta + platformDelta + reserveDelta, payment);
        assertEq(address(subject).balance, 0);
    }

    function _rejectInitialization(address target, address caller, bytes memory payload) private {
        vm.prank(caller);
        (bool success, bytes memory result) = target.call(payload);
        assertFalse(success, "initializer replay succeeded");
        assertEq(result, abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
    }

    function _stateHash(LoomCollection subject) private view returns (bytes32) {
        bytes32 economics = keccak256(
            abi.encode(
                subject.name(),
                subject.symbol(),
                subject.maxSupply(),
                subject.mintPrice(),
                subject.maxPerWallet(),
                subject.creator(),
                subject.royaltyBps(),
                subject.PLATFORM(),
                subject.RESERVE()
            )
        );
        bytes32 metadata = keccak256(
            abi.encode(
                subject.baseURI(),
                subject.unrevealedURI(),
                subject.provenanceHash(),
                subject.revealSeed(),
                subject.provenanceSet(),
                subject.revealSeedSet(),
                subject.metadataFrozen()
            )
        );
        return keccak256(
            abi.encode(
                economics,
                metadata,
                subject.owner(),
                subject.pendingOwner(),
                subject.paused(),
                subject.totalSupply(),
                subject.reserveMinted()
            )
        );
    }
}
