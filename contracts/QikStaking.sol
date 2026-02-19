// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IQikStaking} from "./interfaces/IQikStaking.sol";
import {QikGov} from "./QikGov.sol";

contract QikStaking is IQikStaking, QikGov {
    mapping(address operator => OperatorInfo info) private _operators;
    mapping(address operator => mapping(address staker => uint256 amount)) private _stakes;
    mapping(address operator => mapping(address staker => Unbonding[] entries)) private _unbondings;
    address[] private _registeredOperators;

    uint256 private _minStake;
    uint256 private _maxValidators;
    uint256 private _unbondingPeriod;

    bool private _entered;

    modifier nonReentrant() {
        require(!_entered, "reentrant");
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address admin, uint256 minStake_, uint256 maxValidators_, uint256 unbondingPeriod_) QikGov(admin) {
        require(maxValidators_ > 0, "max=0");
        _minStake = minStake_;
        _maxValidators = maxValidators_;
        _unbondingPeriod = unbondingPeriod_;
    }

    function registerOperator(bytes calldata consensusKey, address payout) external override {
        require(consensusKey.length > 0, "empty key");
        require(payout != address(0), "payout=0");

        OperatorInfo storage info = _operators[msg.sender];
        require(!info.registered, "registered");

        info.operator = msg.sender;
        info.payout = payout;
        info.consensusKey = consensusKey;
        info.registered = true;

        _registeredOperators.push(msg.sender);

        emit OperatorRegistered(msg.sender, consensusKey, payout);
    }

    function updateConsensusKey(bytes calldata newKey) external override {
        require(newKey.length > 0, "empty key");

        OperatorInfo storage info = _operators[msg.sender];
        require(info.registered, "not registered");
        info.consensusKey = newKey;

        emit ConsensusKeyUpdated(msg.sender, newKey);
    }

    function updatePayout(address newPayout) external override {
        require(newPayout != address(0), "payout=0");

        OperatorInfo storage info = _operators[msg.sender];
        require(info.registered, "not registered");
        info.payout = newPayout;

        emit PayoutUpdated(msg.sender, newPayout);
    }

    function stake(address operator) external payable override {
        _stakeFor(operator, msg.sender);
    }

    function stakeFor(address operator, address staker) external payable override {
        _stakeFor(operator, staker);
    }

    function _stakeFor(address operator, address staker) internal {
        require(msg.value > 0, "amount=0");
        require(staker != address(0), "staker=0");

        OperatorInfo storage info = _operators[operator];
        require(info.registered, "operator not registered");

        _stakes[operator][staker] += msg.value;
        info.totalStake += msg.value;

        emit Staked(staker, operator, msg.value);
    }

    function requestUnstake(address operator, uint256 amount) external override {
        require(amount > 0, "amount=0");

        uint256 current = _stakes[operator][msg.sender];
        require(current >= amount, "insufficient stake");

        _stakes[operator][msg.sender] = current - amount;
        _operators[operator].totalStake -= amount;

        uint256 unlockTime = block.timestamp + _unbondingPeriod;
        _unbondings[operator][msg.sender].push(Unbonding({amount: amount, unlockTime: unlockTime}));

        emit UnstakeRequested(msg.sender, operator, amount, unlockTime);
    }

    function withdrawUnstaked(address operator) external override nonReentrant {
        Unbonding[] storage queue = _unbondings[operator][msg.sender];

        uint256 total;
        uint256 i;
        while (i < queue.length) {
            if (queue[i].unlockTime <= block.timestamp) {
                total += queue[i].amount;
                queue[i] = queue[queue.length - 1];
                queue.pop();
            } else {
                i++;
            }
        }

        require(total > 0, "nothing unlocked");

        (bool ok,) = msg.sender.call{value: total}("");
        require(ok, "transfer failed");

        emit UnstakedWithdrawn(msg.sender, operator, total);
    }

    function setJailed(address operator, bool jailed) external override onlyOwner {
        OperatorInfo storage info = _operators[operator];
        require(info.registered, "not registered");
        info.jailed = jailed;

        emit OperatorJailed(operator, jailed);
    }

    function setMinStake(uint256 newMin) external override onlyOwner {
        _minStake = newMin;
        emit ParamsUpdated(keccak256("MIN_STAKE"), newMin);
    }

    function setMaxValidators(uint256 newMax) external override onlyOwner {
        require(newMax > 0, "max=0");
        _maxValidators = newMax;
        emit ParamsUpdated(keccak256("MAX_VALIDATORS"), newMax);
    }

    function setUnbondingPeriod(uint256 seconds_) external override onlyOwner {
        _unbondingPeriod = seconds_;
        emit ParamsUpdated(keccak256("UNBONDING_PERIOD"), seconds_);
    }

    function minStake() external view override returns (uint256) {
        return _minStake;
    }

    function maxValidators() external view override returns (uint256) {
        return _maxValidators;
    }

    function unbondingPeriod() external view override returns (uint256) {
        return _unbondingPeriod;
    }

    function getOperator(address operator) external view override returns (OperatorInfo memory) {
        return _operators[operator];
    }

    function stakeOf(address operator, address staker) external view override returns (uint256) {
        return _stakes[operator][staker];
    }

    function totalStakeOf(address operator) external view override returns (uint256) {
        return _operators[operator].totalStake;
    }

    function getUnbondings(address operator, address staker) external view override returns (Unbonding[] memory) {
        return _unbondings[operator][staker];
    }

    function getActiveOperators() public view override returns (address[] memory) {
        address[] memory temp = new address[](_registeredOperators.length);
        uint256 count;

        for (uint256 i = 0; i < _registeredOperators.length; i++) {
            address operator = _registeredOperators[i];
            OperatorInfo storage info = _operators[operator];

            if (info.registered && !info.jailed && info.totalStake >= _minStake) {
                temp[count++] = operator;
            }
        }

        for (uint256 i = 1; i < count; i++) {
            address key = temp[i];
            uint256 j = i;
            while (j > 0 && _comesBefore(key, temp[j - 1])) {
                temp[j] = temp[j - 1];
                j--;
            }
            temp[j] = key;
        }

        uint256 limit = count > _maxValidators ? _maxValidators : count;
        address[] memory selected = new address[](limit);
        for (uint256 i = 0; i < limit; i++) {
            selected[i] = temp[i];
        }

        return selected;
    }

    function getActiveConsensusKeys() external view override returns (bytes[] memory) {
        address[] memory operators = getActiveOperators();
        bytes[] memory keys = new bytes[](operators.length);

        for (uint256 i = 0; i < operators.length; i++) {
            keys[i] = _operators[operators[i]].consensusKey;
        }

        return keys;
    }

    function isActiveOperator(address operator) external view override returns (bool) {
        OperatorInfo storage info = _operators[operator];
        if (!info.registered || info.jailed || info.totalStake < _minStake) {
            return false;
        }

        address[] memory active = getActiveOperators();
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] == operator) {
                return true;
            }
        }

        return false;
    }

    function _comesBefore(address a, address b) internal view returns (bool) {
        uint256 stakeA = _operators[a].totalStake;
        uint256 stakeB = _operators[b].totalStake;

        if (stakeA > stakeB) {
            return true;
        }
        if (stakeA < stakeB) {
            return false;
        }

        return a < b;
    }
}
