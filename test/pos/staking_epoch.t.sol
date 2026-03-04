// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {QIKToken} from "contracts/pos/QIKToken.sol";
import {ValidatorRegistry} from "contracts/pos/ValidatorRegistry.sol";
import {StakeManager} from "contracts/pos/StakeManager.sol";
import {EpochManager} from "contracts/pos/EpochManager.sol";

contract PosStakingEpochTest is Test {
    QIKToken internal token;
    ValidatorRegistry internal registry;
    StakeManager internal stakeManager;
    EpochManager internal epochManager;

    address internal owner = address(0xA11CE);
    address internal operator = address(0xB0B);

    uint256 internal constant MIN_STAKE = 1000e18;
    uint256 internal constant UNBONDING_BLOCKS = 10;
    uint256 internal constant EPOCH_LENGTH_BLOCKS = 20;

    function setUp() public {
        vm.startPrank(owner);
        token = new QIKToken(owner);
        registry = new ValidatorRegistry();
        stakeManager = new StakeManager(address(token), address(registry), UNBONDING_BLOCKS, MIN_STAKE);
        epochManager = new EpochManager(owner, EPOCH_LENGTH_BLOCKS);
        vm.stopPrank();

        vm.prank(owner);
        token.mint(operator, 10_000e18);

        vm.prank(operator);
        registry.registerValidator(hex"01020304", hex"aabbccdd", "op1", "http://validator-1:8545");
    }

    function testStakeAndUnstakeFlow() public {
        uint256 stakeAmount = 3_000e18;

        vm.startPrank(operator);
        token.approve(address(stakeManager), stakeAmount);
        stakeManager.stake(stakeAmount);

        assertEq(stakeManager.stakeOf(operator), stakeAmount);
        assertEq(stakeManager.totalStaked(), stakeAmount);

        uint256 unstakeAmount = 1_000e18;
        stakeManager.beginUnstake(unstakeAmount);
        vm.stopPrank();

        (uint256 pendingAmount, uint256 unlockBlock, bool withdrawn) = stakeManager.pendingWithdrawals(operator, 0);
        assertEq(pendingAmount, unstakeAmount);
        assertEq(unlockBlock, block.number + UNBONDING_BLOCKS);
        assertFalse(withdrawn);

        vm.roll(block.number + UNBONDING_BLOCKS + 1);

        uint256 preBalance = token.balanceOf(operator);
        vm.prank(operator);
        stakeManager.withdraw(0);

        assertEq(token.balanceOf(operator), preBalance + unstakeAmount);
        assertEq(stakeManager.stakeOf(operator), stakeAmount - unstakeAmount);
    }

    function testStakeRequiresRegisteredValidator() public {
        address unregistered = address(0xD00D);
        vm.prank(owner);
        token.mint(unregistered, 2_000e18);

        vm.startPrank(unregistered);
        token.approve(address(stakeManager), 1_000e18);
        vm.expectRevert("validator not registered");
        stakeManager.stake(1_000e18);
        vm.stopPrank();
    }

    function testSnapshotStoresHashAndOperators() public {
        address[] memory operators = new address[](2);
        operators[0] = operator;
        operators[1] = address(0xC0FFEE);

        vm.roll(EPOCH_LENGTH_BLOCKS);

        vm.prank(owner);
        epochManager.snapshotActiveSet(epochManager.currentEpoch(), operators);

        uint256 epoch = epochManager.currentEpoch();
        address[] memory storedOperators = epochManager.getActiveSet(epoch);

        assertEq(storedOperators.length, 2);
        assertEq(storedOperators[0], operators[0]);
        assertEq(storedOperators[1], operators[1]);
        assertEq(epochManager.activeSetHash(epoch), keccak256(abi.encode(operators)));
    }
}
