// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Test.sol";

import {Token} from "../src/Token.sol";
import {UpgradeableToken} from "../src/UpgradeableToken.sol";

contract UpgradeableTokenScript is Script {
    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("ETH_PRIVATE_KEY");
        address deployer = vm.envAddress("ETH_ADDRESS");
        console.log("Using deployer", deployer);

        // Setup token initialization data
        bytes memory data = abi.encodeWithSignature("initialize(string,string,address)", "MyToken", "MTK", deployer);

        // Deploy tokens
        vm.startBroadcast(privateKey);

        Token simpleToken = new Token();
        UpgradeableToken implementation = new UpgradeableToken();

        vm.recordLogs();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), deployer, data);

        vm.stopBroadcast();

        // Obtain proxy admin and token
        Vm.Log[] memory logs = vm.getRecordedLogs();
        ProxyAdmin proxyAdmin = _getProxyAdmin(logs);
        UpgradeableToken token = UpgradeableToken(address(proxy));
        string memory tokenAddress = vm.toString(address(token));

        console.log("Simple Token", address(simpleToken));
        console.log("UpgradeableToken (proxy)", tokenAddress);
        console.log("ProxyAdmin", address(proxyAdmin));
        console.log("ProxyAdmin owner", proxyAdmin.owner());
    }

    function _getProxyAdmin(Vm.Log[] memory logs) internal pure returns (ProxyAdmin admin) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IERC1967.AdminChanged.selector) {
                (, address adminAddress) = abi.decode(logs[i].data, (address, address));
                return ProxyAdmin(adminAddress);
            }
        }
    }
}
