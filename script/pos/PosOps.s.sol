// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {QIKToken} from "contracts/pos/QIKToken.sol";
import {ValidatorRegistry} from "contracts/pos/ValidatorRegistry.sol";
import {StakeManager} from "contracts/pos/StakeManager.sol";
import {EpochManager} from "contracts/pos/EpochManager.sol";

contract PosOps is Script {
    function runMint() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address tokenAddr = vm.envAddress("POS_TOKEN");
        address to = vm.envAddress("MINT_TO");
        uint256 amount = vm.envUint("MINT_AMOUNT");

        vm.startBroadcast(pk);
        QIKToken(tokenAddr).mint(to, amount);
        vm.stopBroadcast();
    }

    function runRegister() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address registryAddr = vm.envAddress("POS_VALIDATOR_REGISTRY");

        bytes memory blsPubkey = vm.parseBytes(vm.envString("BLS_PUBKEY_HEX"));
        bytes memory nodeId = vm.parseBytes(vm.envString("NODE_ID_HEX"));
        string memory moniker = vm.envString("MONIKER");
        string memory endpoint = vm.envString("ENDPOINT");

        vm.startBroadcast(pk);
        ValidatorRegistry(registryAddr).registerValidator(blsPubkey, nodeId, moniker, endpoint);
        vm.stopBroadcast();
    }

    function runStake() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address tokenAddr = vm.envAddress("POS_TOKEN");
        address stakeManagerAddr = vm.envAddress("POS_STAKE_MANAGER");
        uint256 amount = vm.envUint("STAKE_AMOUNT");

        vm.startBroadcast(pk);
        QIKToken(tokenAddr).approve(stakeManagerAddr, amount);
        StakeManager(stakeManagerAddr).stake(amount);
        vm.stopBroadcast();
    }

    function runUnstake() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address stakeManagerAddr = vm.envAddress("POS_STAKE_MANAGER");
        uint256 amount = vm.envUint("UNSTAKE_AMOUNT");

        vm.startBroadcast(pk);
        StakeManager(stakeManagerAddr).beginUnstake(amount);
        vm.stopBroadcast();
    }

    function runWithdraw() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address stakeManagerAddr = vm.envAddress("POS_STAKE_MANAGER");
        uint256 withdrawalId = vm.envUint("WITHDRAWAL_ID");

        vm.startBroadcast(pk);
        StakeManager(stakeManagerAddr).withdraw(withdrawalId);
        vm.stopBroadcast();
    }

    function runSnapshot() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address epochManagerAddr = vm.envAddress("POS_EPOCH_MANAGER");
        uint256 epoch = vm.envUint("SNAPSHOT_EPOCH");
        string memory operatorsCsv = vm.envString("OPERATORS");
        address[] memory operators = _parseOperators(operatorsCsv);

        vm.startBroadcast(pk);
        EpochManager(epochManagerAddr).snapshotActiveSet(epoch, operators);
        vm.stopBroadcast();
    }

    function _parseOperators(string memory operatorsCsv) internal pure returns (address[] memory) {
        bytes memory data = bytes(operatorsCsv);
        uint256 count = 1;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == 0x2c) {
                count++;
            }
        }

        address[] memory operators = new address[](count);
        uint256 start = 0;
        uint256 index = 0;

        for (uint256 i = 0; i <= data.length; i++) {
            if (i == data.length || data[i] == 0x2c) {
                bytes memory slice = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    slice[j - start] = data[j];
                }
                operators[index] = _parseAddress(string(slice));
                index++;
                start = i + 1;
            }
        }

        return operators;
    }

    function _parseAddress(string memory value) internal pure returns (address) {
        bytes memory strBytes = bytes(value);
        require(strBytes.length == 42, "invalid address length");

        require(strBytes[0] == 0x30 && (strBytes[1] == 0x78 || strBytes[1] == 0x58), "address must start with 0x");

        uint160 result = 0;
        for (uint256 i = 2; i < 42; i++) {
            result *= 16;
            uint8 b = uint8(strBytes[i]);
            if (b >= 48 && b <= 57) {
                result += b - 48;
            } else if (b >= 65 && b <= 70) {
                result += b - 55;
            } else if (b >= 97 && b <= 102) {
                result += b - 87;
            } else {
                revert("invalid address character");
            }
        }

        return address(result);
    }
}
