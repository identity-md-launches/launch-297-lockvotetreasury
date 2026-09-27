// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice LVOT-locked voting over donated Sepolia test ETH, without an administrator.
/// @dev Requires the plain, fixed-supply LaunchToken. Unsolicited token transfers are not locks.
contract LockVoteTreasury is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PROPOSAL_THRESHOLD = 100_000 ether;
    uint256 public constant QUORUM = 1_000_000 ether;
    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant EXECUTION_DELAY = 1 days;
    uint256 public constant EXECUTION_EXPIRY = 15 days;

    enum ProposalState {
        Active,
        Defeated,
        Queued,
        Executable,
        Executed,
        Expired
    }

    struct Proposal {
        address recipient;
        uint256 amount;
        bytes32 descriptionHash;
        address proposer;
        uint256 voteEnd;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
    }

    IERC20 public immutable token;
    uint256 public proposalCount;
    mapping(address holder => uint256 amount) public locked;
    mapping(address holder => uint256 timestamp) public lockedUntil;
    mapping(uint256 id => mapping(address voter => bool voted)) public hasVoted;
    mapping(uint256 id => Proposal) private _proposals;

    error InvalidToken();
    error ZeroAmount();
    error InvalidRecipient();
    error InvalidProposal();
    error InsufficientLockedBalance();
    error TokensStillLocked(uint256 until);
    error AlreadyVoted();
    error VotingClosed();
    error NoVotingWeight();
    error AlreadyExecuted();
    error ExecutionTooEarly();
    error ProposalExpired();
    error ProposalNotPassed();
    error InsufficientETH();
    error ETHTransferFailed();

    event Locked(address indexed holder, uint256 amount);
    event Unlocked(address indexed holder, uint256 amount);
    event Donated(address indexed donor, uint256 amount);
    event Proposed(
        uint256 indexed id,
        address indexed proposer,
        address indexed recipient,
        uint256 amount,
        bytes32 descriptionHash,
        uint256 voteEnd
    );
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event Executed(uint256 indexed id, address indexed executor, address indexed recipient, uint256 amount);

    /// @param tokenAddress The factory-deployed LVOT token; the manifest supplies $token.
    constructor(address tokenAddress) {
        if (tokenAddress == address(0) || tokenAddress.code.length == 0) revert InvalidToken();
        token = IERC20(tokenAddress);
    }

    receive() external payable nonReentrant {
        emit Donated(msg.sender, msg.value);
    }

    function donate() external payable nonReentrant {
        emit Donated(msg.sender, msg.value);
    }

    /// @notice Approve this contract on LVOT before locking. Additional locks do not amend votes.
    function lock(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        locked[msg.sender] += amount;
        emit Locked(msg.sender, amount);
    }

    /// @notice The entire balance, including later locks, is frozen until the latest voted voteEnd.
    function unlock(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < lockedUntil[msg.sender]) revert TokensStillLocked(lockedUntil[msg.sender]);
        if (amount > locked[msg.sender]) revert InsufficientLockedBalance();
        locked[msg.sender] -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Unlocked(msg.sender, amount);
    }

    /// @notice Creates a zero-based proposal ID. Proposing neither votes nor freezes the proposer.
    function propose(address recipient, uint256 amountWei, bytes32 descriptionHash)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (locked[msg.sender] < PROPOSAL_THRESHOLD) revert InsufficientLockedBalance();
        if (recipient == address(0)) revert InvalidRecipient();
        if (amountWei == 0) revert ZeroAmount();
        id = proposalCount++;
        uint256 voteEnd = block.timestamp + VOTING_PERIOD;
        _proposals[id] = Proposal(recipient, amountWei, descriptionHash, msg.sender, voteEnd, 0, 0, false);
        emit Proposed(id, msg.sender, recipient, amountWei, descriptionHash, voteEnd);
    }

    /// @notice Casts one immutable vote per address, using its currently locked balance.
    function vote(uint256 id, bool support) external nonReentrant {
        Proposal storage p = _getProposal(id);
        if (block.timestamp >= p.voteEnd) revert VotingClosed();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        uint256 weight = locked[msg.sender];
        if (weight == 0) revert NoVotingWeight();

        hasVoted[id][msg.sender] = true;
        if (support) p.forVotes += weight;
        else p.againstVotes += weight;
        if (p.voteEnd > lockedUntil[msg.sender]) lockedUntil[msg.sender] = p.voteEnd;
        emit Voted(id, msg.sender, support, weight);
    }

    /// @notice Executes a passed proposal in [voteEnd + 1 day, voteEnd + 15 days).
    /// @dev Failure rolls back the executed flag. ETH is not reserved between proposals.
    function execute(uint256 id) external nonReentrant {
        Proposal storage p = _getProposal(id);
        if (p.executed) revert AlreadyExecuted();
        if (block.timestamp < p.voteEnd + EXECUTION_DELAY) revert ExecutionTooEarly();
        if (block.timestamp >= p.voteEnd + EXECUTION_EXPIRY) revert ProposalExpired();
        if (!_passed(p)) revert ProposalNotPassed();
        if (address(this).balance < p.amount) revert InsufficientETH();

        p.executed = true;
        (bool success,) = p.recipient.call{value: p.amount}("");
        if (!success) revert ETHTransferFailed();
        emit Executed(id, msg.sender, p.recipient, p.amount);
    }

    function proposal(uint256 id)
        external
        view
        returns (
            address recipient,
            uint256 amount,
            bytes32 descriptionHash,
            address proposer,
            uint256 voteEnd,
            uint256 forVotes,
            uint256 againstVotes,
            ProposalState state
        )
    {
        Proposal storage p = _getProposal(id);
        return (p.recipient, p.amount, p.descriptionHash, p.proposer, p.voteEnd, p.forVotes, p.againstVotes, _state(p));
    }

    function _getProposal(uint256 id) private view returns (Proposal storage p) {
        if (id >= proposalCount) revert InvalidProposal();
        return _proposals[id];
    }

    function _passed(Proposal storage p) private view returns (bool) {
        return p.forVotes > p.againstVotes && p.forVotes + p.againstVotes >= QUORUM;
    }

    function _state(Proposal storage p) private view returns (ProposalState) {
        if (p.executed) return ProposalState.Executed;
        if (block.timestamp < p.voteEnd) return ProposalState.Active;
        if (block.timestamp >= p.voteEnd + EXECUTION_EXPIRY) return ProposalState.Expired;
        if (!_passed(p)) return ProposalState.Defeated;
        if (block.timestamp < p.voteEnd + EXECUTION_DELAY) return ProposalState.Queued;
        return ProposalState.Executable;
    }
}
