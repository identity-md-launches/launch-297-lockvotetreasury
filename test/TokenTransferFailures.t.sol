// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LockVoteTreasury} from "../src/LockVoteTreasury.sol";

/// @dev Deliberately hostile test token; production must use LaunchToken.
contract HostileToken is ERC20 {
    bool public returnFalse;
    bool public reenter;
    uint256 public rejectedCallbacks;

    constructor() ERC20("Test only", "TEST") {
        _mint(msg.sender, 100 ether);
    }

    function configure(bool falseReturn, bool callback) external {
        returnFalse = falseReturn;
        reenter = callback;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        if (reenter) _callback(msg.sender);
        return !returnFalse;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (reenter) _callback(msg.sender);
        return !returnFalse;
    }

    function _callback(address treasury) private {
        (bool ok, bytes memory reason) = treasury.call(abi.encodeCall(LockVoteTreasury.unlock, (1)));
        require(!ok, "callback succeeded");
        require(
            keccak256(reason)
                == keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)),
            "wrong callback rejection"
        );
        ++rejectedCallbacks;
    }
}

contract TokenTransferFailuresTest is Test {
    HostileToken internal token;
    LockVoteTreasury internal treasury;

    function setUp() public {
        token = new HostileToken();
        treasury = new LockVoteTreasury(address(token));
        token.approve(address(treasury), 100 ether);
    }

    function test_falseTransferFromRollsBackTokenMovementAllowanceAndCredit() public {
        token.configure(true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        treasury.lock(10 ether);
        assertEq(treasury.locked(address(this)), 0);
        assertEq(token.balanceOf(address(treasury)), 0);
        assertEq(token.balanceOf(address(this)), 100 ether);
        assertEq(token.allowance(address(this), address(treasury)), 100 ether);
    }

    function test_falseTransferRestoresLockAndCanBeRetried() public {
        treasury.lock(10 ether);
        token.configure(true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        treasury.unlock(10 ether);
        assertEq(treasury.locked(address(this)), 10 ether);
        assertEq(token.balanceOf(address(treasury)), 10 ether);
        assertEq(token.balanceOf(address(this)), 90 ether);
        token.configure(false, false);
        treasury.unlock(10 ether);
        assertEq(treasury.locked(address(this)), 0);
        assertEq(token.balanceOf(address(this)), 100 ether);
    }

    function test_guardAlsoBlocksTokenCallbacksDuringLockAndUnlock() public {
        token.configure(false, true);
        treasury.lock(10 ether);
        treasury.unlock(10 ether);
        assertEq(token.rejectedCallbacks(), 2);
        assertEq(treasury.locked(address(this)), 0);
        assertEq(token.balanceOf(address(this)), 100 ether);
        assertEq(token.balanceOf(address(treasury)), 0);
    }
}
