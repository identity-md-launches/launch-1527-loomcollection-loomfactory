// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LoomCollection} from "./LoomCollection.sol";

/// @notice Permissionless, immutable collection factory. The pauser can only pause creation.
contract LoomFactory is Pausable, ReentrancyGuard {
    uint256 public constant CREATE_FEE = 0.002 ether;
    address public immutable implementation;
    address public immutable PLATFORM;
    address public immutable pauser;

    /// @notice Append-only registry in creation order; use collectionCount() and collections(index).
    address[] public collections;
    mapping(address collection => bool registered) public isCollection;

    error InvalidAddress();
    error InvalidImplementation();
    error PlatformMismatch();
    error UnauthorizedPauser(address caller);
    error IncorrectCreationFee(uint256 expected, uint256 received);
    error PaymentFailed(address recipient, uint256 amount);

    event CollectionCreated(address indexed collection, address indexed owner, string name, uint256 maxSupply);

    /// @dev Constructors intentionally make no external calls. Validate implementation at first use.
    constructor(address implementation_, address platform_, address pauser_) {
        if (implementation_ == address(0) || platform_ == address(0) || pauser_ == address(0)) {
            revert InvalidAddress();
        }
        implementation = implementation_;
        PLATFORM = platform_;
        pauser = pauser_;
    }

    function createCollection(
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        uint256 mintPriceWei,
        uint256 maxPerWallet,
        address creator,
        uint96 royaltyBps
    ) external payable nonReentrant whenNotPaused returns (address collection) {
        if (msg.value != CREATE_FEE) revert IncorrectCreationFee(CREATE_FEE, msg.value);
        if (implementation.code.length == 0) revert InvalidImplementation();
        if (LoomCollection(implementation).PLATFORM() != PLATFORM) revert PlatformMismatch();

        collection = Clones.clone(implementation);
        LoomCollection(collection)
            .initialize(name, symbol, maxSupply, mintPriceWei, maxPerWallet, creator, royaltyBps, msg.sender);
        collections.push(collection);
        isCollection[collection] = true;
        emit CollectionCreated(collection, msg.sender, name, maxSupply);

        (bool success,) = PLATFORM.call{value: CREATE_FEE}("");
        if (!success) revert PaymentFailed(PLATFORM, CREATE_FEE);
    }

    function collectionCount() external view returns (uint256) {
        return collections.length;
    }

    function pause() external {
        if (msg.sender != pauser) revert UnauthorizedPauser(msg.sender);
        _pause();
    }

    function unpause() external {
        if (msg.sender != pauser) revert UnauthorizedPauser(msg.sender);
        _unpause();
    }
}
