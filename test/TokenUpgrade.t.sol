// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {TokenV2} from "./TokenV2.sol";
import {TokenTestBase} from "./TokenBase.t.sol";

contract TokenUpgradeTest is TokenTestBase {
    function test_TokenUpgradeHappyCase() public {
        // GIVEN
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(payable(address(token)));
        address newImplementation = address(new TokenV2());
        string memory message = "Hello, World!";
        bytes memory data = abi.encodeWithSelector(TokenV2.initializeMessage.selector, message);

        // WHEN
        vm.startPrank(deployer);
        proxyAdmin.upgradeAndCall(proxy, newImplementation, data);
        vm.stopPrank();

        // THEN
        TokenV2 tokenV2 = TokenV2(address(token));
        assertEq(tokenV2.message(), message, "unexpected message");
    }

    function test_TokenUpgradeTwice() public {
        // GIVEN
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(payable(address(token)));
        address newImplementation = address(new TokenV2());
        string memory message = "Hello, World!";
        bytes memory data = abi.encodeWithSelector(TokenV2.initializeMessage.selector, message);

        vm.startPrank(deployer);
        proxyAdmin.upgradeAndCall(proxy, newImplementation, data);
        vm.stopPrank();

        // WHEN + THEN (upgrade again)
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));

        vm.startPrank(deployer);
        proxyAdmin.upgradeAndCall(proxy, newImplementation, data);
        vm.stopPrank();
    }

    function test_TokenUpgradeTokenNotTokenV2() public {
        TokenV2 tokenV2 = TokenV2(address(token));

        vm.expectRevert();
        tokenV2.message();
    }

    function test_TokenUpgradeTokenNotProxyAdminOwner() public {
        // GIVEN
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(payable(address(token)));
        address newImplementation = address(new TokenV2());
        string memory message = "Hello, World!";
        bytes memory data = abi.encodeWithSelector(TokenV2.initializeMessage.selector, message);
        address outsider = makeAddr("outsider");

        // WHEN + THEN
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));

        vm.startPrank(outsider);
        proxyAdmin.upgradeAndCall(proxy, newImplementation, data);
        vm.stopPrank();
    }
}
