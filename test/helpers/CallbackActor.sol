// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {LoomCollection} from "../../src/LoomCollection.sol";

/// @dev Deliberately configurable adversarial actor, used only in tests.
contract CallbackActor is IERC721Receiver {
    bool public rejectETH;
    uint256 public rejectNFTAt;
    uint256 public nftCallbacks;
    uint256 public attempts;
    bool public lastReentrySucceeded;
    bytes public lastReentryResult;
    uint256 public observedSupply;
    uint256 public observedWalletMints;

    address private target;
    bytes private payload;
    uint256 private value;
    bool private attackOnETH;
    bool private attackOnNFT;
    bool private inCallback;

    function setRejectETH(bool reject) external {
        rejectETH = reject;
    }

    function setRejectNFTAt(uint256 callbackNumber) external {
        rejectNFTAt = callbackNumber;
    }

    function configureAttack(address target_, bytes calldata payload_, uint256 value_, bool onETH, bool onNFT)
        external
    {
        target = target_;
        payload = payload_;
        value = value_;
        attackOnETH = onETH;
        attackOnNFT = onNFT;
    }

    function execute(address target_, bytes calldata payload_) external payable returns (bytes memory result) {
        bool success;
        (success, result) = target_.call{value: msg.value}(payload_);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    receive() external payable {
        require(!rejectETH, "recipient rejects ETH");
        if (attackOnETH) _attack();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++nftCallbacks;
        observedSupply = LoomCollection(msg.sender).totalSupply();
        observedWalletMints = LoomCollection(msg.sender).mintedPerWallet(address(this));
        if (attackOnNFT) _attack();
        if (rejectNFTAt != 0 && nftCallbacks == rejectNFTAt) return bytes4(0);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _attack() private {
        if (inCallback) return;
        inCallback = true;
        ++attempts;
        (lastReentrySucceeded, lastReentryResult) = target.call{value: value}(payload);
        inCallback = false;
    }
}

contract NoNFTReceiver {
    function mint(LoomCollection collection, uint256 quantity) external payable {
        collection.mint{value: msg.value}(quantity);
    }
}
