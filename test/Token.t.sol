// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TokenTestBase} from "./TokenBase.t.sol";

contract TokenTest is TokenTestBase {
    function test_TokenInitialBalance() public {
        assertEq(token.balanceOf(deployer), 1000 * 10 ** token.decimals());
    }

    function test_TokenNameAndSymbol() public {
        assertEq(token.name(), "MyToken");
        assertEq(token.symbol(), "MTK");
    }

    function testFuzz_TokenTransfer(address to, uint256 amount) public {
        // GIVEN
        vm.assume(amount < token.balanceOf(deployer)); // amount must be smaller than deployer balance
        address from = makeAddr("from");

        // ensure proper argument values
        vm.assume(to != address(0)); // token does not allow transfer to address(0)
        vm.assume(to != from); // ensure different accounts (to make intial assertions work)
        vm.assume(to != address(proxyAdmin)); // proxy admin is denied to call any functions from implementation (_defund(proxyAdmin) is prohibited)

        vm.assume(to != deployer); // ensure different accounts (to make intial assertions work)
        vm.assume(from != deployer); // ensure different accounts (to make intial assertions work)

        _defund(to);
        _fund(from, amount + 1);

        assertEq(token.balanceOf(from), amount + 1, "unexpected balance for 'from' account (before)");
        assertEq(token.balanceOf(to), 0, "unexpected balance for 'to' account (before)");

        // WHEN
        vm.startPrank(from);
        require(token.transfer(to, amount), "transfer failed");

        // THEN
        assertEq(token.balanceOf(from), 1, "unexpected balance for 'from' account (after)");
        assertEq(token.balanceOf(to), amount, "unexpected balance for 'to' account (after)");
    }
}
