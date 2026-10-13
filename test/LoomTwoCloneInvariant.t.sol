// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoomCollection} from "src/LoomCollection.sol";
import {LoomFactory} from "src/LoomFactory.sol";
import {TwoCloneHandler} from "./helpers/TwoCloneHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LoomTwoCloneInvariantTest is Test {
    TwoCloneHandler private handler;

    function setUp() public {
        address platform = makeAddr("sequence platform");
        address reserve = makeAddr("sequence reserve");
        address pauser = makeAddr("sequence pauser");
        LoomCollection logic = new LoomCollection(platform, reserve);
        LoomFactory factory = new LoomFactory(address(logic), platform, pauser);
        handler = new TwoCloneHandler(factory, logic, platform, reserve, pauser);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = TwoCloneHandler.mint.selector;
        selectors[1] = TwoCloneHandler.reserveMint.selector;
        selectors[2] = TwoCloneHandler.pause.selector;
        selectors[3] = TwoCloneHandler.metadata.selector;
        selectors[4] = TwoCloneHandler.ownership.selector;
        selectors[5] = TwoCloneHandler.approve.selector;
        selectors[6] = TwoCloneHandler.approveAll.selector;
        selectors[7] = TwoCloneHandler.transfer.selector;
        selectors[8] = TwoCloneHandler.reinitialize.selector;
        selectors[9] = TwoCloneHandler.create.selector;
        // Weight minting so approval/transfer actions have live tokens to exercise.
        selectors[10] = TwoCloneHandler.mint.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_BothClonesMatchIndependentOwnershipAndSupplyModels() public view {
        handler.assertCollections();
    }

    function invariant_MetadataNeverReopensAndRoyaltiesStayWithCreator() public view {
        handler.assertMetadataAndRoyalties();
    }

    function invariant_AllFeesAreConservedAndRegistryIsAppendOnly() public view {
        handler.assertMoneyAndRegistry();
    }

    /// @dev Guarantees the handler exercises live transitions and rejected calls on both clones.
    function test_DeterministicModelSequenceExercisesBothClones() public {
        for (uint8 i; i < 2; ++i) {
            handler.metadata(i, 0, 1 - i, bytes32(uint256(1)), false);
            handler.metadata(i, 2, i, bytes32(0), true);
            handler.metadata(i, 2, i, bytes32(uint256(1)), true);
            handler.mint(i, 2, 3, 0);
            handler.mint(i, 2, 1, 1);
            handler.reserveMint(i, i, 1, true);
            handler.approve(i, 0, 2, 3, true);
            handler.transfer(i, 0, 3, 4, 1);
            handler.approveAll(i, 2, 3, true);
            handler.transfer(i, 1, 3, 4, 2);
            handler.metadata(i, 0, i, bytes32(uint256(1)), true);
            handler.metadata(i, 3, i, bytes32(0), true);
            handler.metadata(i, 4, i, bytes32(0), true);
            handler.metadata(i, 0, i, bytes32(uint256(2)), true);
            handler.ownership(i, 0, i, 5, true);
            handler.ownership(i, 1, 5, 0, true);
            handler.pause(i, 5, true, true);
            handler.mint(i, 2, 1, 0);
            handler.pause(i, 5, false, true);
            handler.mint(i, 2, 1, 0);
            handler.reinitialize(i, 5, 100, bytes32(0));
            handler.assertCollections();
            handler.assertMetadataAndRoyalties();
            handler.assertMoneyAndRegistry();
        }
        handler.pause(2, 0, true, true);
        handler.create(3, 0);
        handler.pause(2, 0, false, true);
        handler.create(3, 0);
        handler.create(4, 3);
        handler.assertMoneyAndRegistry();
        assertGt(handler.successfulCalls(), 20);
        assertGt(handler.rejectedCalls(), 10);
    }
}
