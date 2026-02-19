// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IQikValidatorSet {
    function validatorCount() external view returns (uint256);

    function getValidators() external view returns (address[] memory);

    function getValidatorKeys() external view returns (bytes[] memory);

    function getValidatorAt(uint256 idx) external view returns (address operator, bytes memory consensusKey);

    function isValidator(address operator) external view returns (bool);
}
