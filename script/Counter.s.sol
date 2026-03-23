// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Counter} from "../src/Counter.sol";

contract CounterScript is Script {
    Counter public counter;

    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("ETH_PRIVATE_KEY");
        console.log("Using deployer", vm.envAddress("ETH_ADDRESS"));

        vm.startBroadcast(privateKey);
        counter = new Counter();
        vm.stopBroadcast();

        console.log("Counter deployed", address(counter));
    }
}
