# Lockvote (LVOT)

Lockvote is a **Sepolia-only test toy (chain ID 11155111)** for voting on a treasury of donated **Sepolia test ETH**. LVOT votes carry **no off-chain rights**. Whoever locks a quorum can pass an unopposed proposal and direct the available ETH to any recipient. The one-day execution delay gives visibility; it provides no veto, cancellation, or withdrawal right for donors.

This contribution delivers the contracts, Foundry tests, vendored dependencies, and ABI exports. Deployment through ProjectFactory, the generated `launch.json`, independent review, and the live website are separate workflow responsibilities. No deployment, transaction signing, or independent audit is claimed here.

## Contracts and deployment parameters

| Contract | Constructor arguments | Configuration |
| --- | --- | --- |
| `src/LaunchToken.sol:LaunchToken` | None | Name `Lockvote`, symbol `LVOT`, 18 decimals; exactly 1,000,000,000 LVOT (`1000000000000000000000000000` minor units) minted once to the constructor caller. |
| `src/LockVoteTreasury.sol:LockVoteTreasury` | One `address tokenAddress`, manifest argument `["$token"]` | Immutable LVOT address exposed by `token()`. No initial ETH or LVOT needed. |

Both constructors are nonpayable and require no initialization calls. Deploy the token before the treasury. Under ProjectFactory the entire initial supply belongs to the factory for the policy's liquidity and reward distribution; the treasury constructor leaves that supply untouched. Token addresses with no code, including zero, are rejected. This checks code presence, not token identity: services must supply the actual approved LaunchToken.

There is no owner, administrator, mint after construction, burn, fee, blocklist, pause, upgrade, rescue, arbitrary execution, or privileged beneficiary. Only passed proposals can send ETH out. Deployment on Sepolia is an operational requirement; the reusable contracts do not themselves inspect the chain ID. The application has no oracle, randomness, keeper, or backend dependency.

LVOT reaches users by swapping Sepolia ETH in the factory-seeded ETH/LVOT launch pool. The treasury neither distributes LVOT nor needs an allocation. Its supported token is the plain, non-rebasing, fee-free LaunchToken. See [dependency provenance](docs/DEPENDENCIES.md).

## Locking and voting

1. Approve the treasury on LVOT, then call `lock(amount)` with a positive amount in token minor units. `SafeERC20.safeTransferFrom` pulls exactly that amount of LVOT and credits the caller's lock.
2. With at least 100,000 LVOT locked, call `propose(recipient, amountWei, descriptionHash)`. Recipient must be nonzero and the ETH amount positive. IDs start at zero and increase monotonically. Proposals need no prefunding; proposing neither votes nor freezes tokens.
3. Voting lasts three days from proposal creation. Call `vote(id, support)` before `voteEnd` with a nonzero lock. Each address gets one immutable vote per proposal, weighted by its entire locked balance at that instant. Later locks do not increase an existing vote, and votes cannot be changed.
4. A vote extends `lockedUntil(holder)` to the greatest `voteEnd` among that holder's votes, including opposing votes. The entire locked balance, including additional locks, is frozen until then. `unlock(amount)` succeeds at the deadline itself, returning LVOT only to the caller through `SafeERC20.safeTransfer`.

The same locks may vote on multiple concurrent proposals, but cannot be unlocked, transferred, and used by another address to vote again on one still-open proposal. Quorum is 1,000,000 LVOT, counting both supporting and opposing votes. Passage requires a strict supporting majority; ties fail. One quorum holder can pass proposals alone. There is no proposer fee, proposal cap, vote delegation, snapshot of historical liquid balances, or automatic vote by the proposer.

`descriptionHash` is an opaque `bytes32` commitment. A frontend may use `keccak256` of UTF-8 description bytes. The contract neither stores nor retrieves the description, and a description never becomes executable calldata.

## ETH, execution, and failure behavior

Anyone may fund the treasury through `receive()` or `donate()`; both emit `Donated(donor, amount)`. Donations are irrevocable, with no individual donor refund or withdrawal account. Empty donations are allowed. Unknown calldata reverts.

A passed proposal is executable by anyone during **`[voteEnd + 1 day, voteEnd + 15 days)`** if its ETH amount is available. The balance is not reserved: competing passed proposals are paid first come, first served. An unfunded proposal can be retried after a donation, but never after expiry. Expired ETH remains available to other passed proposals; expiry does not pay or refund anyone automatically.

Execution marks the proposal executed before a single ETH `call` with empty calldata to its recipient. If the recipient rejects payment, the whole transaction reverts, including the executed flag and ETH movement. Anyone may retry within the window. A permanently rejecting recipient remains unpayable but cannot block other proposals. A proposal targeting the treasury itself also cannot execute, because its guarded `receive()` rejects the nested call. Every state-changing entry point, including donations and `receive()`, has a shared reentrancy guard. Successful proposals can execute at most once.

Through the supported lock/unlock API, treasury LVOT equals the sum of all locks; token supply stays fixed. **Do not transfer LVOT directly to the treasury.** ERC-20 transfers cannot be prevented: unsolicited transfers create surplus without lock credit, voting power, or a recovery path. Across arbitrary external transfers the general custody invariant is `LVOT balance >= sum of locks`. Tests explicitly cover this distinction. Similarly, EVM-forced ETH can increase the balance without a `Donated` event; ETH accounting should use the on-chain balance as authoritative. With ordinary donation flows, donations equal remaining treasury ETH plus successfully executed payments.

## Build and tests

Foundry uses Solidity **0.8.26**, Cancun EVM, optimizer runs 200, and `bytecode_hash = "none"`. All Solidity dependencies are ordinary files under `lib/`; no package fetch or submodule is needed. With Foundry and the pinned compiler installed:

```sh
forge build
forge test
forge fmt --check
```

FFI and filesystem cheatcode permissions are disabled. Delivered tests use no environment variables, RPC, wallets, or broadcast scripts. They create isolated fixtures and can run in parallel. Unit and fuzz tests cover supply, transfers and failed transfers, approval, proposal eligibility, voting snapshots, duplicate votes, overlapping lock deadlines, the exact vote/delay/expiry boundaries, exact quorum and ties, failed payouts and retries, competing funding, and reentrancy from both ETH recipients and token callbacks. Stateful invariant tests run 128 campaigns of 64 calls against independent accounting models for token custody, fixed supply, vote weights, ETH conservation, and execution at most once. The deployment harness also checks factory supply preservation, runtime size, and forbidden runtime opcodes.

ABI files are exported at [docs/abi/LaunchToken.json](docs/abi/LaunchToken.json) and [docs/abi/LockVoteTreasury.json](docs/abi/LockVoteTreasury.json). Refresh after contract changes:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/LockVoteTreasury.sol:LockVoteTreasury abi --json > docs/abi/LockVoteTreasury.json
```

See the [ABI and frontend handoff](docs/ABI.md) for state values, events, and wallet flows.

## Operational handoff

The manifest contributor must describe these accepted sources as `evm_project`, with LaunchToken as the launch token and one application entry `LockVoteTreasury` using `["$token"]`. Services own policy, signed artifact linkage, source publication, attestation, admission, and deployment. The manifest and source must undergo the independent adversarial review before release; these self-tests are not that review. The reviewer should attack vote reuse through transfers, later-lock vote inflation, quorum/tie boundaries, early/repeated/expired execution, recipient reentrancy, and funding competition. Constructor, source, policy, or authorization conflicts remain review findings.

Services must record the actual Sepolia token and treasury addresses, deployment transaction/block, accepted build and ABI artifacts, and pool information. There are no wallet addresses or keys to configure in these sources. Do not infer that an unused factory caller has administrative powers.

After the live deployment, the frontend assignment publishes the small static page labelled `lab-lock-dao`, with `dist/index.html`; GitHub publication and IPFS hosting are approved by the workflow. It must display the test-only/no-rights explanation above, the treasury ETH balance, connected-wallet LVOT balance and allowance, approve/lock/unlock with the unlock time, proposal creation/listing/tallies/state, voting, and execution. It reads LVOT from `token()`, explains acquisition through the ETH/LVOT launch pool with no in-page swap, uses views and events with chunked logs from the recorded deployment block, and restricts wallet transactions to Sepolia. Description preimages and network transaction fees are the users' responsibility. Anyone choosing to execute pays gas; no automatic executor is assumed.
