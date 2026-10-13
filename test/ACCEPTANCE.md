# Loom test contribution

The approved workflow and protected deployment/token checks are the requirements. This contribution adds tests to the accepted implementation without changing production contracts, configuration, dependencies, ABI exports, or the launch manifest.

Run offline from the repository root:

```sh
forge build --offline
forge test --offline
```

## Coverage

| Requirement | Existing coverage retained | Additional coverage |
| --- | --- | --- |
| Locked implementation, one initialization per clone | `LoomCollection.t.sol` checks implementation and clone replay, invalid inputs, and retry after failed initialization. | `LoomAcceptance.t.sol` fuzzes replay by arbitrary callers, owners, and factory against two used, frozen, paused clones; checks complete configuration preservation and exact price/supply overflow boundaries. The sequence handler attempts replay throughout random histories. |
| Permissionless creation, immutable implementation/recipients, enumeration, exact creation fee, creation-only pauser | `LoomFactory.t.sol` covers configuration, canonical EIP-1167 code, creation fees, invalid dependencies, unauthorized calls, and separation of pauser/collection powers. | Invalid initializer cases must roll back payment, registry, deployed code and factory nonce. Random creation/pause sequences check append-only registry entries and canonical runtime. Callback tests attempt initializer theft during creation-fee delivery. |
| Exact public mint price and 40/40/20 platform-fee split | `LoomCollection.t.sol` covers exact, missing, short and excess payment; zero quantity; free primary-sale price; shared recipients; mint/payment events. | Fuzzed batched versus split mints on two clones check every wei and both events. Arbitrary odd wei prices cannot create dust. Release topology tests share platform/reserve/pauser and also allow the creator to be the shared recipient. Random histories independently account for creation and mint revenue. |
| Wallet cap, hard supply cap, owner reserve limited to 1% | Existing unit/invariant tests cover lifetime wallet counts, transfers, public sellout, reserve/public supply interaction, owner authorization and paused calls. | Fuzzed reserve rounding at arbitrary supplies on two clones preserves allowance across ownership transfer; reserve events identify the correct owner/batch. Two active clone models track all balances, IDs, wallet counters, reserve counters, approvals and ownership. |
| Pause/unpause and collection isolation | Existing tests cover mint/reserve pause, transfers while paused, and untouched sibling state. | Both clones are actively mutated. Pause, handover, cancellation, renunciation, transfer, operator approval and revocation may interleave with minting, failed payments and replay attempts. Cross-clone approvals cannot authorize NFT transfers. |
| Provenance once before supply; reveal once; URIs; permanent metadata freeze | Existing unit tests cover events, zero-valued commitments/seeds, late provenance, owner checks, nonexistent IDs, URI switching and every frozen setter. | Two-clone freeze tests survive ownership transfer, including a permanently unrevealed clone. Stateful models preserve write-once fields and frozen state through random calls. Decimal URI boundaries 9/10/99/100 and literal prefix concatenation are checked. |
| Creator ERC-2981 royalties | Existing tests check interface support and fuzz the royalty quote. | Two-clone fuzzing uses a quotient/remainder rounding oracle, complementary rates, sale prices through the safe multiplication boundary and nonexistent token IDs. Zero/one-bps quotes are checked at `uint256.max`. Random ownership transitions must not redirect royalties. Quotes beyond the multiplication boundary have a separately reported defect. |
| Atomic external calls and failure paths | `Adversarial.t.sol` covers rejecting each payee, missing/rejecting NFT receivers, rejection partway through a batch, all mint reentry directions and creation reentry. | Cross-clone callbacks can legitimately mint on a different clone; a later outer payment rejection must roll back the nested mint and earlier payments too. The same operation succeeds after the recipient stops rejecting. |
| Standard LOOM token and deployment floor | `LaunchToken.t.sol` checks identity, policy supply, plain transfers, allowances, and absent admin/mint surface. `Deployment.t.sol` checks constructor behavior, sizes, allocation and forbidden opcodes without protected-test environment variables. | A closed-holder ledger checks total supply equals all balances and matches finite/infinite allowances after random transfers, approvals, invalid recipients, overdrafts and forbidden admin calls. |

## Property-test settings and limits

`LoomAcceptanceTest` uses 1,000 runs per fuzz property. The new collection and token invariant suites each use 256 runs of 64 calls, with unexpected handler reverts treated as failures. These settings are inline in the test files. Explicit target selectors prevent the fuzzer from invoking handler getters or inherited test utilities.

The handlers predict success/failure from independent state, perform the real call, and compare all observable accounting afterwards. Expected failed calls are caught and checked; unexpected failures fail the test. Deterministic sequence tests ensure both clone models and the token ledger exercise successful and rejected transitions even independently of random exploration.

ETH conservation is asserted over supported creation/mint calls with isolated funded test actors and distinct payees; forced ETH is outside this handler's action set. Hostile callbacks are exercised separately. Passing royalty fuzz cases cover the safe multiplication domain; the unsupported larger inputs are reported below. Tests do not model off-chain art, publication, deployment services, attestations, a future manifest, or frontend behavior. No environment mutation, forks, FFI, network access, runtime downloads, skipped tests, or external service is required.

## Reported arithmetic edge

`.imd-findings.json` reports a low-severity royalty-quote overflow: at 10,000 bps, `royaltyInfo(1, type(uint256).max)` should return the creator and the sale price itself, but the inherited multiplication panics with `0x11`. The result fits in `uint256`. This is already disclosed as a limitation in the accepted documentation and does not establish an impact at realistic ETH prices; it still prevents testing the full input domain as correct.

The JSON embeds a self-contained Foundry proof, observed failing with `forge test --offline --match-path test/scratch/RoyaltyOverflowProof.t.sol -vv`. The deliberately failing scratch file was removed after its source was copied into the report. No submitted test blesses the overflow as expected behavior. Passing the remaining suite is not a claim that all possible contract behavior has been proven correct.
