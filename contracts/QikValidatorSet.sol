// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IQikStaking} from "./interfaces/IQikStaking.sol";
import {IQikValidatorSet} from "./interfaces/IQikValidatorSet.sol";

contract QikValidatorSet is IQikValidatorSet {
    IQikStaking public immutable staking;

    constructor(address staking_) {
        require(staking_ != address(0), "staking=0");
        staking = IQikStaking(staking_);
    }

    function validatorCount() external view override returns (uint256) {
        return staking.getActiveOperators().length;
    }

    function getValidators() external view override returns (address[] memory) {
        return staking.getActiveOperators();
    }

    function getValidatorKeys() external view override returns (bytes[] memory) {
        return staking.getActiveConsensusKeys();
    }

    function getValidatorAt(uint256 idx) external view override returns (address operator, bytes memory consensusKey) {
        address[] memory operators = staking.getActiveOperators();
        require(idx < operators.length, "idx oob");

        operator = operators[idx];
        consensusKey = staking.getOperator(operator).consensusKey;
    }

    function isValidator(address operator) external view override returns (bool) {
        return staking.isActiveOperator(operator);
    }
}
