// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpgradeableToken} from "../src/UpgradeableToken.sol";

contract TokenV2 is UpgradeableToken {
    // Namespace storage layout
    struct V2Storage {
        string _message;
    }

    // keccak256(abi.encode(uint256(keccak256("foundry-base.storage.V2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant V2_STORAGE_LOCATION = 0x79f293f4d15abebddad769280bece7705fd560fe90cd08a1964c06d945367b00;

    function _getV2Storage() private pure returns (V2Storage storage $) {
        assembly {
            $.slot := V2_STORAGE_LOCATION
        }
    }

    /// @dev Initialize the contract (new deploymnent)
    function initialize(string memory name, string memory symbol, address initialFundsOwner, string memory _message)
        public
        initializer
    {
        super.initialize(name, symbol, initialFundsOwner);
        _setMessage(_message);
    }

    /// @dev Upgrade the contract (for existing token deployments)
    function initializeMessage(string memory _message) public reinitializer(2) {
        _setMessage(_message);
    }

    function message() public view returns (string memory) {
        return _getV2Storage()._message;
    }

    function _setMessage(string memory _message) internal {
        _getV2Storage()._message = _message;
    }
}
