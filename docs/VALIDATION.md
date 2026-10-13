# Validation and review handoff

This is the source contributor's test record and self-review, not the separate independent adversarial review required before release.

## Recorded local result

With Foundry 1.8.3 and the pinned Solidity 0.8.26 compiler:

- `forge build`: passed, with the lint observations discussed below.
- `forge test`: **58 reported tests passed, 0 failed, 0 skipped** across six suites. Foundry groups the three invariant properties into one reported test; that group passed 128 runs and 8,192 actions. The five parameterized fuzz tests each ran 256 cases.
- `env -i PATH=/usr/local/bin:/usr/bin:/bin forge test --offline --threads 4`: the same suite passed using an empty application environment and offline mode.
- `forge fmt --check`: passed.
- ABI comparison and all 57 vendored-file integrity checks: passed.

Production runtimes from `forge build --sizes`: `LaunchToken` 1,722 bytes, `LoomCollection` 11,114 bytes, `LoomFactory` 2,618 bytes. All are below 24,576 bytes and have no external library link references.

## Test coverage by behavior

| Suite | Evidence |
| --- | --- |
| `LoomCollection.t.sol` | Implementation lock; clone replay lock; rollback of invalid initialization; input bounds; standard interfaces; exact fee distribution and logs; free creator price; coincident recipients; fuzzed price/quantity/payment/royalty values; lifetime caps despite transfers; combined supply cap; reserve rounding and ownership handover; ERC-721 authorization; pause behavior; provenance window; zero-value one-time flags; URI resolution; irreversible metadata freeze; owner-only methods. |
| `LoomFactory.t.sol` | Exact creation fee and forwarding; return value/event/registry agreement; canonical 45-byte proxy runtime; clone initialization and mutable-state isolation; invalid initialization rollback; pauser authorization; first-use code/platform checks; constructor accepting an undeployed dependency. |
| `Adversarial.t.sol` | Rejecting creator, platform and reserve; rollback of earlier successful ETH sends; ERC-721 receiver absence and rejection partway through a batch; reserve allowance rollback; callback observations of reserved counters; NFT and ETH reentry into both mint paths; reentry into creation; failed creation leaves no proxy or registry entry; ordinary ETH donations rejected. |
| `LoomInvariant.t.sol` | Independent ghost model over randomized public mints, inexact payments, reserve mints, token transfers, pauses and ownership handovers. Three properties check supply/wallet/owner agreement, exact ETH conservation, and untouched other-clone/implementation storage. Defaults: 128 runs of 64 actions, with unexpected handler reverts treated as failures. |
| `LaunchToken.t.sol` | Fixed policy supply and identity, full initial allocation to deployer, fuzzed plain transfers, allowance spending/failure and absence of common mint/admin/upgrade selectors. |
| `Deployment.t.sol` | Production runtime presence, EIP-170 size limit and forbidden-opcode scan matching the supplied project floor; application deployment leaves the complete token supply with its deploying launch factory. |

Run the root `forge build`, `forge test` and `forge fmt --check` commands. The ABI and dependency checks described in the README are deterministic and offline. `forge build --sizes` reports production runtime sizes. There are no skips, network forks, environment-driven tests or calls to deployed services.

## Security decisions and operational limits

- **Initialization:** the implementation constructor disables all initializer versions. The factory's clone initialization precedes every external payment. The public initializer intentionally supports fresh clone storage; direct third-party cloning must preserve atomic initialization.
- **Funds and reentrancy:** both mint paths share the clone's initialized guard; creation has its own guard. Whole-batch counters are set before receiver hooks. Payments have fixed destinations and come from the exact current transaction value. A failed recipient rolls back the transaction rather than creating a debt. Tests exercise callbacks and late-payment failures explicitly.
- **Rounding and overflow:** fee shares are exact multiples of constant wei amounts. The creator receives the expected payment minus platform and reserve shares. Initialization ensures even a full-supply batch price fits `uint256`. All state counters use checked arithmetic and validated remaining-capacity comparisons. Royalties use standard OpenZeppelin integer rounding; excessively large hypothetical royalty quotes can overflow and revert.
- **Administration:** only clone owners configure metadata, consume the 1% reserve and pause their minting. They cannot alter economics or recover unsolicited funds. Two-step transfers preserve counters and creator economics. Renunciation is irreversible. The factory's immutable pauser controls creation alone.
- **Metadata and ordering:** metadata is mutable until freeze; a freeze can lock empty data. The owner-supplied seed is not random or verified. Public minting starts on creation, so the owner must account for the pre-first-mint provenance deadline, including mempool ordering. These are disclosed operator responsibilities, not cryptographic assurances.
- **Availability:** rejection of ETH by a shared platform/reserve blocks dependent operations. Gas-heavy NFT receivers and huge batches may exceed transaction gas limits; callers should choose practical batch sizes. No on-chain automation promises a mint, reveal or eventual fee-recipient recovery.
- **Deployment authority:** implementation and beneficiaries are immutable constructor choices. The factory checks code presence and platform agreement at creation, but the later independent source/manifest review must verify the actual implementation reference and all three `$owner` bindings. Constructors make no calls to outside contracts. No application contract receives the launch token supply.

## Tool findings and remaining review

Foundry 1.8.3's built-in linter reports conservative warnings about external-call/event ordering, uncapped ETH calls and division before multiplication. The relevant callbacks are guarded and tested; URI/seed/provenance setters make no external calls; the payment helper is private with fixed configured recipients; the fee divisions are exact because `500000000000000` is divisible by five. These warnings have not been globally suppressed.

The delivered tests are local simulations of hostile receivers and randomized state sequences. They do not establish the quality or availability of off-chain art, prove unbiased reveal assignment, certify recipient-wallet operations, or substitute for review of the eventual manifest. Slither, Mythril, deployment transactions, source publication and an independent audit are not claimed as completed by this source assignment.

The separate reviewer should validate the canonical constructor bindings and clone allowance against the launch services, verify fees and reserve semantics against the approved workflow, and inspect accepted source and manifest together. Policy attestations and signed-artifact linkage are service responsibilities rather than missing source deliverables.
