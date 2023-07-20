// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// A Deposit describes a slashable, time-locked deposit of `value` tokens. A Deposit must be in the locked `state` to
/// provide the following invariants:
/// - The `arbiter` has the authority to slash the Deposit before `expiration`, which burns a given amount tokens. A
///   slash also reduces the tokens eventually available to withdraw by the same amount.
/// - A Deposit may only be withdrawn when `block.timestamp >= expiration`. Withdrawal returns `value` tokens to the
///   depositor.
struct Deposit {
    address depositor;
    address arbiter;
    uint256 value;
    uint128 expiration;
    DepositState state;
}

///  ┌────────┐          ┌──────┐          ┌─────────┐
///  │Unlocked│          │Locked│          │Withdrawn│
///  └───┬────┘          └──┬───┘          └────┬────┘
///      │       lock       │                   │
///      │ ─────────────────>                   │
///      │                  │                   │
///      │                  │────┐              │
///      │                  │    │ slash        │
///      │                  │<───┘              │
///      │                  │                   │
///      │                  │     withdraw      │
///      │                  │ ─────────────────>│
///      │                  │                   │
///      │               withdraw               │
///      │ ────────────────────────────────────>│
///      │                  │                   │
///      │               deposit                │
///      │ <────────────────────────────────────│
///  ┌───┴────┐          ┌──┴───┐          ┌────┴────┐
///  │Unlocked│          │Locked│          │Withdrawn│
///  └────────┘          └──────┘          └─────────┘
enum DepositState {
    Unlocked,
    Locked,
    Withdrawn
}

/// Deposit in unexpected state.
error UnexpectedState(DepositState state);
/// Deposit value is zero.
error ZeroValue();
/// Deposit expiration in unexpected state.
error Expired(bool expired);
/// Withdraw called by an address that isn't the depositor.
error NotDepositor();
/// Slash called by an address that isn't the deposit's arbiter.
error NotArbiter();
/// Deposit does not exist.
error NotFound();
/// Slash amount is larger than remainning deposit balance.
error SlashAmountTooLarge();

/// This contract manages Deposits as described above.
contract Collateralization {
    event _Deposit(uint128 indexed id, address indexed arbiter, uint256 value, uint128 expiration);
    event _Lock(uint128 indexed id);
    event _Withdraw(uint128 indexed id);
    event _Slash(uint128 indexed id, uint256 amount);

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
    /// @param _id _id ID of the deposit ID to reuse. This should be set to zero to receive a new ID. IDs may only be
    /// reused by its prior depositor when the deposit is withdrawn.
    /// @param _value Token value of the new deposit.
    /// @param _expiration Expiration timestamp of the new deposit, in seconds.
    /// @param _arbiter Arbiter of the new deposit.
    /// @return id ID associated with the new deposit.
    function deposit(uint128 _id, uint256 _value, uint128 _expiration, address _arbiter) public returns (uint128) {
        if (_value == 0) revert ZeroValue();
        if (_id == 0) {
            if (block.timestamp >= _expiration) revert Expired(true);
            lastID += 1;
            _id = lastID;
        } else {
            Deposit memory _deposit = getDeposit(_id);
            if (msg.sender != _deposit.depositor) revert NotDepositor();
            if (_deposit.state != DepositState.Withdrawn) revert UnexpectedState(_deposit.state);
        }
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
        if (_deposit.depositor != msg.sender) revert NotDepositor();
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

    /// Burn some amount of the deposit value prior to expiration. This action can only be performed by the arbiter of
    /// the deposit associated with the given ID.
    /// @param _id ID of the associated deposit.
    /// @param _amount Amount of remaining tokens to burn.
    function slash(uint128 _id, uint256 _amount) public {
        Deposit memory _deposit = getDeposit(_id);
        if (msg.sender != _deposit.arbiter) revert NotArbiter();
        if (_deposit.state != DepositState.Locked) revert UnexpectedState(_deposit.state);
        if (block.timestamp >= _deposit.expiration) revert Expired(true);
        if (_amount > _deposit.value) revert SlashAmountTooLarge();
        deposits[_id].value -= _amount;
        token.burn(_amount);
        emit _Slash(_id, _amount);
    }

    /// Return the deposit associated with the given ID.
    /// @param _id ID of the associated deposit.
    function getDeposit(uint128 _id) public view returns (Deposit memory) {
        Deposit memory _deposit = deposits[_id];
        if (_deposit.depositor == address(0)) revert NotFound();
        return _deposit;
    }

    /// Return true if the deposit associated with the given ID is slashable, false otherwise. A slashable deposit is
    /// locked and not expired.
    /// @param _id ID of the associated deposit.
    function isSlashable(uint128 _id) public view returns (bool) {
        Deposit memory _deposit = getDeposit(_id);
        // TODO: also check if `_deposit.value > 0`?
        return (_deposit.state == DepositState.Locked) && (block.timestamp < _deposit.expiration);
    }
}
