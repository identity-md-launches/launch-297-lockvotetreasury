// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndFixedSupplyMintedToDeployer() public view {
        assertEq(token.name(), "Lockvote");
        assertEq(token.symbol(), "LVOT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzz_transferConservesSupplyWithoutFees(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromConsumesAllowanceAndCannotOverspend() public {
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 3 ether);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 2 ether));
        assertEq(token.allowance(ALICE, BOB), 1 ether);
        assertEq(token.balanceOf(BOB), 2 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 1 ether, 2 ether));
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 2 ether);
    }

    function test_transferRejectsInsufficientBalanceAndZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_noMintBurnOrAdminSelectorsEvenForDeployer() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            (bool deployerOK,) = address(token).call(data);
            vm.prank(ALICE);
            (bool aliceOK,) = address(token).call(data);
            assertFalse(deployerOK);
            assertFalse(aliceOK);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
