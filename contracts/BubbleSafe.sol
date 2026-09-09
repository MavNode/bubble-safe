// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from
    "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BubbleSafe {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_OWNERS = 50;
    uint256 public constant MAX_NAME_LENGTH = 128;

    bool private _initialized;
    uint256 private _executionLock;

    string public name;

    address[] private _owners;
    mapping(address => uint256) private _ownerIndexPlusOne;

    uint256 public threshold;
    uint256 public transactionCount;
    uint256 public ownerEpoch;

    struct Transaction {
        address target;
        uint256 value;
        bytes data;
        uint256 approvals;
        uint256 epoch;
        bool executed;
        uint256 expiresAt;
    }

    mapping(uint256 => Transaction) private _transactions;
    mapping(uint256 => mapping(address => bool)) public approved;

    error AlreadyInitialized();
    error NotInitialized();
    error Unauthorized();
    error InvalidName();
    error InvalidOwner();
    error DuplicateOwner();
    error OwnerNotFound();
    error TooManyOwners();
    error InvalidThreshold();
    error InvalidTarget();
    error InvalidExpiration();
    error InvalidRecipient();
    error TransactionNotFound();
    error TransactionAlreadyExecuted();
    error TransactionInvalidated();
    error TransactionExpired();
    error AlreadyApproved();
    error NotApproved();
    error InsufficientApprovals();
    error ExecutionFailed();
    error Reentrancy();

    event Initialized(
        string name,
        address[] owners,
        uint256 threshold
    );

    event Deposit(
        address indexed sender,
        uint256 amount,
        uint256 balance
    );

    event TransactionSubmitted(
        uint256 indexed transactionId,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 epoch,
        uint256 expiresAt
    );

    event TransactionApproved(
        uint256 indexed transactionId,
        address indexed owner,
        uint256 approvals
    );

    event ApprovalRevoked(
        uint256 indexed transactionId,
        address indexed owner,
        uint256 approvals
    );

    event TransactionExecuted(
        uint256 indexed transactionId,
        address indexed executor,
        bytes returnData
    );

    event OwnerAdded(
        address indexed owner
    );

    event OwnerRemoved(
        address indexed owner
    );

    event OwnerReplaced(
        address indexed oldOwner,
        address indexed newOwner
    );

    event ThresholdChanged(
        uint256 previousThreshold,
        uint256 newThreshold
    );

    event PendingTransactionsInvalidated(
        uint256 indexed newEpoch
    );

    modifier onlyOwner() {
        if (_ownerIndexPlusOne[msg.sender] == 0) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert Unauthorized();
        }
        _;
    }

    modifier transactionExists(uint256 transactionId) {
        if (transactionId >= transactionCount) {
            revert TransactionNotFound();
        }
        _;
    }

    modifier activeTransaction(uint256 transactionId) {
        Transaction storage txn = _transactions[transactionId];

        if (txn.executed) {
            revert TransactionAlreadyExecuted();
        }

        if (txn.epoch != ownerEpoch) {
            revert TransactionInvalidated();
        }

        if (block.timestamp >= txn.expiresAt) {
            revert TransactionExpired();
        }

        _;
    }

    modifier nonReentrantExecution() {
        if (_executionLock != 0) {
            revert Reentrancy();
        }

        _executionLock = 1;
        _;

        _executionLock = 0;
    }

    constructor() {
        _initialized = true;
    }

    function initialize(
        string calldata name_,
        address[] calldata owners_,
        uint256 threshold_
    )
        external
    {
        if (_initialized) {
            revert AlreadyInitialized();
        }

        _initialized = true;

        uint256 nameLength = bytes(name_).length;
        uint256 initialOwnerCount = owners_.length;

        if (
            nameLength == 0 ||
            nameLength > MAX_NAME_LENGTH
        ) {
            revert InvalidName();
        }

        if (initialOwnerCount == 0) {
            revert InvalidOwner();
        }

        if (initialOwnerCount > MAX_OWNERS) {
            revert TooManyOwners();
        }

        if (
            threshold_ == 0 ||
            threshold_ > initialOwnerCount
        ) {
            revert InvalidThreshold();
        }

        name = name_;
        threshold = threshold_;

        for (uint256 i = 0; i < initialOwnerCount; ++i) {
            address owner = owners_[i];

            if (
                owner == address(0) ||
                owner == address(this)
            ) {
                revert InvalidOwner();
            }

            if (_ownerIndexPlusOne[owner] != 0) {
                revert DuplicateOwner();
            }

            _owners.push(owner);
            _ownerIndexPlusOne[owner] = i + 1;
        }

        emit Initialized(
            name_,
            owners_,
            threshold_
        );
    }

    receive() external payable {
        emit Deposit(
            msg.sender,
            msg.value,
            address(this).balance
        );
    }

    /// @notice Proposes a native-currency transfer or arbitrary contract call.
    /// @dev expiresAt is a Unix timestamp in seconds and must be in the future.
    /// Arbitrary return data is not interpreted; use submitERC20Transfer for tokens.
    function submitTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 expiresAt
    )
        external
        onlyOwner
        returns (uint256 transactionId)
    {
        return _submitTransaction(
            target,
            value,
            data,
            expiresAt
        );
    }

    /// @notice Proposes an ERC-20 transfer with checked token return data.
    /// @dev Uses the same approval, expiration and execution flow as other proposals.
    function submitERC20Transfer(
        address token,
        address recipient,
        uint256 amount,
        uint256 expiresAt
    )
        external
        onlyOwner
        returns (uint256 transactionId)
    {
        if (token.code.length == 0) {
            revert InvalidTarget();
        }

        if (recipient == address(0)) {
            revert InvalidRecipient();
        }

        return _submitTransaction(
            address(this),
            0,
            abi.encodeCall(
                this.transferERC20,
                (token, recipient, amount)
            ),
            expiresAt
        );
    }

    /// @dev Only callable through an approved wallet self-call. SafeERC20 rejects
    /// false returns and supports tokens that return no data. Failure reverts the
    /// outer execution too, leaving the proposal unexecuted and retryable until expiry.
    function transferERC20(
        address token,
        address recipient,
        uint256 amount
    )
        external
        onlySelf
    {
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }

        IERC20(token).safeTransfer(recipient, amount);
    }

    function _submitTransaction(
        address target,
        uint256 value,
        bytes memory data,
        uint256 expiresAt
    )
        private
        returns (uint256 transactionId)
    {
        if (target == address(0)) {
            revert InvalidTarget();
        }

        if (expiresAt <= block.timestamp) {
            revert InvalidExpiration();
        }

        transactionId = transactionCount;
        transactionCount = transactionId + 1;

        Transaction storage txn =
            _transactions[transactionId];

        txn.target = target;
        txn.value = value;
        txn.data = data;
        txn.epoch = ownerEpoch;
        txn.expiresAt = expiresAt;

        emit TransactionSubmitted(
            transactionId,
            msg.sender,
            target,
            value,
            data,
            ownerEpoch,
            expiresAt
        );
    }

    function approveTransaction(
        uint256 transactionId
    )
        external
        onlyOwner
        transactionExists(transactionId)
        activeTransaction(transactionId)
    {
        if (approved[transactionId][msg.sender]) {
            revert AlreadyApproved();
        }

        approved[transactionId][msg.sender] = true;

        Transaction storage txn =
            _transactions[transactionId];

        txn.approvals += 1;

        emit TransactionApproved(
            transactionId,
            msg.sender,
            txn.approvals
        );
    }

    function revokeApproval(
        uint256 transactionId
    )
        external
        onlyOwner
        transactionExists(transactionId)
        activeTransaction(transactionId)
    {
        if (!approved[transactionId][msg.sender]) {
            revert NotApproved();
        }

        approved[transactionId][msg.sender] = false;

        Transaction storage txn =
            _transactions[transactionId];

        txn.approvals -= 1;

        emit ApprovalRevoked(
            transactionId,
            msg.sender,
            txn.approvals
        );
    }

    function executeTransaction(
        uint256 transactionId
    )
        external
        onlyOwner
        transactionExists(transactionId)
        activeTransaction(transactionId)
        nonReentrantExecution
        returns (bytes memory returnData)
    {
        Transaction storage txn =
            _transactions[transactionId];

        if (txn.approvals < threshold) {
            revert InsufficientApprovals();
        }

        txn.executed = true;

        bool success;

        (success, returnData) =
            txn.target.call{value: txn.value}(txn.data);

        if (!success) {
            if (returnData.length != 0) {
                assembly ("memory-safe") {
                    revert(
                        add(returnData, 0x20),
                        mload(returnData)
                    )
                }
            }

            revert ExecutionFailed();
        }

        emit TransactionExecuted(
            transactionId,
            msg.sender,
            returnData
        );
    }

    function addOwner(
        address newOwner
    )
        external
        onlySelf
    {
        if (
            newOwner == address(0) ||
            newOwner == address(this)
        ) {
            revert InvalidOwner();
        }

        if (_ownerIndexPlusOne[newOwner] != 0) {
            revert DuplicateOwner();
        }

        if (_owners.length >= MAX_OWNERS) {
            revert TooManyOwners();
        }

        _owners.push(newOwner);
        _ownerIndexPlusOne[newOwner] =
            _owners.length;

        emit OwnerAdded(newOwner);

        _invalidatePendingTransactions();
    }

    function removeOwner(
        address owner
    )
        external
        onlySelf
    {
        uint256 indexPlusOne =
            _ownerIndexPlusOne[owner];

        if (indexPlusOne == 0) {
            revert OwnerNotFound();
        }

        uint256 newOwnerCount =
            _owners.length - 1;

        if (
            newOwnerCount == 0 ||
            threshold > newOwnerCount
        ) {
            revert InvalidThreshold();
        }

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _owners.length - 1;

        if (index != lastIndex) {
            address lastOwner =
                _owners[lastIndex];

            _owners[index] = lastOwner;
            _ownerIndexPlusOne[lastOwner] =
                index + 1;
        }

        _owners.pop();
        delete _ownerIndexPlusOne[owner];

        emit OwnerRemoved(owner);

        _invalidatePendingTransactions();
    }

    function replaceOwner(
        address oldOwner,
        address newOwner
    )
        external
        onlySelf
    {
        uint256 indexPlusOne =
            _ownerIndexPlusOne[oldOwner];

        if (indexPlusOne == 0) {
            revert OwnerNotFound();
        }

        if (
            newOwner == address(0) ||
            newOwner == address(this)
        ) {
            revert InvalidOwner();
        }

        if (_ownerIndexPlusOne[newOwner] != 0) {
            revert DuplicateOwner();
        }

        uint256 index = indexPlusOne - 1;

        _owners[index] = newOwner;

        delete _ownerIndexPlusOne[oldOwner];
        _ownerIndexPlusOne[newOwner] =
            index + 1;

        emit OwnerReplaced(
            oldOwner,
            newOwner
        );

        _invalidatePendingTransactions();
    }

    function changeThreshold(
        uint256 newThreshold
    )
        external
        onlySelf
    {
        if (
            newThreshold == 0 ||
            newThreshold > _owners.length ||
            newThreshold == threshold
        ) {
            revert InvalidThreshold();
        }

        uint256 previousThreshold = threshold;
        threshold = newThreshold;

        emit ThresholdChanged(
            previousThreshold,
            newThreshold
        );

        _invalidatePendingTransactions();
    }

    function invalidatePendingTransactions()
        external
        onlySelf
    {
        _invalidatePendingTransactions();
    }

    function getOwners()
        external
        view
        returns (address[] memory)
    {
        return _owners;
    }

    function ownerCount()
        external
        view
        returns (uint256)
    {
        return _owners.length;
    }

    function isOwner(
        address account
    )
        external
        view
        returns (bool)
    {
        return _ownerIndexPlusOne[account] != 0;
    }

    function getTransaction(
        uint256 transactionId
    )
        external
        view
        transactionExists(transactionId)
        returns (
            address target,
            uint256 value,
            bytes memory data,
            uint256 approvals,
            uint256 epoch,
            bool executed,
            bool active,
            uint256 expiresAt
        )
    {
        Transaction storage txn =
            _transactions[transactionId];

        return (
            txn.target,
            txn.value,
            txn.data,
            txn.approvals,
            txn.epoch,
            txn.executed,
            !txn.executed &&
                txn.epoch == ownerEpoch &&
                block.timestamp < txn.expiresAt,
            txn.expiresAt
        );
    }

    function getTransactionHash(
        uint256 transactionId
    )
        external
        view
        transactionExists(transactionId)
        returns (bytes32)
    {
        Transaction storage txn =
            _transactions[transactionId];

        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                transactionId,
                txn.target,
                txn.value,
                keccak256(txn.data),
                txn.epoch,
                txn.expiresAt
            )
        );
    }

    /// @notice Whether a proposal is approved, unexecuted, current and unexpired.
    /// @dev Does not check the caller, wallet balance or whether the target will revert.
    /// Actual execution is restricted to current owners.
    function canExecute(
        uint256 transactionId
    )
        external
        view
        transactionExists(transactionId)
        returns (bool)
    {
        Transaction storage txn =
            _transactions[transactionId];

        return (
            !txn.executed &&
            txn.epoch == ownerEpoch &&
            block.timestamp < txn.expiresAt &&
            txn.approvals >= threshold
        );
    }

    function _invalidatePendingTransactions()
        private
    {
        ownerEpoch += 1;

        emit PendingTransactionsInvalidated(
            ownerEpoch
        );
    }
}
