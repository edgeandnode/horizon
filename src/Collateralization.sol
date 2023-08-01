// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// The state associated with a slashable, potentially time-locked deposit of tokens. When a deposit is locked
/// (`block.timestamp < unlock`) it has the following properties:
/// - A deposit may only be withdrawn when the deposit is unlocked (`block.timestamp >= unlock`). Withdrawal returns the
///   deposit's token value to the depositor.
/// - The arbiter has authority to slash the deposit before unlock, which burns a given amount tokens. A slash also
///   reduces the tokens available to withdraw by the same amount.
struct DepositState {
    // creator of the deposit, has ability to withdraw when the deposit is unlocked
    address depositor;
    // authority to slash deposit value, when the deposit is locked
    address arbiter;
    // token amount associated with deposit
    uint256 value;
    // timestamp when deposit is no longer locked
    uint64 unlock;
    // timestamp of deposit creation
    uint64 start;
    // timestamp of withdrawal, 0 until withdrawn
    uint64 end;
}

//                    ┌────────┐                         ┌──────┐          ┌─────────┐
//                    │unlocked│                         │locked│          │withdrawn│
//                    └───┬────┘                         └──┬───┘          └────┬────┘
//  deposit (unlock == 0) │                                 │                   │
//  ─────────────────────>│                                 │                   │
//                        │                                 │                   │
//                   deposit (unlock != 0)                  │                   │
//  ───────────────────────────────────────────────────────>│                   │
//                        │                                 │                   │
//                        │ lock (block.timestamp < _unlock)│                   │
//                        │ ───────────────────────────────>│                   │
//                        │                                 │                   │
//                        │   (block.timestamp >= unlock)   │                   │
//                        │ <─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│                   │
//                        │                                 │                   │
//                        │                      withdraw   │                   │
//                        │ ───────────────────────────────────────────────────>│
//                    ┌───┴────┐                         ┌──┴───┐          ┌────┴────┐
//                    │unlocked│                         │locked│          │withdrawn│
//                    └────────┘                         └──────┘          └─────────┘

/// This contract manages Deposits as described above.
contract Collateralization {
    event Deposit(uint128 indexed id, address indexed depositor, address indexed arbiter, uint256 value, uint64 unlock);
    event Lock(uint128 indexed id, uint64 unlock);
    event Slash(uint128 indexed id, uint256 amount);
    event Withdraw(uint128 indexed id);

    /// Burnable ERC-20 token held by this contract.
    ERC20Burnable public immutable token;
    /// Mapping of deposit IDs to deposits.
    mapping(uint128 => DepositState) public deposits;
    /// Counter for assigning new deposit IDs.
    uint128 public lastID;

    /// @param _token the burnable ERC-20 token held by this contract.
    constructor(ERC20Burnable _token) {
        token = _token;
    }

    /// Create a new deposit, returning its associated ID.
    /// @param _arbiter Arbiter of the new deposit.
    /// @param _value Initial token value of the new deposit.
    /// @param _unlock Unlock timestamp of the new deposit, in seconds. Set to a nonzero value to lock deposit.
    /// @return id Unique ID associated with the new deposit.
    function deposit(address _arbiter, uint256 _value, uint64 _unlock) external returns (uint128) {
        lastID += 1;
        deposits[lastID] = DepositState({
            depositor: msg.sender,
            arbiter: _arbiter,
            value: _value,
            unlock: _unlock,
            start: uint64(block.timestamp),
            end: 0
        });
        bool _transferSuccess = token.transferFrom(msg.sender, address(this), _value);
        require(_transferSuccess, "transfer failed");
        emit Deposit(lastID, msg.sender, _arbiter, _value, _unlock);
        return lastID;
    }

    /// Lock the deposit associated with the given ID. This makes the deposit slashable until it is unlocked.
    /// @param _id ID of the associated deposit.
    /// @param _unlock Unlock timestamp of deposit, in seconds.
    function lock(uint128 _id, uint64 _unlock) external {
        DepositState memory _deposit = getDeposit(_id);
        require(msg.sender == _deposit.arbiter, "sender not arbiter");
        require(_deposit.end == 0, "deposit withdrawn");
        if (_deposit.unlock == _unlock) {
            return;
        }
        require(_deposit.unlock == 0, "deposit locked");
        deposits[_id].unlock = _unlock;
        emit Lock(_id, _unlock);
    }

    /// Burn some amount of the deposit value while it's locked. This action can only be performed by the arbiter of
    /// the deposit associated with the given ID.
    /// @param _id ID of the associated deposit.
    /// @param _amount Amount of remaining deposit tokens to burn.
    function slash(uint128 _id, uint256 _amount) external {
        DepositState memory _deposit = getDeposit(_id);
        require(msg.sender == _deposit.arbiter, "sender not arbiter");
        require(_deposit.end == 0, "deposit withdrawn");
        require(block.timestamp < _deposit.unlock, "deposit unlocked");
        require(_amount <= _deposit.value, "amount too large");
        deposits[_id].value -= _amount;
        token.burn(_amount);
        emit Slash(_id, _amount);
    }

    /// Collect remaining tokens associated with a deposit.
    /// @param _id ID of the associated deposit.
    function withdraw(uint128 _id) external {
        DepositState memory _deposit = getDeposit(_id);
        require(_deposit.depositor == msg.sender, "sender not depositor");
        require(_deposit.end == 0, "deposit withdrawn");
        require(block.timestamp >= _deposit.unlock, "deposit locked");
        deposits[_id].end = uint64(block.timestamp);
        bool _transferSuccess = token.transfer(_deposit.depositor, _deposit.value);
        require(_transferSuccess, "transfer failed");
        emit Withdraw(_id);
    }

    /// Return the deposit state associated with the given ID.
    /// @param _id ID of the associated deposit.
    function getDeposit(uint128 _id) public view returns (DepositState memory) {
        DepositState memory _deposit = deposits[_id];
        require(_deposit.depositor != address(0), "deposit not found");
        return _deposit;
    }

    /// Return true if the deposit associated with the given ID is slashable, false otherwise.
    /// @param _id ID of the associated deposit.
    function isSlashable(uint128 _id) external view returns (bool) {
        DepositState memory _deposit = getDeposit(_id);
        return (block.timestamp < _deposit.unlock);
    }
}
