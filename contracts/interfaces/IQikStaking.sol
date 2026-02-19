// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IQikStaking {
    struct OperatorInfo {
        address operator;
        address payout;
        bytes consensusKey;
        uint256 totalStake;
        bool registered;
        bool jailed;
    }

    struct Unbonding {
        uint256 amount;
        uint256 unlockTime;
    }

    function registerOperator(bytes calldata consensusKey, address payout) external;

    function updateConsensusKey(bytes calldata newKey) external;

    function updatePayout(address newPayout) external;

    function stake(address operator) external payable;

    function stakeFor(address operator, address staker) external payable;

    function requestUnstake(address operator, uint256 amount) external;

    function withdrawUnstaked(address operator) external;

    function setJailed(address operator, bool jailed) external;

    function setMinStake(uint256 newMin) external;

    function setMaxValidators(uint256 newMax) external;

    function setUnbondingPeriod(uint256 seconds_) external;

    function minStake() external view returns (uint256);

    function maxValidators() external view returns (uint256);

    function unbondingPeriod() external view returns (uint256);

    function getOperator(address operator) external view returns (OperatorInfo memory);

    function stakeOf(address operator, address staker) external view returns (uint256);

    function totalStakeOf(address operator) external view returns (uint256);

    function getUnbondings(address operator, address staker) external view returns (Unbonding[] memory);

    function getActiveOperators() external view returns (address[] memory);

    function getActiveConsensusKeys() external view returns (bytes[] memory);

    function isActiveOperator(address operator) external view returns (bool);

    event OperatorRegistered(address indexed operator, bytes consensusKey, address payout);
    event ConsensusKeyUpdated(address indexed operator, bytes newKey);
    event PayoutUpdated(address indexed operator, address payout);

    event Staked(address indexed staker, address indexed operator, uint256 amount);
    event UnstakeRequested(address indexed staker, address indexed operator, uint256 amount, uint256 unlockTime);
    event UnstakedWithdrawn(address indexed staker, address indexed operator, uint256 amount);

    event OperatorJailed(address indexed operator, bool jailed);
    event ParamsUpdated(bytes32 indexed param, uint256 value);
}
