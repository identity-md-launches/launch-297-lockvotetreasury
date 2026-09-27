// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockVoteTreasury} from "../src/LockVoteTreasury.sol";

/// @dev A local deployment harness, not the production ProjectFactory or an authorization simulation.
contract FactoryHarness {
    function deploy() external returns (LaunchToken token, LockVoteTreasury treasury) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        treasury = new LockVoteTreasury{salt: bytes32(uint256(2))}(address(token));
    }
}

contract DeploymentCompatibilityTest is Test {
    function test_factoryConstructionPreservesAllLaunchSupplyAndRuntimeRestrictions() public {
        FactoryHarness factory = new FactoryHarness();
        (LaunchToken token, LockVoteTreasury treasury) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(treasury)), 0);
        assertEq(address(treasury.token()), address(token));
        _checkRuntime(address(token).code);
        _checkRuntime(address(treasury).code);
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
