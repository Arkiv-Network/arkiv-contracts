// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EntityRegistry} from "../src/EntityRegistry.sol";

contract EntityRegistryScript is Script {
    EntityRegistry public registry;

    function run() public {
        uint256 privateKey = vm.envUint("ETH_PRIVATE_KEY");
        console.log("Using deployer", vm.envAddress("ETH_ADDRESS"));

        vm.startBroadcast(privateKey);
        registry = new EntityRegistry();
        vm.stopBroadcast();

        console.log("EntityRegistry deployed", address(registry));
    }
}
