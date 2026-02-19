// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IQikGov} from "./interfaces/IQikGov.sol";

contract QikGov is IQikGov {
    address public override owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        requireOwner();
        _;
    }

    constructor(address initialOwner) {
        require(initialOwner != address(0), "owner=0");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function transferOwnership(address newOwner) external override onlyOwner {
        require(newOwner != address(0), "owner=0");
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    function requireOwner() public view override {
        require(msg.sender == owner, "not owner");
    }
}
