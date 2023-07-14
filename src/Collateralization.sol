// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// A `Deposit` describes a slashable, time-locked deposit of `value` tokens. A `Deposit` must be `locked` to provide
/// the following invariants:
/// - A `Deposit` may only be withdrawn when `block.timestamp >= expiration`. Withdrawal returns `value` tokens to the
///   depositor.
/// - The `arbiter` has the authority to slash the `Deposit` before `expiration`, which also burns `value` tokens.
struct Deposit {
    address depositor;
    address arbiter;
    uint256 value;
    uint128 expiration;
    DepositState state;
}

///  ┌────────┐          ┌──────┐          ┌─────────┐          ┌───────┐
///  │Unlocked│          │Locked│          │Withdrawn│          │Slashed│
///  └───┬────┘          └──┬───┘          └────┬────┘          └───┬───┘
///      │       lock       │                   │                   │
///      │ ────────────────>│                   │                   │
///      │                  │                   │                   │
///      │                  │     withdraw      │                   │
///      │                  │ ─────────────────>│                   │
///      │                  │                   │                   │
///      │               withdraw               │                   │
///      │ ────────────────────────────────────>│                   │
///      │                  │                   │                   │
///      │                  │                 slash                 │
///      │                  │ ─────────────────────────────────────>│
///  ┌───┴────┐          ┌──┴───┐          ┌────┴────┐          ┌───┴───┐
///  │Unlocked│          │Locked│          │Withdrawn│          │Slashed│
///  └────────┘          └──────┘          └─────────┘          └───────┘
enum DepositState {
    Unlocked, //  0b00
    Locked, //    0b01
    Withdrawn, // 0b10
    Slashed //    0b11
}

/// Deposit in unexpected state.
error UnexpectedState(DepositState state);
/// Deposit value is zero.
error ZeroValue();
/// Deposit expiration in unexpected state.
error Expired(bool expired);
/// Slash called by an address that isn't the deposit's arbiter.
error NotArbiter();
/// Deposit does not exist.
error NotFound();

/// This contract manages `Deposit`s as described above.
contract Collateralization {
    event _Deposit(uint128 indexed id, address indexed arbiter, uint256 value, uint128 expiration);
    event _Lock(uint128 indexed id);
    event _Withdraw(uint128 indexed id);
    event _Slash(uint128 indexed id);

    /// Burnable ERC-20 token held by this contract.
    ERC20Burnable public token;
    /// Mapping of deposit IDs to deposits.
    mapping(uint128 => Deposit) public deposits;
    /// Counter for assigning new deposit IDs.
    uint128 public lastID;

    /// @param _token the burnable ERC-20 token held by this contract.
    constructor(ERC20Burnable _token) {
        // TODO: use a constant
        token = _token;
    }

    /// Create a new deposit, returning its associated ID.
    /// @param _value Token value of the new deposit.
    /// @param _expiration Expiration timestamp of the new deposit, in seconds.
    /// @param _arbiter Arbiter of the new deposit.
    /// @return id Unique ID associated with the new deposit.
    function deposit(uint256 _value, uint128 _expiration, address _arbiter) public returns (uint128) {
        if (_value == 0) revert ZeroValue();
        if (block.timestamp >= _expiration) revert Expired(true);
        lastID += 1;
        uint128 _id = lastID;
        deposits[_id] = Deposit({
            depositor: msg.sender,
            arbiter: _arbiter,
            value: _value,
            expiration: _expiration,
            state: DepositState.Unlocked
        });
        bool _transferSuccess = token.transferFrom(msg.sender, address(this), _value);
        require(_transferSuccess, "transfer failed");
        emit _Deposit(_id, _arbiter, _value, _expiration);
        return _id;
    }

    /// Lock the deposit associated with the given ID. This makes the deposit slashable until the deposit
    /// expiration.
    /// @param _id ID of the associated deposit.
    function lock(uint128 _id) public {
        Deposit memory _deposit = getDeposit(_id);
        if (msg.sender != _deposit.arbiter) revert NotArbiter();
        if (_deposit.state != DepositState.Unlocked) revert UnexpectedState(_deposit.state);
        if (block.timestamp >= _deposit.expiration) revert Expired(true);
        deposits[_id].state = DepositState.Locked;
        emit _Lock(_id);
    }

    /// Unlock the deposit associated with the given ID and return its associated tokens to the depositor.
    /// @param _id ID of the associated deposit.
    function withdraw(uint128 _id) public {
        Deposit memory _deposit = getDeposit(_id);
        DepositState _state = deposits[_id].state;
        if (_state == DepositState.Locked) {
            if (block.timestamp < _deposit.expiration) revert Expired(false);
        } else if (_state != DepositState.Unlocked) {
            revert UnexpectedState(_state);
        }
        deposits[_id].state = DepositState.Withdrawn;
        bool _transferSuccess = token.transfer(_deposit.depositor, _deposit.value);
        require(_transferSuccess, "transfer failed");
        emit _Withdraw(_id);
    }

    /// Remove a deposit prior to expiration and burn its associated tokens. This action can only be performed by the
    /// arbiter of the deposit associated with the given ID.
    /// @param _id ID of the associated deposit.
    function slash(uint128 _id) public {
        Deposit memory _deposit = getDeposit(_id);
        if (msg.sender != _deposit.arbiter) revert NotArbiter();
        if (_deposit.state != DepositState.Locked) revert UnexpectedState(_deposit.state);
        if (block.timestamp >= _deposit.expiration) revert Expired(true);
        deposits[_id].state = DepositState.Slashed;
        token.burn(_deposit.value);
        emit _Slash(_id);
    }

    /// Return the deposit associated with the given ID.
    /// @param _id ID of the associated deposit.
    function getDeposit(uint128 _id) public view returns (Deposit memory) {
        Deposit memory _deposit = deposits[_id];
        if (_deposit.value == 0) revert NotFound();
        return _deposit;
    }

    /// Return true if the deposit associated with the given ID is slashable, false otherwise. A slashable deposit is
    /// locked and not expired.
    /// @param _id ID of the associated deposit.
    function isSlashable(uint128 _id) public view returns (bool) {
        Deposit memory _deposit = getDeposit(_id);
        return (_deposit.state == DepositState.Locked) && (block.timestamp < _deposit.expiration);
    }
}
