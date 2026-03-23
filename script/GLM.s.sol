// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GlmToken} from "../src/GLM.sol";

contract GLMScript is Script {
    GlmToken public glm;

    function run() public {
        uint256 privateKey = vm.envUint("ETH_PRIVATE_KEY");
        console.log("Using deployer", vm.envAddress("ETH_ADDRESS"));

        vm.startBroadcast(privateKey);
        glm = new GlmToken();
        vm.stopBroadcast();

        console.log("GLM deployed", address(glm));
    }
}
