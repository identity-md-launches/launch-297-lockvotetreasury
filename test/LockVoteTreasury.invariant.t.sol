// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockVoteTreasury} from "../src/LockVoteTreasury.sol";

/// @dev Drives real transfers and calls; ghost accounting is independent of treasury storage.
contract TreasuryHandler is Test {
    LaunchToken public immutable token;
    LockVoteTreasury public immutable treasury;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    mapping(address => uint256) public modelLocked;
    mapping(address => uint256) public modelUntil;
    mapping(uint256 => uint256) public modelFor;
    mapping(uint256 => uint256) public modelAgainst;
    mapping(uint256 => mapping(address => uint256)) public voteWeight;
    mapping(uint256 => uint256) public executionCount;
    uint256 public depositedETH;
    uint256 public paidETH;

    constructor(LaunchToken token_, LockVoteTreasury treasury_) {
        token = token_;
        treasury = treasury_;
    }

    function lock(uint256 who, uint256 amount) external {
        address actor = actors[who % actors.length];
        uint256 available = token.balanceOf(actor);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.startPrank(actor);
        token.approve(address(treasury), amount);
        treasury.lock(amount);
        vm.stopPrank();
        modelLocked[actor] += amount;
    }

    function unlock(uint256 who, uint256 amount) external {
        address actor = actors[who % actors.length];
        uint256 available = modelLocked[actor];
        if (available == 0) return;
        amount = bound(amount, 1, available);
        if (block.timestamp < modelUntil[actor]) {
            vm.expectRevert(abi.encodeWithSelector(LockVoteTreasury.TokensStillLocked.selector, modelUntil[actor]));
            vm.prank(actor);
            treasury.unlock(amount);
            return;
        }
        vm.prank(actor);
        treasury.unlock(amount);
        modelLocked[actor] -= amount;
    }

    function transfer(uint256 from, uint256 to, uint256 amount) external {
        address actor = actors[from % actors.length];
        amount = bound(amount, 0, token.balanceOf(actor));
        vm.prank(actor);
        token.transfer(actors[to % actors.length], amount);
    }

    function propose(uint256 who, uint256 recipient, uint256 amount) external {
        address actor = actors[who % actors.length];
        if (modelLocked[actor] < 100_000 ether || treasury.proposalCount() >= 32) return;
        amount = bound(amount, 1, 5 ether);
        vm.prank(actor);
        treasury.propose(actors[recipient % actors.length], amount, keccak256(abi.encode(who, amount)));
    }

    function vote(uint256 who, uint256 id, bool support) external {
        uint256 count = treasury.proposalCount();
        if (count == 0) return;
        id %= count;
        address actor = actors[who % actors.length];
        (,,,, uint256 end,,,) = treasury.proposal(id);
        if (block.timestamp >= end || modelLocked[actor] == 0) return;
        if (voteWeight[id][actor] != 0) {
            vm.expectRevert(LockVoteTreasury.AlreadyVoted.selector);
            vm.prank(actor);
            treasury.vote(id, support);
            return;
        }
        vm.prank(actor);
        treasury.vote(id, support);
        uint256 weight = modelLocked[actor];
        voteWeight[id][actor] = weight;
        if (support) modelFor[id] += weight;
        else modelAgainst[id] += weight;
        if (end > modelUntil[actor]) modelUntil[actor] = end;
    }

    function donate(uint256 amount, bool direct) external {
        amount = bound(amount, 0, 5 ether);
        if (direct) {
            (bool ok,) = address(treasury).call{value: amount}("");
            require(ok, "donation failed");
        } else {
            treasury.donate{value: amount}();
        }
        depositedETH += amount;
    }

    function execute(uint256 id, uint256 who) external {
        uint256 count = treasury.proposalCount();
        if (count == 0) return;
        id %= count;
        (, uint256 amount,,, uint256 end,,,) = treasury.proposal(id);
        bool shouldSucceed = executionCount[id] == 0 && block.timestamp >= end + 1 days
            && block.timestamp < end + 15 days && modelFor[id] > modelAgainst[id]
            && modelFor[id] + modelAgainst[id] >= 1_000_000 ether && address(treasury).balance >= amount;
        vm.prank(actors[who % actors.length]);
        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.execute, (id)));
        assertEq(ok, shouldSucceed, "execution differs from independent model");
        if (ok) {
            ++executionCount[id];
            paidETH += amount;
        }
    }

    function elapse(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 2 days));
    }
}

contract LockVoteTreasuryInvariantTest is StdInvariant, Test {
    LaunchToken internal token;
    LockVoteTreasury internal treasury;
    TreasuryHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        treasury = new LockVoteTreasury(address(token));
        handler = new TreasuryHandler(token, treasury);
        vm.deal(address(handler), 1_000 ether);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), 5_000_000 ether);
            // Start with enough voters and a proposal so campaigns exercise execution as well as custody.
            handler.lock(i, 1_500_000 ether);
        }
        handler.propose(0, 1, 1 ether);
        handler.vote(0, 0, true);
        handler.donate(3 ether, false);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.lock.selector;
        selectors[1] = handler.unlock.selector;
        selectors[2] = handler.transfer.selector;
        selectors[3] = handler.propose.selector;
        selectors[4] = handler.vote.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.execute.selector;
        selectors[7] = handler.elapse.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_tokenCustodyEqualsSumOfLocksAndSupplyIsConserved() public view {
        uint256 locks;
        uint256 liquid = token.balanceOf(address(this));
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(treasury.locked(actor), handler.modelLocked(actor));
            assertEq(treasury.lockedUntil(actor), handler.modelUntil(actor));
            locks += treasury.locked(actor);
            liquid += token.balanceOf(actor);
        }
        assertEq(token.balanceOf(address(treasury)), locks);
        assertEq(locks + liquid, 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function invariant_ETHLeavesOnlyForExecutedProposalsAtMostOnce() public view {
        uint256 paid;
        uint256 recipientsBalance;
        for (uint256 i; i < 4; ++i) {
            recipientsBalance += handler.actors(i).balance;
        }
        for (uint256 id; id < treasury.proposalCount(); ++id) {
            (, uint256 amount,,,,,, LockVoteTreasury.ProposalState state) = treasury.proposal(id);
            uint256 executions = handler.executionCount(id);
            assertLe(executions, 1);
            assertEq(state == LockVoteTreasury.ProposalState.Executed, executions == 1);
            if (executions == 1) paid += amount;
        }
        assertEq(paid, handler.paidETH());
        assertEq(recipientsBalance, paid);
        assertEq(address(treasury).balance + paid, handler.depositedETH());
    }

    function invariant_voteTalliesAreImmutableSnapshotsCountedOnce() public view {
        for (uint256 id; id < treasury.proposalCount(); ++id) {
            (,,,,, uint256 yes, uint256 no,) = treasury.proposal(id);
            assertEq(yes, handler.modelFor(id));
            assertEq(no, handler.modelAgainst(id));
            uint256 recordedWeight;
            for (uint256 i; i < 4; ++i) {
                address actor = handler.actors(i);
                uint256 weight = handler.voteWeight(id, actor);
                assertEq(treasury.hasVoted(id, actor), weight != 0);
                recordedWeight += weight;
            }
            assertEq(yes + no, recordedWeight);
            assertLe(recordedWeight, 20_000_000 ether);
        }
    }
}
