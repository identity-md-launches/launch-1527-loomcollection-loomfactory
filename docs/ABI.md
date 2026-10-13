# ABI integration

The JSON files are plain ABI arrays generated from Foundry artifacts, including inherited functions, events and custom errors:

- [LaunchToken.json](abi/LaunchToken.json)
- [LoomCollection.json](abi/LoomCollection.json)
- [LoomFactory.json](abi/LoomFactory.json)

After source changes, run `forge build` then `python3 tools/export_abi.py`. Use `python3 tools/export_abi.py --check` to confirm parity. Attach the **LoomCollection ABI to each clone address**. The implementation address only supplies shared logic and immutable fee recipients; it is never an active mint collection.

## Factory interface

| Signature | Use |
| --- | --- |
| `createCollection(string,string,uint256,uint256,uint256,address,uint96)` payable → `address` | Arguments: name, symbol, maxSupply, mintPriceWei, maxPerWallet, creator, royaltyBps. Exact `CREATE_FEE` required; caller becomes clone owner. |
| `CREATE_FEE()` → `uint256` | Always `2000000000000000` wei. |
| `implementation()`, `PLATFORM()`, `pauser()` → `address` | Immutable deployment settings. |
| `collectionCount()` → `uint256` | Number of successfully created collections. |
| `collections(uint256)` → `address` | Index in append-only creation order, starting at zero. |
| `isCollection(address)` → `bool` | Whether this factory created the address. |
| `paused()` → `bool` | Whether creation is disabled. |
| `pause()`, `unpause()` | Immutable pauser only. |

`CollectionCreated(address indexed collection,address indexed owner,string name,uint256 maxSupply)` is emitted once for each successful creation. A reverted transaction has no canonical logs and no registry entry. Read the receipt's log to obtain the new address; transactions do not expose Solidity return data through ordinary wallet APIs.

## Collection interface

`initialize(string,string,uint256,uint256,uint256,address,uint96,address)` takes name, symbol, maxSupply, mintPriceWei, maxPerWallet, creator, royaltyBps and owner, in that order. Only clone deployment code should call it, atomically with creation. The factory supplies owner automatically. All other application changes are nonpayable except `mint`.

| Signature | Use |
| --- | --- |
| `mint(uint256 quantity)` payable | Positive quantity, exact `(mintPrice() + PLATFORM_FEE()) * quantity` wei. |
| `reserveMint(uint256 quantity)` | Owner-only free reserve mint, at most 1% rounded down, also subject to total supply and pause. |
| `maxSupply()`, `totalSupply()`, `maxPerWallet()`, `mintedPerWallet(address)`, `reserveMinted()` → `uint256` | Supply and lifetime mint counters. |
| `mintPrice()`, `PLATFORM_FEE()` → `uint256` | Immutable-per-clone creator price and shared fee in wei. |
| `creator()`, `PLATFORM()`, `RESERVE()` → `address` | Primary payment recipients. |
| `royaltyBps()` → `uint96` | Fixed royalty rate in basis points. |
| `royaltyInfo(uint256 tokenId,uint256 salePrice)` → `(address receiver,uint256 royaltyAmount)` | ERC-2981 quote; same creator/rate for every ID. |
| `pause()`, `unpause()`, `paused()` | Owner-operated pause on both mint paths only. |
| `setProvenanceHash(bytes32)`, `provenanceHash()`, `provenanceSet()` | One pre-mint commitment and explicit presence flag. |
| `setRevealSeed(bytes32)`, `revealSeed()`, `revealSeedSet()` | One seed and explicit presence flag. |
| `setBaseURI(string)`, `baseURI()` | Metadata prefix, initially empty. |
| `setUnrevealedURI(string)`, `unrevealedURI()` | Placeholder URI, initially empty. |
| `freezeMetadata()`, `metadataFrozen()` | Irreversible freeze of all four metadata setters. |
| `tokenURI(uint256)` → `string` | Existing token's resolved URI; IDs start at 1. |
| `owner()`, `pendingOwner()`, `transferOwnership(address)`, `acceptOwnership()`, `renounceOwnership()` | Two-step ownership and explicit renunciation. |

Standard ERC-721 `name`, `symbol`, `balanceOf`, `ownerOf`, `approve`, `getApproved`, `setApprovalForAll`, `isApprovedForAll`, `transferFrom`, both `safeTransferFrom` overloads, and ERC-165 `supportsInterface` are inherited. Interfaces supported are ERC-165 (`0x01ffc9a7`), ERC-721 (`0x80ac58cd`), metadata (`0x5b5e139f`) and ERC-2981 (`0x2a55205a`). `Transfer` is the authoritative ownership log, including transfers performed by an NFT receiver inside a mint callback. A `Minted` event identifies the original recipient and batch, not necessarily the final owner at transaction end.

Application event signatures:

```solidity
Minted(address indexed minter, uint256 indexed firstTokenId, uint256 quantity, bool reserved)
FeesDistributed(address indexed payer, uint256 creatorAmount, uint256 platformAmount, uint256 reserveAmount)
ProvenanceSet(bytes32 indexed provenanceHash)
Revealed(bytes32 indexed revealSeed)
MetadataFrozen()
BaseURISet(string baseURI)
UnrevealedURISet(string unrevealedURI)
```

`reserved == true` means free owner mint; no `FeesDistributed` is emitted for that path. Fee amounts are integer wei. Standard `Initialized`, `OwnershipTransferStarted`, `OwnershipTransferred`, `Paused`, `Unpaused`, `Transfer`, `Approval`, and `ApprovalForAll` events are also included in the ABI.

## Error handling

Decode errors using the contract ABI. Collection input and lifecycle errors include `InvalidAddress`, `InvalidSupply`, `InvalidWalletCap`, `InvalidMintPrice`, `InvalidRoyalty`, `ZeroQuantity`, `IncorrectPayment(expected,received)`, `MaxSupplyExceeded`, `WalletCapExceeded`, `ReserveCapExceeded`, `MetadataIsFrozen`, `ProvenanceAlreadySet`, `MintingAlreadyStarted`, and `RevealSeedAlreadySet`.

Factory errors include `InvalidAddress`, `InvalidImplementation`, `PlatformMismatch`, `UnauthorizedPauser(caller)` and `IncorrectCreationFee(expected,received)`. Both contracts can return `PaymentFailed(recipient,amount)`. Inherited errors cover repeated initialization, access denial, reentrancy, pause state and standard ERC-721 failures. Never retry a rejected payment with extra ETH: overpayment also reverts.

## Token interface

`LaunchToken` exposes the standard ERC-20 ABI: `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `transfer`, `allowance`, `approve`, and `transferFrom`, with `Transfer` and `Approval` events. No application action needs LOOM allowance or balance; collection creation and minting use ETH.
