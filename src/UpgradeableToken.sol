// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract UpgradeableToken is Initializable, ERC20Upgradeable {
    // REMARK when adding contract state follow namespace storage layout pattern.
    // Example: ERC20Storage in ERC20Upgradeable.

    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name, string memory symbol, address fundsOwner) public initializer {
        __ERC20_init(name, symbol);
        _mint(fundsOwner, 1000 * 10 ** decimals());
    }
}
