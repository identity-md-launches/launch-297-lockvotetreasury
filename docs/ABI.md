# Contract interface handoff

The JSON files in `docs/abi/` are full compiler-generated ABI arrays, including constructors, errors, events, and inherited ERC-20 methods. Token/lock/vote amounts use 18-decimal LVOT minor units; ETH amounts are wei. Timestamps are Unix seconds. IDs are zero-based; an ID greater than or equal to `proposalCount()` reverts in `proposal`, `vote`, and `execute`.

| Contract/function | Caller inputs | Result or behavior |
| --- | --- | --- |
| LaunchToken constructor | None | Mints `10^27` minor units to its caller. |
| `name`, `symbol`, `decimals`, `totalSupply` | None | `Lockvote`, `LVOT`, `18`, `10^27`. |
| `balanceOf`, `allowance` | Account; owner and spender | Standard ERC-20 reads. |
| `approve`, `transfer`, `transferFrom` | Standard ERC-20 arguments | Standard ERC-20 writes returning `bool`; OpenZeppelin custom errors on failure. |
| Treasury constructor | `address tokenAddress` | Immutable token; no funding or initialization call. |
| `token()` | None | LVOT address. |
| `locked(holder)`, `lockedUntil(holder)` | Holder address | Lock credit and earliest allowed unlock timestamp. Timestamp can remain in the past after unlocking. |
| `lock(amount)`, `unlock(amount)` | Positive LVOT minor units | Pull approved LVOT, or return the caller's credited LVOT if unfrozen. |
| `donate()`, `receive()` | ETH as transaction value | Accept ETH and emit `Donated`. |
| `propose(recipient, amountWei, descriptionHash)` | Address, uint256, bytes32 | Returns proposal ID. Caller needs 100,000 LVOT locked. Receipt's `Proposed` event supplies the ID to a wallet UI. |
| `proposalCount()` | None | Number of created proposals. |
| `proposal(id)` | uint256 ID | Tuple described below; computed state is independent of funding and recipient acceptance. |
| `hasVoted(id, voter)` | ID and address | Whether this address has already voted on this ID; mapping returns false for an unknown ID. |
| `vote(id, support)` | ID and bool | Votes once at current locked weight and extends the freeze. |
| `execute(id)` | ID | Permissionless payment subject to passage, time, balance, and successful recipient call. |

`proposal(id)` returns, in order:

```text
(address recipient, uint256 amount, bytes32 descriptionHash,
 address proposer, uint256 voteEnd, uint256 forVotes,
 uint256 againstVotes, uint8 state)
```

| State value | Name | Meaning |
| --- | --- | --- |
| 0 | Active | Current timestamp is before `voteEnd`. |
| 1 | Defeated | Voting ended without both quorum and a strict supporting majority; before expiry. |
| 2 | Queued | Passed; before `voteEnd + 1 day`. |
| 3 | Executable | Passed; in `[voteEnd + 1 day, voteEnd + 15 days)`. Balance or a rejecting recipient can still prevent execution. |
| 4 | Executed | Payment succeeded. This state is permanent, including after expiry. |
| 5 | Expired | Unexecuted and timestamp is at least `voteEnd + 15 days`, including defeated proposals. |

Constants expose the same units: `PROPOSAL_THRESHOLD = 100000 * 10^18`, `QUORUM = 1000000 * 10^18`, `VOTING_PERIOD = 259200`, `EXECUTION_DELAY = 86400`, and `EXECUTION_EXPIRY = 1296000`. Expiry is measured from vote end, not creation or the end of the execution delay.

Events, with indexed fields marked `indexed`:

```solidity
Locked(address indexed holder, uint256 amount)
Unlocked(address indexed holder, uint256 amount)
Donated(address indexed donor, uint256 amount)
Proposed(uint256 indexed id, address indexed proposer, address indexed recipient,
         uint256 amount, bytes32 descriptionHash, uint256 voteEnd)
Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight)
Executed(uint256 indexed id, address indexed executor, address indexed recipient, uint256 amount)
```

LaunchToken also emits standard ERC-20 `Transfer` and `Approval` events. State transitions caused by time do not emit events. Use fresh `proposal(id)` reads to render them; successful receipt logs, not pending transactions, establish state changes. The ABI lists treasury errors (`InvalidToken`, `ZeroAmount`, `InvalidRecipient`, `InvalidProposal`, `InsufficientLockedBalance`, `TokensStillLocked`, `AlreadyVoted`, `VotingClosed`, `NoVotingWeight`, `AlreadyExecuted`, `ExecutionTooEarly`, `ProposalExpired`, `ProposalNotPassed`, `InsufficientETH`, `ETHTransferFailed`) and inherited library errors. `TokensStillLocked` includes the unlock timestamp.

The page must first check Sepolia chain ID 11155111, then read the treasury's `token()` for balance/allowance reads. Approve the treasury on that address before locking; wait for confirmation before `lock`. No permit, token faucet, treasury allocation, or in-page swap exists. Read ETH with the chain's native-balance method. Fetch proposal IDs from count/events, paginate view calls, and chunk event queries from the recorded deployment block without a backend/indexer. Handle reorganizations and refresh at time boundaries. Hash descriptions locally and show their hashes without assuming on-chain text retrieval. See the README for the required test-only notice and launch-pool acquisition explanation.
