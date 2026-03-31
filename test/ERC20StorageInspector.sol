// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract ERC20StorageInspector is Initializable, ERC20Upgradeable {
    ERC20Upgradeable.ERC20Storage public erc20Storage;
    Initializable.InitializableStorage public initializableStorage;
}
