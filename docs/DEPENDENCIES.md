# Vendored Solidity dependencies

All dependency files are ordinary source files, with no git submodules or installation needed during verification. Only the transitive OpenZeppelin Solidity sources used by the delivered contracts/tests are retained. Forge standard library `src/` is retained. Upstream licenses accompany both libraries.

| Library | Pinned release | Upstream archive | Archive SHA-256 |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.0.2 | `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2` | `18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a` |
| Forge Std | v1.9.7 | `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7` | `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94` |

The checksums describe the downloaded archives before extracting the selected files. Vendored Solidity contents are unmodified. OpenZeppelin supplies ERC20, SafeERC20, ReentrancyGuard and their dependencies; Forge Std is only a test dependency. Build outputs and a compiler binary are not deliverables. Solidity 0.8.26 is version-pinned in `foundry.toml`, not pinned to a machine path. Library remappings are in `remappings.txt`.
