// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract EpochManager is Ownable {
    uint256 public immutable EPOCH_LENGTH_BLOCKS;

    mapping(uint256 epoch => address[] operators) private _activeSet;
    mapping(uint256 epoch => bytes32 hash) public activeSetHash;

    event ActiveSetSnapshotted(uint256 indexed epoch, bytes32 activeSetHash, uint256 operatorCount);

    constructor(address initialOwner, uint256 epochLengthBlocks_) Ownable(initialOwner) {
        require(epochLengthBlocks_ > 0, "epoch length is zero");
        EPOCH_LENGTH_BLOCKS = epochLengthBlocks_;
    }

    function currentEpoch() public view returns (uint256) {
        return epochAtBlock(block.number);
    }

    function epochAtBlock(uint256 blockNum) public view returns (uint256) {
        return blockNum / EPOCH_LENGTH_BLOCKS;
    }

    function isEpochBoundary(uint256 blockNum) public view returns (bool) {
        return blockNum % EPOCH_LENGTH_BLOCKS == 0;
    }

    /// @dev Future: derive set from StakeManager + deterministic sort by stake/address.
    function snapshotActiveSet(uint256 epoch, address[] calldata operators) external onlyOwner {
        require(epoch == currentEpoch(), "epoch must equal current epoch");
        require(isEpochBoundary(block.number), "snapshot requires epoch boundary");
        require(operators.length > 0, "operators required");

        delete _activeSet[epoch];
        for (uint256 i = 0; i < operators.length; i++) {
            require(operators[i] != address(0), "zero operator");
            _activeSet[epoch].push(operators[i]);
        }

        bytes32 hash = keccak256(abi.encode(operators));
        activeSetHash[epoch] = hash;

        emit ActiveSetSnapshotted(epoch, hash, operators.length);
    }

    function getActiveSet(uint256 epoch) external view returns (address[] memory) {
        return _activeSet[epoch];
    }
}
