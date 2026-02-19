// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IQikGov {
    function owner() external view returns (address);

    function transferOwnership(address newOwner) external;

    function requireOwner() external view;
}
