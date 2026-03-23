// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";

contract MultiSigWalletScript is Script {
    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("ETH_PRIVATE_KEY");
        address deployer = vm.envAddress("ETH_ADDRESS");
        console.log("Using deployer", deployer);

        // Build owners list and confirmation threshold from env, defaulting to
        // a single-owner wallet requiring 1 confirmation.
        address[] memory owners = new address[](1);
        owners[0] = deployer;
        uint256 numConfirmationsRequired = 1;

        vm.startBroadcast(privateKey);
        MultiSigWallet wallet = new MultiSigWallet(owners, numConfirmationsRequired);
        vm.stopBroadcast();

        console.log("MultiSigWallet deployed", address(wallet));
        console.log("Owners:", owners.length);
        console.log("Confirmations required:", numConfirmationsRequired);
    }
}
