# Loom contracts

Loom is an NFT collection launchpad for art produced off chain by the IMD swarm. This contribution supplies the Ethereum contracts, their tests and ABI exports. It includes the fixed-supply `LaunchToken`, the locked `LoomCollection` implementation, and `LoomFactory`, which creates and initializes EIP-1167 clones in one transaction.

## Build and verify

From the repository root, with Foundry and Solidity **0.8.26** available:

```sh
forge build
forge test
forge fmt --check
python3 tools/check_dependencies.py
python3 tools/export_abi.py --check
```

The compiler is pinned in `foundry.toml`, targeting Cancun, with optimization at 200 runs and `bytecode_hash = "none"`. All imported dependencies and their licenses are ordinary files under `lib/`; no package download or submodule is needed to compile or test. FFI and EVM filesystem permissions are disabled. Tests do not read environment variables, use RPC, access keys or depend on execution order. Python helpers use only the standard library.

The implementation uses OpenZeppelin's initializer-based ERC-721 as the permitted equivalent to ERC721A. OpenZeppelin Contracts and Contracts Upgradeable are pinned to **v5.0.2**; forge-std is pinned to **v1.9.7**. [Dependency provenance](docs/DEPENDENCIES.md) records upstream sources and hashes.

## Contracts and deployment parameters

| Order | Contract | Nonpayable constructor arguments | Configuration for this release |
| --- | --- | --- | --- |
| 1 | `LaunchToken` | none | Name `Loom`, symbol `LOOM`, 18 decimals |
| 2 | `LoomCollection` | `address platform, address reserve` | `$owner, $owner` |
| 3 | `LoomFactory` | `address implementation_, address platform_, address pauser_` | `$contract:LoomCollection, $owner, $owner` |

`$owner` is the approved launch owner, `0x02b4bd9cc103fd502b2f3f601e29e6ae2039ac85`. These symbols are deployment handoff values, not strings to pass to Solidity. They require no guessed address or post-launch recipient configuration. The collection implementation has no owner; every clone has its own owner. Factory pausing belongs only to the explicitly supplied `pauser`, never the constructor caller or `tx.origin`.

Constructors make no external calls and do not require another address to have code. `LoomFactory` checks implementation code and agreement with its `PLATFORM` on every creation. The reviewed manifest must reference the accepted `LoomCollection` implementation; this check alone does not authenticate arbitrary code supplied to a differently configured factory.

The standard token mints exactly **1,000,000,000 LOOM (10^27 units)** once to its deploying launch factory. It has plain ERC-20 transfers, approvals and allowances, with no mint, owner, pause, upgrade, burn, tax or blocklist entry point. Loom's NFT contracts receive no launch-token allocation and operate in ETH, independently of LOOM.

The launch is `evm_project` on Ethereum mainnet, chain ID **1**. The launch pipeline provides the token allocation, Merkle distributor and pool. The specified pairing is IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, pool fee **12500 (1.25%)**, tick spacing **60**, and manifest initial-price value `79228162514264337593543950336`. Services derive the effective opening price from policy; application contracts do not implement these allocations or pool fees.

`launch.json`, independent review, source publication, attestation, admission, deployment and the site are later assignments or service responsibilities. This contribution does not create a manifest or broadcast transactions. The explicit clone architecture applies to collections created after launch. The three top-level deployed runtimes contain no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; only the subsequently generated EIP-1167 clone runtimes delegate to the fixed implementation.

## Collection creation

Anyone may call:

```solidity
createCollection(
    string name,
    string symbol,
    uint256 maxSupply,
    uint256 mintPriceWei,
    uint256 maxPerWallet,
    address creator,
    uint96 royaltyBps
) payable returns (address collection);
```

Send exactly **0.002 ETH** (`CREATE_FEE`), including when the creator and platform are the same wallet. Zero payment, underpayment and overpayment all revert. The factory clones, initializes, appends to `collections`, marks `isCollection`, emits `CollectionCreated` and forwards the fee to `PLATFORM`. Any failure rolls back the clone, registry and payment.

`msg.sender` becomes the new collection's owner; `creator` receives primary-sale proceeds and royalties and may be a different address. All clone fields start independently, including both URIs, counters, approvals, owner, pause state, provenance, seed and royalty settings. The implementation is initialization-locked in its constructor. Clones have one successful initializer call, with no reinitializer or upgrade entry point. Factory creation leaves no uninitialized interval; anyone deploying a clone outside the factory must initialize it atomically as well. Such clones are absent from the factory's registry.

Validation requires nonzero creator and owner, positive supply, `1 <= maxPerWallet <= maxSupply`, and `0 <= royaltyBps <= 10000`. Mint price may be zero. `(mintPriceWei + PLATFORM_FEE) * maxSupply` must fit in `uint256`; otherwise initialization returns `InvalidMintPrice`. Name and symbol may be empty and are display-only inputs.

Use `collectionCount()` and `collections(index)` for bounded enumeration; out-of-range indices revert. `isCollection(address)` verifies factory membership. Duplicate names and symbols are permitted; use addresses as collection identities.

## Minting, payments and caps

`mint(quantity)` safely mints consecutive IDs starting at **1** to the caller. Quantity must be positive. It requires exactly:

```text
msg.value = (mintPrice + 500000000000000) * quantity
```

For each public-minted token:

| Recipient | Amount in ETH |
| --- | --- |
| Collection creator | `mintPrice` plus `0.0002` |
| Implementation's immutable `PLATFORM` | `0.0002` |
| Implementation's immutable `RESERVE` | `0.0001` |

The fixed **0.0005 ETH** platform fee splits **40/40/20**. All amounts are exact integer wei; the fee is divisible by five, so batches have no rounding dust. Identical recipients receive the sum of their shares. Creator price, fee, recipients, caps and royalty rate have no post-initialization setters. `FeesDistributed.creatorAmount` includes both the mint price and creator's fee share.

`mintedPerWallet` tracks lifetime successful **public mints**, not balance. Transferring tokens away does not free mint allowance; incoming transfers may take a holder's balance above `maxPerWallet`. Different wallets and clones have separate limits. This is a wallet cap, not a proof of unique human identity.

`reserveMint(quantity)` is an explicitly **free owner allocation**: it safely mints to the calling owner, with no creator price or platform fee, up to **floor(maxSupply / 100)** cumulatively across ownership changes. It does not consume the owner's public mint allowance. This interprets the brief's owner reserve separately from paid `mint()`. For supply below 100 the reserve allowance is zero. Reserve and public minting both consume `totalSupply`; the reserve is a limit, not inventory held back from the public sale. An owner wanting reserved tokens must mint them before the public sale consumes the supply. There is no public burn path.

Both mint paths stop when the collection is paused and use one reentrancy guard. Supply and wallet/reserve counters are reserved before ERC-721 callbacks. Contracts receiving NFTs must implement `onERC721Received`; rejection rolls back the entire batch. Transfers and approvals remain available during pauses.

ETH is pushed with checked calls after minting. A rejecting or gas-exhausting creator, platform or reserve makes the **entire mint revert**, including all earlier payments, tokens and counters; the payer retains the payment. A rejecting platform also blocks creation. Recipients must remain able to accept ETH. There is no pooled balance, deferred credit or admin withdrawal. Ordinary direct ETH transfers revert; forcibly sent ETH is not revenue and has no recovery path.

## Art, metadata and royalties

The collection owner controls these operations:

1. `setProvenanceHash(bytes32)` records one commitment while total supply is zero. Any reserve mint also closes this window.
2. `setUnrevealedURI(string)` supplies the placeholder URI. Both URIs start empty.
3. `setRevealSeed(bytes32)` records one off-chain seed. A separate flag makes even a zero seed consume the one allowed call; provenance uses the same explicit-flag approach.
4. `setBaseURI(string)` supplies the final prefix, normally an IPFS directory **including its trailing slash**.
5. `freezeMetadata()` permanently locks both URIs, provenance and reveal seed, including any values still unset. It cannot be undone or called twice.

For an existing token, `tokenURI(id)` is `unrevealedURI` while the base is empty, otherwise `baseURI + decimal(id) + ".json"`. Nonexistent IDs revert. Base URI presence controls visibility; the seed does not reorder IDs or control the URI branch. Before freezing the owner can replace or clear either URI. Freezing an empty base locks the placeholder behavior permanently but does not stop minting.

**The seed is an owner-supplied record, not verifiable randomness.** The contracts do not claim unbiased assignment, enforce a relation between seed and provenance, or verify off-chain art. Art production, deterministic provenance construction, seed sourcing, assignment and IPFS availability remain the collection operator's responsibility. Consumers must evaluate those commitments off chain. No oracle or external randomness service is configured.

ERC-2981 returns the fixed creator and `floor(salePrice * royaltyBps / 10000)` using the pinned OpenZeppelin implementation. It advertises royalties; secondary marketplaces decide whether to pay them. Ownership transfers never change the creator or royalty rate. The standard implementation reverts if a caller supplies a hypothetical sale price whose multiplication by the royalty rate overflows `uint256`.

Collection ownership uses a two-step `transferOwnership` / `acceptOwnership` handover. Setting pending owner to zero cancels a pending handover. Inherited `renounceOwnership` permanently removes all administrative powers; renouncing while paused prevents future mints, and renouncing before metadata completion leaves unfinished metadata locked by lack of authority. The owner must deliberately finish the lifecycle before renouncing.

## After launch

- **Launch services:** deploy the accepted source with the reviewed constructor values above; publish attestations, ABIs and addresses. Confirm the platform can receive ETH and the pauser is controlled by the approved owner. There are no missing service IDs, subscriptions, keys or external-contract settings in this design.
- **Factory pauser:** use `pause()` / `unpause()` on `LoomFactory` to stop/resume creation. This immutable role cannot upgrade code, change fees, change recipients, withdraw funds, modify collections or stop existing mints. There is no role-rotation setter.
- **Collection creators/owners:** verify economics before creation; use the correct creator address; arrange any reserve mint; publish provenance before the first mint; set placeholder and base URIs from the actual pinned IPFS metadata; publish the seed once; verify metadata, then freeze. Collections open for minting immediately when created. If commitment must precede public access, use a creator-controlled contract to create and set provenance/pause in the same transaction, or publish the pre-mint commitment before advertising the collection; mempool ordering can otherwise allow an early mint.
- **Frontend/indexer:** use the deployment handoff's addresses and chain ID, factory registry and `CollectionCreated` events; calculate exact integer-wei payment; check remaining supply, wallet lifetime mint count and pause state; index ERC-721 `Transfer` events for connected-wallet tokens. Treat name, symbol and URI content as untrusted display data. The contract does not implement ERC-721 Enumerable or a full-wallet array getter. Pool UI must use the exact deployed pool key from the handoff.
- **Independent reviewer:** review accepted source and the later manifest, particularly immutable beneficiary addresses and pauser ownership, before production release. Local tests and the self-review notes are not an independent audit.

Machine-readable ABI arrays are in [docs/abi](docs/abi); function/event guidance is in [docs/ABI.md](docs/ABI.md), and validation and trust boundaries are in [docs/VALIDATION.md](docs/VALIDATION.md).
