// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract ValidatorRegistry {
    struct Validator {
        address operator;
        bytes blsPubkey;
        bytes nodeId;
        string moniker;
        string endpoint;
        uint256 registeredAtBlock;
        bool exists;
    }

    mapping(address operator => Validator validator) private _validators;

    event ValidatorRegistered(address indexed operator, bytes nodeId, string moniker, string endpoint);
    event ValidatorUpdated(address indexed operator, bytes nodeId, string moniker, string endpoint);

    function registerValidator(
        bytes calldata blsPubkey,
        bytes calldata nodeId,
        string calldata moniker,
        string calldata endpoint
    ) external {
        require(!_validators[msg.sender].exists, "validator already registered");
        require(blsPubkey.length > 0, "bls pubkey required");
        require(nodeId.length > 0, "node id required");

        _validators[msg.sender] = Validator({
            operator: msg.sender,
            blsPubkey: blsPubkey,
            nodeId: nodeId,
            moniker: moniker,
            endpoint: endpoint,
            registeredAtBlock: block.number,
            exists: true
        });

        emit ValidatorRegistered(msg.sender, nodeId, moniker, endpoint);
    }

    function updateValidator(
        bytes calldata nodeId,
        string calldata moniker,
        string calldata endpoint
    ) external {
        Validator storage validator = _validators[msg.sender];
        require(validator.exists, "validator not registered");
        require(nodeId.length > 0, "node id required");

        validator.nodeId = nodeId;
        validator.moniker = moniker;
        validator.endpoint = endpoint;

        emit ValidatorUpdated(msg.sender, nodeId, moniker, endpoint);
    }

    function isRegistered(address operator) external view returns (bool) {
        return _validators[operator].exists;
    }

    function getValidator(address operator) external view returns (Validator memory) {
        require(_validators[operator].exists, "validator not registered");
        return _validators[operator];
    }
}
