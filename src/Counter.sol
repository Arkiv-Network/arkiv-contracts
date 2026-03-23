// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Counter {
    uint256 public number;

    event NumberIncremented(uint256 indexed newNumber);
    event NumberUpdated(uint256 indexed newNumber, uint256 oldNumber);

    function setNumber(uint256 newNumber) public {
        uint256 oldNumber = number;
        number = newNumber;

        emit NumberUpdated(newNumber, oldNumber);
    }

    function increment() public {
        number++;

        emit NumberIncremented(number);
    }
}
