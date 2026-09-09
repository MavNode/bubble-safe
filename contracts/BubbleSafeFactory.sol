// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from
    "@openzeppelin/contracts/proxy/Clones.sol";

import {BubbleSafe} from
    "./BubbleSafe.sol";

contract BubbleSafeFactory {
    using Clones for address;

    address public immutable implementation;

    /// @notice Emitted after a wallet is deployed and successfully initialized.
    /// @dev Frontends discover wallets from this factory's events, not a storage registry.
    event BubbleSafeCreated(
        address indexed safe,
        address indexed creator,
        string name,
        address[] owners,
        uint256 threshold
    );

    constructor() {
        implementation =
            address(new BubbleSafe());
    }

    function createBubbleSafe(
        string calldata name,
        address[] calldata owners,
        uint256 threshold
    )
        external
        returns (address safe)
    {
        safe = implementation.clone();

        BubbleSafe(payable(safe)).initialize(
            name,
            owners,
            threshold
        );

        emit BubbleSafeCreated(
            safe,
            msg.sender,
            name,
            owners,
            threshold
        );
    }
}
