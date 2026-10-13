// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoomCollection} from "../../src/LoomCollection.sol";
import {LoomFactory} from "../../src/LoomFactory.sol";

abstract contract LoomTestBase is Test {
    LoomCollection internal implementation;
    LoomFactory internal factory;
    LoomCollection internal collection;

    address internal platform;
    address internal reserve;
    address internal pauser;
    address internal collectionOwner;
    address internal creator;
    address internal alice;
    address internal bob;

    uint256 internal constant PRICE = 0.01 ether;
    uint256 internal constant FEE = 0.0005 ether;
    uint256 internal constant CREATE_FEE = 0.002 ether;
    uint256 internal constant SUPPLY = 1_000;
    uint256 internal constant WALLET_CAP = 10;

    function setUp() public virtual {
        platform = makeAddr("platform");
        reserve = makeAddr("reserve");
        pauser = makeAddr("pauser");
        collectionOwner = makeAddr("collection owner");
        creator = makeAddr("creator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(collectionOwner, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        implementation = new LoomCollection(platform, reserve);
        factory = new LoomFactory(address(implementation), platform, pauser);
        collection = _create(collectionOwner, "First", "ONE", SUPPLY, PRICE, WALLET_CAP, creator, 750);
    }

    function _create(
        address owner,
        string memory name,
        string memory symbol,
        uint256 supply,
        uint256 price,
        uint256 cap,
        address artist,
        uint96 royalty
    ) internal returns (LoomCollection) {
        vm.prank(owner);
        return
            LoomCollection(
                factory.createCollection{value: CREATE_FEE}(name, symbol, supply, price, cap, artist, royalty)
            );
    }

    function _mint(address minter, uint256 quantity) internal {
        vm.prank(minter);
        collection.mint{value: (PRICE + FEE) * quantity}(quantity);
    }
}
