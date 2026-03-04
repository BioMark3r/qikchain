// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, stdJson} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {QIKToken} from "contracts/pos/QIKToken.sol";
import {ValidatorRegistry} from "contracts/pos/ValidatorRegistry.sol";
import {StakeManager} from "contracts/pos/StakeManager.sol";
import {EpochManager} from "contracts/pos/EpochManager.sol";

contract DeployPos is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPk);

        uint256 minStake = vm.envOr("POS_MIN_STAKE", uint256(1000e18));
        uint256 unbondingBlocks = vm.envOr("POS_UNBONDING_BLOCKS", uint256(200));
        uint256 epochLengthBlocks = vm.envOr("POS_EPOCH_LENGTH_BLOCKS", uint256(100));

        vm.startBroadcast(deployerPk);

        QIKToken token = new QIKToken(owner);
        ValidatorRegistry registry = new ValidatorRegistry();
        StakeManager stakeManager = new StakeManager(address(token), address(registry), unbondingBlocks, minStake);
        EpochManager epochManager = new EpochManager(owner, epochLengthBlocks);

        vm.stopBroadcast();

        string memory root = vm.projectRoot();
        string memory dir = string.concat(root, "/.data/pos");
        vm.createDir(dir, true);

        string memory path = vm.envOr("POS_ADDRESSES_FILE", string(".data/pos/addresses.json"));
        string memory json;
        json = vm.serializeAddress("pos", "deployer", owner);
        json = vm.serializeAddress("pos", "token", address(token));
        json = vm.serializeAddress("pos", "validatorRegistry", address(registry));
        json = vm.serializeAddress("pos", "stakeManager", address(stakeManager));
        json = vm.serializeAddress("pos", "epochManager", address(epochManager));
        json = vm.serializeUint("pos", "minStake", minStake);
        json = vm.serializeUint("pos", "unbondingBlocks", unbondingBlocks);
        json = vm.serializeUint("pos", "epochLengthBlocks", epochLengthBlocks);
        vm.writeJson(json, path);

        console2.log("QIKToken", address(token));
        console2.log("ValidatorRegistry", address(registry));
        console2.log("StakeManager", address(stakeManager));
        console2.log("EpochManager", address(epochManager));
        console2.log("addresses file", path);
    }
}
