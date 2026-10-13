# Vendored dependencies

Only the required OpenZeppelin Solidity import closure and the forge-std `src/` tree are vendored. Files retain their original upstream bytes and license notices. No dependency install hook runs during the build.

| Package | Pinned release | Source | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.0.2 | [Release](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.0.2) | MIT, `lib/openzeppelin-contracts/LICENSE` |
| OpenZeppelin Contracts Upgradeable | v5.0.2 | [Release](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/releases/tag/v5.0.2) | MIT, `lib/openzeppelin-contracts-upgradeable/LICENSE` |
| forge-std | v1.9.7 | [Release](https://github.com/foundry-rs/forge-std/releases/tag/v1.9.7) | MIT/Apache-2.0, license files in `lib/forge-std/` |

`lib/dependencies.json` records the upstream release URL, SHA-256 of each downloaded GitHub release archive, and SHA-256 of every included file. `python3 tools/check_dependencies.py` checks the local files without accessing the network. This confirms integrity relative to the recorded source snapshot; it is not a security audit of upstream code.

Used production modules are ERC-20, Clones, ERC721Upgradeable, ERC2981Upgradeable, Ownable2StepUpgradeable, Initializable, Pausable/PausableUpgradeable, ReentrancyGuard/ReentrancyGuardUpgradeable, Strings and their internal dependencies. There is no proxy administration or UUPS module and no externally linked library. The `Upgradeable` suffix denotes initializer-compatible storage here; Loom exposes no upgrade mechanism.
