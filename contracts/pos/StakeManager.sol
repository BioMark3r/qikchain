// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IValidatorRegistry {
    function isRegistered(address operator) external view returns (bool);
}

contract StakeManager is ReentrancyGuard {
    struct PendingWithdrawal {
        uint256 amount;
        uint256 unlockBlock;
        bool withdrawn;
    }

    IERC20 public immutable stakingToken;
    IValidatorRegistry public immutable validatorRegistry;
    uint256 public immutable UNBONDING_BLOCKS;
    uint256 public immutable minStake;

    mapping(address operator => uint256 stakeAmount) public stakeOf;
    uint256 public totalStaked;

    mapping(address operator => uint256 count) public withdrawalCount;
    mapping(address operator => mapping(uint256 withdrawalId => PendingWithdrawal pending)) public pendingWithdrawals;

    event Staked(address indexed operator, uint256 amount, uint256 newStake);
    event UnstakeStarted(address indexed operator, uint256 amount, uint256 unlockBlock, uint256 withdrawalId);
    event Withdrawn(address indexed operator, uint256 amount, uint256 withdrawalId);

    constructor(address token_, address validatorRegistry_, uint256 unbondingBlocks_, uint256 minStake_) {
        require(token_ != address(0), "token is zero");
        require(validatorRegistry_ != address(0), "validator registry is zero");
        stakingToken = IERC20(token_);
        validatorRegistry = IValidatorRegistry(validatorRegistry_);
        UNBONDING_BLOCKS = unbondingBlocks_;
        minStake = minStake_;
    }

    function stake(uint256 amount) external {
        require(validatorRegistry.isRegistered(msg.sender), "validator not registered");
        require(amount > 0, "stake amount is zero");

        bool success = stakingToken.transferFrom(msg.sender, address(this), amount);
        require(success, "stake transfer failed");

        uint256 newStake = stakeOf[msg.sender] + amount;
        stakeOf[msg.sender] = newStake;
        totalStaked += amount;

        emit Staked(msg.sender, amount, newStake);
    }

    function beginUnstake(uint256 amount) external {
        require(amount > 0, "unstake amount is zero");

        uint256 currentStake = stakeOf[msg.sender];
        require(currentStake >= amount, "insufficient stake");

        uint256 newStake = currentStake - amount;
        require(newStake == 0 || newStake >= minStake, "remaining stake below min");

        stakeOf[msg.sender] = newStake;
        totalStaked -= amount;

        uint256 withdrawalId = withdrawalCount[msg.sender];
        withdrawalCount[msg.sender] = withdrawalId + 1;

        uint256 unlockBlock = block.number + UNBONDING_BLOCKS;
        pendingWithdrawals[msg.sender][withdrawalId] = PendingWithdrawal({
            amount: amount,
            unlockBlock: unlockBlock,
            withdrawn: false
        });

        emit UnstakeStarted(msg.sender, amount, unlockBlock, withdrawalId);
    }

    function withdraw(uint256 withdrawalId) external nonReentrant {
        PendingWithdrawal storage pending = pendingWithdrawals[msg.sender][withdrawalId];
        require(!pending.withdrawn, "already withdrawn");
        require(pending.amount > 0, "withdrawal not found");
        require(block.number >= pending.unlockBlock, "withdrawal still locked");

        pending.withdrawn = true;
        bool success = stakingToken.transfer(msg.sender, pending.amount);
        require(success, "withdraw transfer failed");

        emit Withdrawn(msg.sender, pending.amount, withdrawalId);
    }
}
