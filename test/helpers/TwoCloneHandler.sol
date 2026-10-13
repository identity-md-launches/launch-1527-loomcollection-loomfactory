// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoomCollection} from "src/LoomCollection.sol";
import {LoomFactory} from "src/LoomFactory.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev All preconditions and expected state come from this model, not contract getters.
/// Actors and payees are disjoint so ETH accounting remains independent of NFT ownership.
contract TwoCloneHandler is Test {
    uint256 private constant FEE = 0.0005 ether;
    uint256 private constant CREATE_FEE = 0.002 ether;

    struct Model {
        address owner;
        address pendingOwner;
        uint256 supplyLimit;
        uint256 walletLimit;
        uint256 price;
        uint96 royalty;
        uint256 publicMints;
        uint256 reserves;
        bool paused;
        bool frozen;
        bool provenanceSet;
        bool seedSet;
        bytes32 provenance;
        bytes32 seed;
        string base;
        string unrevealed;
    }

    LoomFactory public immutable factory;
    LoomCollection public immutable implementation;
    address public immutable platform;
    address public immutable reserve;
    address public immutable pauser;
    LoomCollection[2] public clones;
    address[2] public artists;
    address[6] public actors;
    Model[2] private model;
    address[] private registry;
    bool private creationPaused;
    uint256 public successfulCalls;
    uint256 public rejectedCalls;
    uint256 public mintPayments;
    mapping(uint256 => mapping(address => uint256)) private walletMints;
    mapping(uint256 => mapping(address => uint256)) private balances;
    mapping(uint256 => mapping(uint256 => address)) private holders;
    mapping(uint256 => mapping(uint256 => address)) private approvals;
    mapping(uint256 => mapping(address => mapping(address => bool))) private operators;

    constructor(
        LoomFactory factory_,
        LoomCollection implementation_,
        address platform_,
        address reserve_,
        address pauser_
    ) {
        factory = factory_;
        implementation = implementation_;
        platform = platform_;
        reserve = reserve_;
        pauser = pauser_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("sequence actor ", vm.toString(i)));
            vm.deal(actors[i], 1_000 ether);
        }
        for (uint256 i; i < 2; ++i) {
            artists[i] = makeAddr(string.concat("sequence artist ", vm.toString(i)));
            Model storage m = model[i];
            m.owner = actors[i];
            m.supplyLimit = i == 0 ? 100 : 199;
            m.walletLimit = i == 0 ? 23 : 41;
            m.price = i == 0 ? 1 : 10_003;
            m.royalty = i == 0 ? 1 : 9_999;
            vm.prank(m.owner);
            clones[i] = LoomCollection(
                factory.createCollection{value: CREATE_FEE}(
                    i == 0 ? "Sequence A" : "Sequence B",
                    i == 0 ? "A" : "B",
                    m.supplyLimit,
                    m.price,
                    m.walletLimit,
                    artists[i],
                    m.royalty
                )
            );
            registry.push(address(clones[i]));
        }
    }

    function mint(uint8 cloneSeed, uint8 actorSeed, uint8 quantitySeed, uint8 paymentSeed) external {
        uint256 i = cloneSeed % 2;
        address actor = actors[actorSeed % actors.length];
        Model storage m = model[i];
        uint256 quantity = quantitySeed % 45;
        uint256 cost = (m.price + FEE) * quantity;
        uint256 sent = cost;
        if (paymentSeed % 4 == 1) sent = cost == 0 ? 1 : cost - 1;
        if (paymentSeed % 4 == 2) sent = cost + 1;
        bool expected = quantity > 0 && sent == cost && !m.paused
            && m.publicMints + m.reserves + quantity <= m.supplyLimit
            && walletMints[i][actor] + quantity <= m.walletLimit;
        uint256 before = actor.balance;
        _execute(address(clones[i]), actor, abi.encodeCall(LoomCollection.mint, (quantity)), sent, expected);
        assertEq(actor.balance, expected ? before - sent : before, "payer ETH mismatch");
        if (expected) {
            _recordTokens(i, actor, quantity);
            m.publicMints += quantity;
            walletMints[i][actor] += quantity;
            mintPayments += sent;
        }
    }

    function reserveMint(uint8 cloneSeed, uint8 actorSeed, uint8 quantitySeed, bool authorized) external {
        uint256 i = cloneSeed % 2;
        Model storage m = model[i];
        address caller = _caller(m.owner, actorSeed, authorized);
        uint256 quantity = quantitySeed % 4;
        bool expected = caller == m.owner && quantity > 0 && !m.paused && m.reserves + quantity <= m.supplyLimit / 100
            && m.publicMints + m.reserves + quantity <= m.supplyLimit;
        _execute(address(clones[i]), caller, abi.encodeCall(LoomCollection.reserveMint, (quantity)), 0, expected);
        if (expected) {
            _recordTokens(i, caller, quantity);
            m.reserves += quantity;
        }
    }

    function pause(uint8 targetSeed, uint8 actorSeed, bool desired, bool authorized) external {
        uint256 i = targetSeed % 3;
        address role = i == 2 ? pauser : model[i].owner;
        address caller = _caller(role, actorSeed, authorized);
        bool before = i == 2 ? creationPaused : model[i].paused;
        bool expected = caller == role && before != desired;
        _execute(
            i == 2 ? address(factory) : address(clones[i]),
            caller,
            desired ? abi.encodeWithSignature("pause()") : abi.encodeWithSignature("unpause()"),
            0,
            expected
        );
        if (expected) {
            if (i == 2) creationPaused = desired;
            else model[i].paused = desired;
        }
    }

    function metadata(uint8 cloneSeed, uint8 kindSeed, uint8 actorSeed, bytes32 value, bool authorized) external {
        uint256 i = cloneSeed % 2;
        uint256 kind = kindSeed % 5;
        Model storage m = model[i];
        address caller = _caller(m.owner, actorSeed, authorized);
        bool expected = caller == m.owner && !m.frozen;
        bytes memory data;
        string memory uri = uint256(value) % 4 == 0 ? "" : string.concat("ipfs://", vm.toString(value), "/");
        if (kind == 0) {
            data = abi.encodeCall(LoomCollection.setBaseURI, (uri));
        } else if (kind == 1) {
            data = abi.encodeCall(LoomCollection.setUnrevealedURI, (uri));
        } else if (kind == 2) {
            expected = expected && !m.provenanceSet && m.publicMints + m.reserves == 0;
            data = abi.encodeCall(LoomCollection.setProvenanceHash, (value));
        } else if (kind == 3) {
            expected = expected && !m.seedSet;
            data = abi.encodeCall(LoomCollection.setRevealSeed, (value));
        } else {
            data = abi.encodeCall(LoomCollection.freezeMetadata, ());
        }
        _execute(address(clones[i]), caller, data, 0, expected);
        if (!expected) return;
        if (kind == 0) {
            m.base = uri;
        } else if (kind == 1) {
            m.unrevealed = uri;
        } else if (kind == 2) {
            m.provenanceSet = true;
            m.provenance = value;
        } else if (kind == 3) {
            m.seedSet = true;
            m.seed = value;
        } else {
            m.frozen = true;
        }
    }

    function ownership(uint8 cloneSeed, uint8 kindSeed, uint8 actorSeed, uint8 nextSeed, bool authorized) external {
        uint256 i = cloneSeed % 2;
        uint256 kind = kindSeed % 4;
        Model storage m = model[i];
        address role = kind == 1 ? m.pendingOwner : m.owner;
        address caller = _caller(role, actorSeed, authorized);
        bool expected = caller == role;
        address next = actors[nextSeed % actors.length];
        bytes memory data;
        if (kind == 0) data = abi.encodeWithSignature("transferOwnership(address)", next);
        else if (kind == 1) data = abi.encodeWithSignature("acceptOwnership()");
        else if (kind == 2) data = abi.encodeWithSignature("transferOwnership(address)", address(0));
        else data = abi.encodeWithSignature("renounceOwnership()");
        _execute(address(clones[i]), caller, data, 0, expected);
        if (!expected) return;
        if (kind == 0) {
            m.pendingOwner = next;
        } else if (kind == 1) {
            m.owner = m.pendingOwner;
            m.pendingOwner = address(0);
        } else if (kind == 2) {
            m.pendingOwner = address(0);
        } else {
            m.owner = address(0);
            m.pendingOwner = address(0);
        }
    }

    function approve(uint8 cloneSeed, uint8 idSeed, uint8 actorSeed, uint8 toSeed, bool authorized) external {
        uint256 i = cloneSeed % 2;
        uint256 total = model[i].publicMints + model[i].reserves;
        uint256 id = total == 0 ? 1 : uint256(idSeed) % total + 1;
        address holder = holders[i][id];
        address caller = _caller(holder, actorSeed, authorized);
        address to = toSeed % 7 == 6 ? address(0) : actors[toSeed % actors.length];
        bool expected = holder != address(0) && (caller == holder || operators[i][holder][caller]);
        _execute(address(clones[i]), caller, abi.encodeWithSignature("approve(address,uint256)", to, id), 0, expected);
        if (expected) approvals[i][id] = to;
    }

    function approveAll(uint8 cloneSeed, uint8 actorSeed, uint8 operatorSeed, bool approved) external {
        uint256 i = cloneSeed % 2;
        address holder = actors[actorSeed % actors.length];
        address operator = operatorSeed % 7 == 6 ? address(0) : actors[operatorSeed % actors.length];
        bool expected = operator != address(0);
        _execute(
            address(clones[i]),
            holder,
            abi.encodeWithSignature("setApprovalForAll(address,bool)", operator, approved),
            0,
            expected
        );
        if (expected) operators[i][holder][operator] = approved;
    }

    function transfer(uint8 cloneSeed, uint8 idSeed, uint8 actorSeed, uint8 toSeed, uint8 kindSeed) external {
        uint256 i = cloneSeed % 2;
        uint256 total = model[i].publicMints + model[i].reserves;
        uint256 id = total == 0 ? 1 : uint256(idSeed) % total + 1;
        address holder = holders[i][id];
        uint256 kind = kindSeed % 5;
        address caller = _caller(holder, actorSeed, kind == 0);
        if (kind == 1 && approvals[i][id] != address(0)) caller = approvals[i][id];
        address to = kind == 3 ? address(0) : actors[toSeed % actors.length];
        address from = kind == 4 ? actors[actorSeed % actors.length] : holder;
        bool expected = holder != address(0) && to != address(0) && from == holder
            && (caller == holder || caller == approvals[i][id] || operators[i][holder][caller]);
        _execute(
            address(clones[i]),
            caller,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id),
            0,
            expected
        );
        if (expected) {
            --balances[i][holder];
            ++balances[i][to];
            holders[i][id] = to;
            approvals[i][id] = address(0);
        }
    }

    function reinitialize(uint8 targetSeed, uint8 actorSeed, uint256 supply, bytes32 seed) external {
        uint256 target = targetSeed % 3;
        address subject = target == 2 ? address(implementation) : address(clones[target]);
        bytes memory result = _execute(
            subject,
            actors[actorSeed % actors.length],
            abi.encodeCall(
                LoomCollection.initialize, (vm.toString(seed), "REPLAY", supply, 0, 1, actors[0], 0, actors[0])
            ),
            0,
            false
        );
        assertEq(result, abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
    }

    function create(uint8 actorSeed, uint8 kindSeed) external {
        address caller = actors[actorSeed % actors.length];
        uint256 kind = kindSeed % 4;
        // Bound registry growth without reducing the invalid-call/rollback coverage.
        if (registry.length >= 10 && kind == 0) kind = 1;
        uint256 sent = kind == 1 ? CREATE_FEE - 1 : kind == 2 ? CREATE_FEE + 1 : CREATE_FEE;
        uint256 supply = kind == 3 ? 0 : 100;
        bool expected = !creationPaused && kind == 0;
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        uint256 before = caller.balance;
        bytes memory result = _execute(
            address(factory),
            caller,
            abi.encodeCall(LoomFactory.createCollection, ("Extra", "X", supply, 0, 1, artists[0], 0)),
            sent,
            expected
        );
        assertEq(caller.balance, expected ? before - sent : before, "creation payment mismatch");
        if (expected) {
            address deployed = abi.decode(result, (address));
            assertEq(deployed, predicted);
            assertEq(LoomCollection(deployed).owner(), caller);
            registry.push(deployed);
        } else {
            assertEq(predicted.code.length, 0, "failed creation left a clone");
            assertFalse(factory.isCollection(predicted));
        }
    }

    function assertCollections() external view {
        for (uint256 i; i < 2; ++i) {
            LoomCollection c = clones[i];
            Model storage m = model[i];
            uint256 total = m.publicMints + m.reserves;
            assertEq(c.name(), i == 0 ? "Sequence A" : "Sequence B");
            assertEq(c.symbol(), i == 0 ? "A" : "B");
            assertEq(c.maxSupply(), m.supplyLimit);
            assertEq(c.maxPerWallet(), m.walletLimit);
            assertEq(c.mintPrice(), m.price);
            assertEq(c.creator(), artists[i]);
            assertEq(c.royaltyBps(), m.royalty);
            assertEq(c.PLATFORM(), platform);
            assertEq(c.RESERVE(), reserve);
            assertEq(c.owner(), m.owner);
            assertEq(c.pendingOwner(), m.pendingOwner);
            assertEq(c.paused(), m.paused);
            assertEq(c.totalSupply(), total);
            assertLe(total, m.supplyLimit);
            assertEq(c.reserveMinted(), m.reserves);
            assertLe(m.reserves, m.supplyLimit / 100);
            uint256 sumBalances;
            uint256 sumMints;
            for (uint256 a; a < actors.length; ++a) {
                address actor = actors[a];
                assertEq(c.balanceOf(actor), balances[i][actor]);
                assertEq(c.mintedPerWallet(actor), walletMints[i][actor]);
                assertLe(walletMints[i][actor], m.walletLimit);
                sumBalances += c.balanceOf(actor);
                sumMints += c.mintedPerWallet(actor);
                for (uint256 b; b < actors.length; ++b) {
                    assertEq(c.isApprovedForAll(actor, actors[b]), operators[i][actor][actors[b]]);
                }
            }
            assertEq(sumBalances, total);
            assertEq(sumMints, m.publicMints);
            for (uint256 id = 1; id <= total; ++id) {
                assertEq(c.ownerOf(id), holders[i][id]);
                assertEq(c.getApproved(id), approvals[i][id]);
            }
        }
    }

    function assertMetadataAndRoyalties() external view {
        for (uint256 i; i < 2; ++i) {
            LoomCollection c = clones[i];
            Model storage m = model[i];
            assertEq(c.baseURI(), m.base);
            assertEq(c.unrevealedURI(), m.unrevealed);
            assertEq(c.metadataFrozen(), m.frozen);
            assertEq(c.provenanceSet(), m.provenanceSet);
            assertEq(c.revealSeedSet(), m.seedSet);
            assertEq(c.provenanceHash(), m.provenance);
            assertEq(c.revealSeed(), m.seed);
            uint256 total = m.publicMints + m.reserves;
            if (total > 0) {
                assertEq(c.tokenURI(1), bytes(m.base).length == 0 ? m.unrevealed : string.concat(m.base, "1.json"));
                assertEq(
                    c.tokenURI(total),
                    bytes(m.base).length == 0 ? m.unrevealed : string.concat(m.base, vm.toString(total), ".json")
                );
            }
            (address receiver, uint256 amount) = c.royaltyInfo(total, 10_001);
            assertEq(receiver, artists[i]);
            assertEq(amount, uint256(m.royalty) * 10_001 / 10_000);
        }
    }

    function assertMoneyAndRegistry() external view {
        uint256 publicTokens = model[0].publicMints + model[1].publicMints;
        uint256 creationFees = registry.length * CREATE_FEE;
        uint256 allCreatorPayments;
        for (uint256 i; i < 2; ++i) {
            uint256 expectedCreator = model[i].publicMints * (model[i].price + FEE * 40 / 100);
            assertEq(artists[i].balance, expectedCreator);
            allCreatorPayments += expectedCreator;
            assertEq(address(clones[i]).balance, 0);
        }
        assertEq(platform.balance, creationFees + publicTokens * FEE * 40 / 100);
        assertEq(reserve.balance, publicTokens * FEE * 20 / 100);
        assertEq(allCreatorPayments + platform.balance - creationFees + reserve.balance, mintPayments);
        assertEq(address(factory).balance, 0);
        assertEq(factory.paused(), creationPaused);
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.PLATFORM(), platform);
        assertEq(factory.pauser(), pauser);
        assertEq(factory.collectionCount(), registry.length);
        for (uint256 i; i < registry.length; ++i) {
            assertEq(factory.collections(i), registry[i]);
            assertTrue(factory.isCollection(registry[i]));
            assertEq(
                registry[i].code,
                abi.encodePacked(
                    hex"363d3d373d3d3d363d73", address(implementation), hex"5af43d82803e903d91602b57fd5bf3"
                )
            );
            for (uint256 j; j < i; ++j) {
                assertNotEq(registry[i], registry[j]);
            }
        }
        assertFalse(factory.isCollection(address(implementation)));
        assertEq(implementation.totalSupply(), 0);
        assertEq(implementation.owner(), address(0));
        assertEq(implementation.baseURI(), "");
        assertFalse(implementation.metadataFrozen());
        assertEq(address(implementation).balance, 0);
    }

    function _caller(address role, uint8 actorSeed, bool authorized) private view returns (address) {
        // Never impersonate the zero address after renunciation/cancellation.
        return authorized && role != address(0) ? role : actors[actorSeed % actors.length];
    }

    function _recordTokens(uint256 i, address recipient, uint256 quantity) private {
        uint256 first = model[i].publicMints + model[i].reserves + 1;
        for (uint256 id = first; id < first + quantity; ++id) {
            holders[i][id] = recipient;
        }
        balances[i][recipient] += quantity;
    }

    function _execute(address target, address caller, bytes memory data, uint256 value, bool expected)
        private
        returns (bytes memory result)
    {
        vm.prank(caller);
        bool success;
        (success, result) = target.call{value: value}(data);
        assertEq(success, expected, "model disagrees with call success");
        if (success) ++successfulCalls;
        else ++rejectedCalls;
    }
}
