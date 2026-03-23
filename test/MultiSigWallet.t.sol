// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MultiSigWallet} from "../src/MultiSigWallet.sol";
import {TestContract} from "./TestContract.sol";

contract MultiSigWalletTest is Test {
    MultiSigWallet wallet;
    address[] owners;

    address owner1 = makeAddr("owner1");
    address owner2 = makeAddr("owner2");

    TestContract testContract;

    function setUp() public {
        // Deploy the initial implementation
        owners.push(owner1);
        owners.push(owner2);
        wallet = new MultiSigWallet(owners, 2);

        testContract = new TestContract();
    }

    function test_MultiSigSetup() public view {
        // GIVEN + WHEN setup
        // THEN
        address[] memory walletOwners = wallet.getOwners();
        assertEq(walletOwners.length, 2, "unexpected number of owners");
        assertEq(walletOwners[0], owner1, "unexpected owner1");
        assertEq(walletOwners[1], owner2, "unexpected owner2");
        assertEq(wallet.numConfirmationsRequired(), 2, "unexpected numConfirmationsRequired");
        assertEq(wallet.getTransactionCount(), 0, "transaction count > 0");
    }

    function test_MultiSigSubmitTransaction() public {
        // GIVEN
        bytes memory dataIn = testContract.getData();
        uint256 valueIn = 0;

        // WHEN
        vm.startPrank(owner1);
        wallet.submitTransaction(address(testContract), valueIn, dataIn);
        vm.stopPrank();

        // THEN
        assertEq(wallet.getTransactionCount(), 1, "unexpected transaction count");

        (address to, uint256 valueOut, bytes memory dataOut, bool executed, uint256 numConfirmations) =
            wallet.getTransaction(0);

        assertEq(to, address(testContract), "unexpected to");
        assertEq(valueOut, valueIn, "unexpected value");
        assertEq(dataOut, dataIn, "unexpected data");
        assertEq(executed, false, "unexpected executed");
        assertEq(numConfirmations, 0, "unexpected numConfirmations");
    }

    function test_MultiSigConfirmTransaction() public {
        // GIVEN
        bytes memory dataIn = testContract.getData();
        uint256 valueIn = 0;

        vm.startPrank(owner1);
        wallet.submitTransaction(address(testContract), valueIn, dataIn);
        vm.stopPrank();

        // WHEN - onwer1 confirms
        vm.startPrank(owner1);
        wallet.confirmTransaction(0);
        vm.stopPrank();

        // THEN
        (,,,, uint256 numConfirmations) = wallet.getTransaction(0);
        assertEq(numConfirmations, 1, "unexpected numConfirmations (after owner 1)");

        // WHEN - onwer2 confirms
        vm.startPrank(owner2);
        wallet.confirmTransaction(0);
        vm.stopPrank();

        // THEN
        (,,,, numConfirmations) = wallet.getTransaction(0);
        assertEq(numConfirmations, 2, "unexpected numConfirmations (after owner 2)");
    }

    function test_MultiSigExecuteTransaction() public {
        // GIVEN - submit and fully confirm a transaction
        bytes memory dataIn = testContract.getData();

        vm.prank(owner1);
        wallet.submitTransaction(address(testContract), 0, dataIn);

        vm.prank(owner1);
        wallet.confirmTransaction(0);

        vm.prank(owner2);
        wallet.confirmTransaction(0);

        // WHEN
        vm.prank(owner1);
        wallet.executeTransaction(0);

        // THEN
        (,,, bool executed,) = wallet.getTransaction(0);
        assertEq(executed, true, "tx should be executed");
        assertEq(testContract.i(), 123, "testContract.i should be updated");
    }

    function test_MultiSigExecuteTransactionInsufficientConfirmations() public {
        // GIVEN - submit but only one confirmation (need 2)
        bytes memory dataIn = testContract.getData();

        vm.prank(owner1);
        wallet.submitTransaction(address(testContract), 0, dataIn);

        vm.prank(owner1);
        wallet.confirmTransaction(0);

        // WHEN + THEN
        vm.expectRevert("cannot execute tx");

        vm.prank(owner1);
        wallet.executeTransaction(0);
    }

    function test_MultiSigRevokeConfirmation() public {
        // GIVEN - submit and confirm as owner1
        bytes memory dataIn = testContract.getData();

        vm.prank(owner1);
        wallet.submitTransaction(address(testContract), 0, dataIn);

        vm.prank(owner1);
        wallet.confirmTransaction(0);

        (,,,, uint256 numConfirmations) = wallet.getTransaction(0);
        assertEq(numConfirmations, 1, "unexpected numConfirmations (before revoke)");

        // WHEN
        vm.prank(owner1);
        wallet.revokeConfirmation(0);

        // THEN
        (,,,, numConfirmations) = wallet.getTransaction(0);
        assertEq(numConfirmations, 0, "unexpected numConfirmations (after revoke)");
        assertEq(wallet.isConfirmed(0, owner1), false, "owner1 should not be confirmed");
    }
}
