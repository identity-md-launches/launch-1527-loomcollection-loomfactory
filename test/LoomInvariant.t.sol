// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoomTestBase, LoomCollection} from "./helpers/LoomTestBase.sol";

/// @dev Maintains an independent model of ownership, supply and ETH paid across arbitrary action sequences.
contract LoomHandler is Test {
    LoomCollection public immutable collection;
    address[5] public actors;
    address public expectedOwner;
    uint256 public publicMinted;
    uint256 public reserved;
    uint256 public paid;
    uint256 public successfulTransfers;
    uint256 public rejectedMints;
    mapping(address actor => uint256 count) public expectedPublicMints;
    mapping(address actor => uint256 count) public expectedBalance;
    mapping(uint256 tokenId => address holder) public expectedTokenOwner;

    constructor(LoomCollection collection_, address initialOwner) {
        collection = collection_;
        expectedOwner = initialOwner;
        actors[0] = initialOwner;
        for (uint256 i = 1; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("invariant minter ", vm.toString(i)));
        }
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 100 ether);
        }
    }

    function mint(uint256 actorSeed, uint256 quantitySeed, uint8 paymentKind) external {
        address actor = actors[actorSeed % actors.length];
        uint256 quantity = bound(quantitySeed, 0, 30);
        uint256 cost = quantity * (collection.mintPrice() + collection.PLATFORM_FEE());
        uint256 sent = cost;
        if (paymentKind % 3 == 1) sent = cost == 0 ? 1 : cost - 1;
        if (paymentKind % 3 == 2) sent = cost + 1;
        bool shouldSucceed = quantity > 0 && sent == cost && !collection.paused()
            && publicMinted + reserved + quantity <= collection.maxSupply()
            && expectedPublicMints[actor] + quantity <= collection.maxPerWallet();
        uint256 first = publicMinted + reserved + 1;
        uint256 balanceBefore = actor.balance;
        vm.prank(actor);
        try collection.mint{value: sent}(quantity) {
            assertTrue(shouldSucceed, "invalid public mint succeeded");
            publicMinted += quantity;
            expectedPublicMints[actor] += quantity;
            expectedBalance[actor] += quantity;
            paid += sent;
            for (uint256 i; i < quantity; ++i) {
                expectedTokenOwner[first + i] = actor;
            }
            assertEq(actor.balance, balanceBefore - sent);
        } catch {
            assertFalse(shouldSucceed, "valid public mint reverted");
            assertEq(actor.balance, balanceBefore, "failed mint retained payment");
            ++rejectedMints;
        }
    }

    function reserveMint(uint8 quantitySeed) external {
        uint256 quantity = uint256(quantitySeed) % 4;
        bool shouldSucceed = quantity > 0 && !collection.paused()
            && publicMinted + reserved + quantity <= collection.maxSupply()
            && reserved + quantity <= collection.maxSupply() / 100;
        uint256 first = publicMinted + reserved + 1;
        vm.prank(expectedOwner);
        try collection.reserveMint(quantity) {
            assertTrue(shouldSucceed, "invalid reserve mint succeeded");
            reserved += quantity;
            expectedBalance[expectedOwner] += quantity;
            for (uint256 i; i < quantity; ++i) {
                expectedTokenOwner[first + i] = expectedOwner;
            }
        } catch {
            assertFalse(shouldSucceed, "valid reserve mint reverted");
        }
    }

    function transfer(uint256 tokenSeed, uint256 recipientSeed) external {
        if (publicMinted + reserved == 0) return;
        uint256 id = tokenSeed % (publicMinted + reserved) + 1;
        address from = expectedTokenOwner[id];
        address to = actors[recipientSeed % actors.length];
        vm.prank(from);
        collection.transferFrom(from, to, id);
        --expectedBalance[from];
        ++expectedBalance[to];
        expectedTokenOwner[id] = to;
        ++successfulTransfers;
    }

    function setPaused(bool pauseIt) external {
        if (pauseIt == collection.paused()) return;
        vm.prank(expectedOwner);
        if (pauseIt) collection.pause();
        else collection.unpause();
    }

    function handover(uint256 actorSeed) external {
        address nextOwner = actors[actorSeed % actors.length];
        vm.prank(expectedOwner);
        collection.transferOwnership(nextOwner);
        assertEq(collection.owner(), expectedOwner);
        vm.prank(nextOwner);
        collection.acceptOwnership();
        expectedOwner = nextOwner;
    }
}

contract LoomInvariantTest is LoomTestBase {
    LoomHandler internal handler;
    LoomCollection internal untouched;
    uint256 internal platformBaseline;

    function setUp() public override {
        super.setUp();
        collection = _create(collectionOwner, "State machine", "STM", 100, PRICE, 25, creator, 750);
        untouched = _create(bob, "Isolated", "ISO", 100, 0, 1, bob, 0);
        handler = new LoomHandler(collection, collectionOwner);
        platformBaseline = platform.balance;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = LoomHandler.mint.selector;
        selectors[1] = LoomHandler.reserveMint.selector;
        selectors[2] = LoomHandler.transfer.selector;
        selectors[3] = LoomHandler.setPaused.selector;
        selectors[4] = LoomHandler.handover.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SupplyCapsWalletCountsAndOwnership() public view {
        uint256 publicCount = handler.publicMinted();
        uint256 reserveCount = handler.reserved();
        uint256 count = publicCount + reserveCount;
        assertEq(collection.totalSupply(), count);
        assertLe(count, collection.maxSupply());
        assertEq(collection.reserveMinted(), reserveCount);
        assertLe(reserveCount, collection.maxSupply() / 100);
        assertEq(collection.owner(), handler.expectedOwner());
        uint256 balances;
        uint256 publicCounts;
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            assertEq(collection.balanceOf(actor), handler.expectedBalance(actor));
            assertEq(collection.mintedPerWallet(actor), handler.expectedPublicMints(actor));
            assertLe(collection.mintedPerWallet(actor), collection.maxPerWallet());
            balances += collection.balanceOf(actor);
            publicCounts += collection.mintedPerWallet(actor);
        }
        assertEq(balances, count);
        assertEq(publicCounts, publicCount);
        for (uint256 id = 1; id <= count; ++id) {
            assertEq(collection.ownerOf(id), handler.expectedTokenOwner(id));
        }
    }

    function invariant_EveryWeiPaidHasExactlyOneRecipient() public view {
        uint256 publicCount = handler.publicMinted();
        assertEq(creator.balance, publicCount * (PRICE + 0.0002 ether));
        assertEq(platform.balance - platformBaseline, publicCount * 0.0002 ether);
        assertEq(reserve.balance, publicCount * 0.0001 ether);
        assertEq(creator.balance + platform.balance - platformBaseline + reserve.balance, handler.paid());
        assertEq(address(collection).balance, 0);
        assertEq(address(factory).balance, 0);
    }

    function invariant_OtherCloneAndImplementationRemainUntouched() public view {
        assertEq(untouched.owner(), bob);
        assertEq(untouched.totalSupply(), 0);
        assertEq(untouched.reserveMinted(), 0);
        assertEq(untouched.creator(), bob);
        assertFalse(untouched.paused());
        assertEq(untouched.baseURI(), "");
        assertFalse(untouched.metadataFrozen());
        assertFalse(untouched.revealSeedSet());
        assertEq(implementation.totalSupply(), 0);
        assertEq(implementation.owner(), address(0));
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            assertEq(untouched.balanceOf(actor), 0);
            assertEq(untouched.mintedPerWallet(actor), 0);
            assertEq(implementation.mintedPerWallet(actor), 0);
        }
    }
}
