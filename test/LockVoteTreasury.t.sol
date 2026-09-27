// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockVoteTreasury} from "../src/LockVoteTreasury.sol";

contract RetryRecipient {
    bool public rejecting = true;
    uint256 public calls;

    function allowPayment() external {
        rejecting = false;
    }

    receive() external payable {
        require(!rejecting, "recipient rejected");
        ++calls;
    }
}

contract ReentrantRecipient {
    LockVoteTreasury private immutable treasury;
    uint256 private proposalId;
    uint256 public attempts;
    uint256 public payments;

    constructor(LockVoteTreasury treasury_) {
        treasury = treasury_;
    }

    function setProposal(uint256 id) external {
        proposalId = id;
    }

    receive() external payable {
        ++payments;
        // The guard must reject every state-changing entry point, including receive().
        _attempt(abi.encodeCall(treasury.execute, (proposalId)));
        _attempt(abi.encodeCall(treasury.execute, (proposalId + 1)));
        _attempt(abi.encodeCall(treasury.lock, (1)));
        _attempt(abi.encodeCall(treasury.unlock, (1)));
        _attempt(abi.encodeCall(treasury.propose, (address(this), 1, bytes32(0))));
        _attempt(abi.encodeCall(treasury.vote, (proposalId, true)));
        _attempt(abi.encodeCall(treasury.donate, ()));
        _attempt("");
    }

    function _attempt(bytes memory data) private {
        (bool ok, bytes memory reason) = address(treasury).call(data);
        require(!ok, "reentrant mutation succeeded");
        require(
            keccak256(reason)
                == keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)),
            "wrong rejection"
        );
        ++attempts;
    }
}

contract LockVoteTreasuryTest is Test {
    LaunchToken internal token;
    LockVoteTreasury internal treasury;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant RECIPIENT = address(0xBEEF);
    uint256 internal constant THRESHOLD = 100_000 ether;
    uint256 internal constant QUORUM = 1_000_000 ether;
    bytes32 internal constant DESCRIPTION = keccak256("Sepolia test donation");

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        treasury = new LockVoteTreasury(address(token));
        token.transfer(ALICE, 10_000_000 ether);
        token.transfer(BOB, 10_000_000 ether);
        token.transfer(CAROL, 10_000_000 ether);
        vm.deal(address(this), 100 ether);
    }

    function _lock(address holder, uint256 amount) internal {
        vm.startPrank(holder);
        token.approve(address(treasury), amount);
        treasury.lock(amount);
        vm.stopPrank();
    }

    function _propose(address recipient, uint256 amount) internal returns (uint256 id) {
        vm.prank(ALICE);
        return treasury.propose(recipient, amount, DESCRIPTION);
    }

    function _passing(address recipient, uint256 amount) internal returns (uint256 id, uint256 end) {
        _lock(ALICE, QUORUM);
        id = _propose(recipient, amount);
        vm.prank(ALICE);
        treasury.vote(id, true);
        end = _end(id);
    }

    function _end(uint256 id) internal view returns (uint256 end) {
        (,,,, end,,,) = treasury.proposal(id);
    }

    function _state(uint256 id) internal view returns (LockVoteTreasury.ProposalState state) {
        (,,,,,,, state) = treasury.proposal(id);
    }

    function _assertTallies(uint256 id, uint256 yes, uint256 no) internal view {
        (,,,,, uint256 forVotes, uint256 againstVotes,) = treasury.proposal(id);
        assertEq(forVotes, yes);
        assertEq(againstVotes, no);
    }

    function test_constructorFullyConfiguredAndDoesNotMoveSupply() public view {
        assertEq(address(treasury.token()), address(token));
        assertEq(token.balanceOf(address(treasury)), 0);
        assertEq(address(treasury).balance, 0);
        assertEq(token.totalSupply(), 1e27);
        assertEq(treasury.proposalCount(), 0);
    }

    function test_constructorRejectsMissingTokenCode() public {
        vm.expectRevert(LockVoteTreasury.InvalidToken.selector);
        new LockVoteTreasury(address(0));
        vm.expectRevert(LockVoteTreasury.InvalidToken.selector);
        new LockVoteTreasury(ALICE);
    }

    function test_receiveAndDonateEmitEventsAndAccumulateETH() public {
        vm.expectEmit(true, false, false, true, address(treasury));
        emit LockVoteTreasury.Donated(address(this), 2 ether);
        treasury.donate{value: 2 ether}();
        vm.expectEmit(true, false, false, true, address(treasury));
        emit LockVoteTreasury.Donated(address(this), 3 ether);
        (bool ok,) = address(treasury).call{value: 3 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 5 ether);
        (ok,) = address(treasury).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok);
        assertEq(address(treasury).balance, 5 ether);
    }

    function testFuzz_lockAndPartialUnlockConserveTokens(uint256 amount, uint256 returned) public {
        amount = bound(amount, 1, token.balanceOf(ALICE));
        returned = bound(returned, 1, amount);
        uint256 before = token.balanceOf(ALICE);
        vm.prank(ALICE);
        token.approve(address(treasury), amount);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit LockVoteTreasury.Locked(ALICE, amount);
        vm.prank(ALICE);
        treasury.lock(amount);
        assertEq(treasury.locked(ALICE), amount);
        assertEq(token.balanceOf(address(treasury)), amount);
        assertEq(token.balanceOf(ALICE), before - amount);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit LockVoteTreasury.Unlocked(ALICE, returned);
        vm.prank(ALICE);
        treasury.unlock(returned);
        assertEq(treasury.locked(ALICE), amount - returned);
        assertEq(token.balanceOf(address(treasury)), amount - returned);
        assertEq(token.balanceOf(ALICE), before - amount + returned);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_invalidLocksAndUnlocksDoNotChangeCustody() public {
        vm.expectRevert(LockVoteTreasury.ZeroAmount.selector);
        treasury.lock(0);
        vm.expectRevert(LockVoteTreasury.ZeroAmount.selector);
        treasury.unlock(0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(treasury), 0, 1)
        );
        vm.prank(ALICE);
        treasury.lock(1);
        _lock(ALICE, 10 ether);
        vm.expectRevert(LockVoteTreasury.InsufficientLockedBalance.selector);
        vm.prank(ALICE);
        treasury.unlock(10 ether + 1);
        vm.expectRevert(LockVoteTreasury.InsufficientLockedBalance.selector);
        vm.prank(BOB);
        treasury.unlock(1);
        assertEq(treasury.locked(ALICE), 10 ether);
        assertEq(token.balanceOf(address(treasury)), 10 ether);
    }

    function test_proposalThresholdAndFields() public {
        _lock(ALICE, THRESHOLD - 1);
        vm.expectRevert(LockVoteTreasury.InsufficientLockedBalance.selector);
        _propose(RECIPIENT, 1 ether);
        _lock(ALICE, 1);
        uint256 end = block.timestamp + 3 days;
        vm.expectEmit(true, true, true, true, address(treasury));
        emit LockVoteTreasury.Proposed(0, ALICE, RECIPIENT, 1 ether, DESCRIPTION, end);
        uint256 id = _propose(RECIPIENT, 1 ether);
        assertEq(id, 0);
        assertEq(treasury.proposalCount(), 1);
        (
            address recipient,
            uint256 amount,
            bytes32 descriptionHash,
            address proposer,
            uint256 voteEnd,
            uint256 yes,
            uint256 no,
            LockVoteTreasury.ProposalState state
        ) = treasury.proposal(id);
        assertEq(recipient, RECIPIENT);
        assertEq(amount, 1 ether);
        assertEq(descriptionHash, DESCRIPTION);
        assertEq(proposer, ALICE);
        assertEq(voteEnd, end);
        assertEq(yes + no, 0);
        assertEq(uint256(state), uint256(LockVoteTreasury.ProposalState.Active));
        // Proposing alone is not voting and does not freeze LVOT.
        assertEq(treasury.lockedUntil(ALICE), 0);
        vm.prank(ALICE);
        treasury.unlock(THRESHOLD);
    }

    function test_invalidProposalArgumentsAndIdsRevert() public {
        _lock(ALICE, THRESHOLD);
        vm.expectRevert(LockVoteTreasury.InvalidRecipient.selector);
        _propose(address(0), 1 ether);
        vm.expectRevert(LockVoteTreasury.ZeroAmount.selector);
        _propose(RECIPIENT, 0);
        vm.expectRevert(LockVoteTreasury.InvalidProposal.selector);
        treasury.proposal(0);
        vm.expectRevert(LockVoteTreasury.InvalidProposal.selector);
        treasury.vote(0, true);
        vm.expectRevert(LockVoteTreasury.InvalidProposal.selector);
        treasury.execute(0);
        assertEq(treasury.proposalCount(), 0);
    }

    function test_voteRejectsZeroWeightAndDuplicateOrChangedVote() public {
        _lock(ALICE, THRESHOLD);
        uint256 id = _propose(RECIPIENT, 1 ether);
        vm.expectRevert(LockVoteTreasury.NoVotingWeight.selector);
        vm.prank(BOB);
        treasury.vote(id, true);
        assertFalse(treasury.hasVoted(id, BOB));
        vm.expectEmit(true, true, false, true, address(treasury));
        emit LockVoteTreasury.Voted(id, ALICE, true, THRESHOLD);
        vm.prank(ALICE);
        treasury.vote(id, true);
        vm.expectRevert(LockVoteTreasury.AlreadyVoted.selector);
        vm.prank(ALICE);
        treasury.vote(id, true);
        vm.expectRevert(LockVoteTreasury.AlreadyVoted.selector);
        vm.prank(ALICE);
        treasury.vote(id, false);
        _assertTallies(id, THRESHOLD, 0);
    }

    function test_voteWeightIsSnapshotAndAdditionalLocksCannotVoteAgain() public {
        _lock(ALICE, THRESHOLD);
        uint256 id = _propose(RECIPIENT, 1 ether);
        vm.prank(ALICE);
        treasury.vote(id, true);
        _lock(ALICE, QUORUM);
        assertEq(treasury.locked(ALICE), THRESHOLD + QUORUM);
        _assertTallies(id, THRESHOLD, 0);
        vm.expectRevert(LockVoteTreasury.AlreadyVoted.selector);
        vm.prank(ALICE);
        treasury.vote(id, true);
        vm.expectRevert(abi.encodeWithSelector(LockVoteTreasury.TokensStillLocked.selector, _end(id)));
        vm.prank(ALICE);
        treasury.unlock(QUORUM);
        vm.warp(_end(id));
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Defeated));
    }

    function test_unlockTransferRelockCannotReuseVotesWhileOpenOrAfterClose() public {
        (uint256 id, uint256 end) = _passing(RECIPIENT, 1 ether);
        vm.warp(end - 1);
        vm.expectRevert(abi.encodeWithSelector(LockVoteTreasury.TokensStillLocked.selector, end));
        vm.prank(ALICE);
        treasury.unlock(QUORUM);
        vm.warp(end);
        vm.startPrank(ALICE);
        treasury.unlock(QUORUM);
        token.transfer(BOB, QUORUM);
        vm.stopPrank();
        _lock(BOB, QUORUM);
        vm.expectRevert(LockVoteTreasury.VotingClosed.selector);
        vm.prank(BOB);
        treasury.vote(id, true);
        _assertTallies(id, QUORUM, 0);
        assertEq(token.balanceOf(address(treasury)), treasury.locked(BOB));
    }

    function test_lockDeadlineIsMaximumAcrossOverlappingVotesIncludingOpposition() public {
        _lock(ALICE, QUORUM);
        uint256 first = _propose(RECIPIENT, 1 ether);
        uint256 firstEnd = _end(first);
        vm.warp(block.timestamp + 1 days);
        uint256 second = _propose(RECIPIENT, 1 ether);
        uint256 secondEnd = _end(second);
        vm.startPrank(ALICE);
        treasury.vote(second, false);
        treasury.vote(first, true);
        vm.stopPrank();
        assertEq(treasury.lockedUntil(ALICE), secondEnd);
        vm.warp(firstEnd);
        vm.expectRevert(abi.encodeWithSelector(LockVoteTreasury.TokensStillLocked.selector, secondEnd));
        vm.prank(ALICE);
        treasury.unlock(1);
        vm.warp(secondEnd);
        vm.prank(ALICE);
        treasury.unlock(QUORUM);
        assertEq(treasury.locked(ALICE), 0);
    }

    function test_voteEndBoundaryAndExecutionDelayBoundary() public {
        (uint256 id, uint256 end) = _passing(RECIPIENT, 1 ether);
        treasury.donate{value: 1 ether}();
        _lock(BOB, 1);
        vm.warp(end - 1);
        vm.prank(BOB);
        treasury.vote(id, false);
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Active));
        vm.expectRevert(LockVoteTreasury.ExecutionTooEarly.selector);
        treasury.execute(id);
        vm.warp(end);
        vm.expectRevert(LockVoteTreasury.VotingClosed.selector);
        vm.prank(CAROL);
        treasury.vote(id, true);
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Queued));
        vm.expectRevert(LockVoteTreasury.ExecutionTooEarly.selector);
        treasury.execute(id);
        vm.warp(end + 1 days - 1);
        vm.expectRevert(LockVoteTreasury.ExecutionTooEarly.selector);
        treasury.execute(id);
        vm.warp(end + 1 days);
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Executable));
        vm.expectEmit(true, true, true, true, address(treasury));
        emit LockVoteTreasury.Executed(id, CAROL, RECIPIENT, 1 ether);
        vm.prank(CAROL);
        treasury.execute(id);
        assertEq(RECIPIENT.balance, 1 ether);
        assertEq(address(treasury).balance, 0);
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Executed));
    }

    function test_exactQuorumPassesWithoutOpposition() public {
        (uint256 id, uint256 end) = _passing(RECIPIENT, 1 ether);
        _assertTallies(id, QUORUM, 0);
        treasury.donate{value: 1 ether}();
        vm.warp(end + 1 days);
        treasury.execute(id);
        assertEq(RECIPIENT.balance, 1 ether);
    }

    function test_oneUnitBelowQuorumFails() public {
        _lock(ALICE, QUORUM - 1);
        uint256 id = _propose(RECIPIENT, 1 ether);
        vm.prank(ALICE);
        treasury.vote(id, true);
        vm.warp(_end(id) + 1 days);
        treasury.donate{value: 1 ether}();
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Defeated));
        vm.expectRevert(LockVoteTreasury.ProposalNotPassed.selector);
        treasury.execute(id);
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_tieFailsAtQuorum() public {
        _lock(ALICE, QUORUM / 2);
        _lock(BOB, QUORUM / 2);
        uint256 id = _propose(RECIPIENT, 1 ether);
        vm.prank(ALICE);
        treasury.vote(id, true);
        vm.prank(BOB);
        treasury.vote(id, false);
        _assertTallies(id, QUORUM / 2, QUORUM / 2);
        treasury.donate{value: 1 ether}();
        vm.warp(_end(id) + 1 days);
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Defeated));
        vm.expectRevert(LockVoteTreasury.ProposalNotPassed.selector);
        treasury.execute(id);
        assertEq(RECIPIENT.balance, 0);
    }

    function test_oppositionCountsTowardQuorumAndNarrowMajorityPasses() public {
        _lock(ALICE, QUORUM / 2 + 1);
        _lock(BOB, QUORUM / 2 - 1);
        uint256 id = _propose(RECIPIENT, 1 ether);
        vm.prank(ALICE);
        treasury.vote(id, true);
        vm.prank(BOB);
        treasury.vote(id, false);
        treasury.donate{value: 1 ether}();
        vm.warp(_end(id) + 1 days);
        treasury.execute(id);
        assertEq(RECIPIENT.balance, 1 ether);
    }

    function test_expiryBoundaryAndLastExecutableSecond() public {
        (uint256 first, uint256 end) = _passing(RECIPIENT, 1 ether);
        uint256 second = _propose(RECIPIENT, 1 ether);
        vm.prank(ALICE);
        treasury.vote(second, true);
        treasury.donate{value: 2 ether}();
        vm.warp(end + 15 days - 1);
        treasury.execute(first);
        vm.warp(end + 15 days);
        assertEq(uint256(_state(first)), uint256(LockVoteTreasury.ProposalState.Executed));
        assertEq(uint256(_state(second)), uint256(LockVoteTreasury.ProposalState.Expired));
        vm.expectRevert(LockVoteTreasury.ProposalExpired.selector);
        treasury.execute(second);
        vm.warp(end + 100 days);
        vm.expectRevert(LockVoteTreasury.ProposalExpired.selector);
        treasury.execute(second);
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_unvotedAndDefeatedProposalsEventuallyExpire() public {
        _lock(ALICE, QUORUM);
        uint256 id = _propose(RECIPIENT, 1 ether);
        vm.warp(_end(id));
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Defeated));
        vm.warp(_end(id) + 15 days);
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Expired));
    }

    function test_executeAtMostOnceEvenAfterMoreFunding() public {
        (uint256 id, uint256 end) = _passing(RECIPIENT, 1 ether);
        treasury.donate{value: 2 ether}();
        vm.warp(end + 1 days);
        treasury.execute(id);
        vm.expectRevert(LockVoteTreasury.AlreadyExecuted.selector);
        treasury.execute(id);
        assertEq(RECIPIENT.balance, 1 ether);
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_failedRecipientRollsBackAndCanRetryWithinWindow() public {
        RetryRecipient recipient = new RetryRecipient();
        (uint256 id, uint256 end) = _passing(address(recipient), 1 ether);
        treasury.donate{value: 2 ether}();
        vm.warp(end + 1 days);
        vm.expectRevert(LockVoteTreasury.ETHTransferFailed.selector);
        treasury.execute(id);
        assertEq(uint256(_state(id)), uint256(LockVoteTreasury.ProposalState.Executable));
        assertEq(address(treasury).balance, 2 ether);
        assertEq(address(recipient).balance, 0);
        recipient.allowPayment();
        treasury.execute(id);
        assertEq(address(treasury).balance, 1 ether);
        assertEq(address(recipient).balance, 1 ether);
        assertEq(recipient.calls(), 1);
    }

    function test_failedRecipientDoesNotBlockOtherProposalsAndCannotRetryAfterExpiry() public {
        RetryRecipient recipient = new RetryRecipient();
        (uint256 first, uint256 end) = _passing(address(recipient), 1 ether);
        uint256 second = _propose(RECIPIENT, 1 ether);
        vm.prank(ALICE);
        treasury.vote(second, true);
        treasury.donate{value: 2 ether}();
        vm.warp(end + 1 days);
        vm.expectRevert(LockVoteTreasury.ETHTransferFailed.selector);
        treasury.execute(first);
        treasury.execute(second);
        assertEq(RECIPIENT.balance, 1 ether);
        vm.warp(end + 15 days);
        recipient.allowPayment();
        vm.expectRevert(LockVoteTreasury.ProposalExpired.selector);
        treasury.execute(first);
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_competingPassedProposalsUseFirstComeFundingWithoutReservingETH() public {
        (uint256 first, uint256 end) = _passing(RECIPIENT, 2 ether);
        uint256 second = _propose(BOB, 3 ether);
        vm.prank(ALICE);
        treasury.vote(second, true);
        vm.warp(end + 1 days);
        vm.expectRevert(LockVoteTreasury.InsufficientETH.selector);
        treasury.execute(first);
        treasury.donate{value: 3 ether}();
        treasury.execute(second);
        vm.expectRevert(LockVoteTreasury.InsufficientETH.selector);
        treasury.execute(first);
        assertEq(uint256(_state(first)), uint256(LockVoteTreasury.ProposalState.Executable));
        treasury.donate{value: 2 ether}();
        treasury.execute(first);
        assertEq(RECIPIENT.balance + BOB.balance, 5 ether);
        assertEq(address(treasury).balance, 0);
        assertEq(token.balanceOf(address(treasury)), QUORUM);
        vm.prank(ALICE);
        treasury.unlock(QUORUM);
        assertEq(token.balanceOf(address(treasury)), 0);
    }

    function test_recipientCannotReenterAnyMutationOrExecuteAnotherProposal() public {
        ReentrantRecipient recipient = new ReentrantRecipient(treasury);
        (uint256 first, uint256 end) = _passing(address(recipient), 1 ether);
        uint256 second = _propose(RECIPIENT, 1 ether);
        vm.prank(ALICE);
        treasury.vote(second, true);
        recipient.setProposal(first);
        treasury.donate{value: 3 ether}();
        vm.warp(end + 1 days);
        treasury.execute(first);
        assertEq(recipient.attempts(), 8);
        assertEq(recipient.payments(), 1);
        assertEq(address(recipient).balance, 1 ether);
        assertEq(address(treasury).balance, 2 ether);
        assertEq(uint256(_state(second)), uint256(LockVoteTreasury.ProposalState.Executable));
        treasury.execute(second);
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_unsolicitedTokensAreNotVotesAndCannotBeWithdrawnAsLocks() public {
        _lock(ALICE, THRESHOLD);
        token.transfer(address(treasury), 1 ether);
        assertEq(token.balanceOf(address(treasury)), THRESHOLD + 1 ether);
        assertEq(treasury.locked(address(this)), 0);
        vm.expectRevert(LockVoteTreasury.InsufficientLockedBalance.selector);
        treasury.unlock(1 ether);
        uint256 id = _propose(RECIPIENT, 1 ether);
        vm.expectRevert(LockVoteTreasury.NoVotingWeight.selector);
        treasury.vote(id, true);
        vm.prank(ALICE);
        treasury.unlock(THRESHOLD);
        assertEq(token.balanceOf(address(treasury)), 1 ether);
    }
}
