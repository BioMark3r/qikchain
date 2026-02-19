// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {QikStaking} from "../contracts/QikStaking.sol";

interface Vm {
    function prank(address) external;
    function deal(address who, uint256 newBalance) external;
    function warp(uint256) external;
    function expectEmit(bool, bool, bool, bool) external;
}

contract StakingTest {
    event OperatorRegistered(address indexed operator, bytes consensusKey, address payout);

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    QikStaking internal staking;
    address internal admin = address(0xA11CE);
    address internal staker = address(0xB0B);

    address internal op1 = address(0x1001);
    address internal op2 = address(0x1002);
    address internal op3 = address(0x1003);

    function setUp() public {
        staking = new QikStaking(admin, 1 ether, 2, 3 days);
        vm.deal(staker, 100 ether);
        vm.deal(op1, 100 ether);
        vm.deal(op2, 100 ether);
        vm.deal(op3, 100 ether);

        vm.prank(op1);
        staking.registerOperator(hex"01", op1);
        vm.prank(op2);
        staking.registerOperator(hex"02", op2);
        vm.prank(op3);
        staking.registerOperator(hex"03", op3);
    }

    function testRegisterOperatorSetsFieldsAndEmits() public {
        address op4 = address(0x1004);
        vm.expectEmit(true, false, false, true);
        emit OperatorRegistered(op4, hex"beef", op4);

        vm.prank(op4);
        staking.registerOperator(hex"beef", op4);

        (address operator, address payout, bytes memory key, uint256 totalStake, bool registered, bool jailed) = staking.getOperator(op4);
        require(operator == op4, "operator mismatch");
        require(payout == op4, "payout mismatch");
        require(keccak256(key) == keccak256(hex"beef"), "key mismatch");
        require(totalStake == 0, "total stake mismatch");
        require(registered, "not registered");
        require(!jailed, "unexpected jailed");
    }

    function testStakeIncreasesBalances() public {
        vm.prank(staker);
        staking.stake{value: 2 ether}(op1);

        require(staking.stakeOf(op1, staker) == 2 ether, "stakeOf wrong");
        require(staking.totalStakeOf(op1) == 2 ether, "total stake wrong");
    }

    function testRequestUnstakeCreatesUnbonding() public {
        vm.prank(staker);
        staking.stake{value: 4 ether}(op1);

        uint256 nowTs = block.timestamp;
        vm.prank(staker);
        staking.requestUnstake(op1, 1 ether);

        require(staking.stakeOf(op1, staker) == 3 ether, "stake not reduced");
        require(staking.totalStakeOf(op1) == 3 ether, "total not reduced");

        QikStaking.Unbonding[] memory unbondings = staking.getUnbondings(op1, staker);
        require(unbondings.length == 1, "missing unbonding");
        require(unbondings[0].amount == 1 ether, "amount wrong");
        require(unbondings[0].unlockTime == nowTs + 3 days, "unlock wrong");
    }

    function testWithdrawUnstakedAfterPeriod() public {
        vm.prank(staker);
        staking.stake{value: 3 ether}(op1);

        vm.prank(staker);
        staking.requestUnstake(op1, 2 ether);

        vm.warp(block.timestamp + 3 days - 1);
        vm.prank(staker);
        (bool ok,) = address(staking).call(abi.encodeWithSelector(staking.withdrawUnstaked.selector, op1));
        require(!ok, "withdraw should fail early");

        uint256 beforeBal = staker.balance;
        vm.warp(block.timestamp + 1);
        vm.prank(staker);
        staking.withdrawUnstaked(op1);

        require(staker.balance == beforeBal + 2 ether, "withdraw amount wrong");
        require(staking.getUnbondings(op1, staker).length == 0, "queue not cleared");
    }

    function testJailedOperatorExcludedFromActiveSet() public {
        vm.prank(op1);
        staking.stake{value: 3 ether}(op1);
        vm.prank(op2);
        staking.stake{value: 2 ether}(op2);

        vm.prank(admin);
        staking.setJailed(op1, true);

        address[] memory active = staking.getActiveOperators();
        require(active.length == 1, "active length wrong");
        require(active[0] == op2, "jailed operator included");
    }

    function testDeterministicTieOrderByAddress() public {
        vm.prank(op1);
        staking.stake{value: 1 ether}(op1);
        vm.prank(op2);
        staking.stake{value: 1 ether}(op2);

        address[] memory active = staking.getActiveOperators();
        require(active.length == 2, "active length wrong");
        require(active[0] < active[1], "not sorted by address on tie");
    }

    function testActiveSetRespectsMaxValidators() public {
        vm.prank(op1);
        staking.stake{value: 5 ether}(op1);
        vm.prank(op2);
        staking.stake{value: 4 ether}(op2);
        vm.prank(op3);
        staking.stake{value: 3 ether}(op3);

        address[] memory active = staking.getActiveOperators();
        require(active.length == 2, "max validator limit ignored");
        require(active[0] == op1 && active[1] == op2, "wrong top operators");
    }
}
