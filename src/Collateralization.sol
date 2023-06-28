// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice A `Deposit` describes a slashable, time-locked deposit of `value` tokens. A `Deposit`
/// might not be funded upon creation, in which case the `depositor` is set to the zero address.
/// Once a `Deposit` is funded (has a nonzero `depositor`), it will remain in the funded state until
/// the deposit is removed via withdrawal or slashing. A `Deposit` may only be withdrawn when
/// `block.timestamp >= expiration`. Withdrawal returns `value` tokens to the depositor. The
/// `arbiter` has the authority to slash the `Deposit` before `expiration`, which also burns `value`
/// tokens.
struct Deposit {
    uint256 value;
    uint128 expiration;
    address arbiter;
    address depositor;
}

/// @notice This contract manages `Deposits` as described above.
contract Collateralization {
    /// @notice Burnable ERC-20 token held by this contract.
    ERC20Burnable public token;
    /// @notice Mapping of deposit IDs to deposits.
    mapping(uint128 => Deposit) public deposits;
    /// @notice Counter for assigning new deposit IDs.
    uint128 public lastID;

    /// @param _token the burnable ERC-20 token held by this contract.
    constructor(ERC20Burnable _token) {
        token = _token;
    }

    /// @notice Create a new deposit, returning its associated ID.
    /// @param value Token value of the new deposit.
    /// @param expiration Expiration timestamp of the new deposit, in seconds.
    /// @param arbiter Arbiter of the new deposit.
    /// @param _fund True if the sender intends to fund the new deposit, false otherwise.
    /// @return id Unique ID associated with the new deposit.
    function prepare(uint256 value, uint128 expiration, address arbiter, bool _fund) public returns (uint128) {
        require(value > 0, "value is zero");
        require(block.timestamp < expiration, "deposit expired");
        lastID += 1;
        address depositor = _fund ? msg.sender : address(0);
        deposits[lastID] = Deposit({value: value, expiration: expiration, arbiter: arbiter, depositor: depositor});
        if (_fund) {
            bool transferSuccess = token.transferFrom(msg.sender, address(this), value);
            require(transferSuccess, "transfer failed");
        }
        return lastID;
    }

    /// @notice Fund an existing deposit. The sender will be set as the depositor, granting them the
    /// authority to withdraw upon expiration.
    /// @param id ID of the associated deposit.
    function fund(uint128 id) public {
        Deposit memory deposit = deposits[id];
        require(block.timestamp < deposit.expiration, "deposit expired");
        require(deposit.depositor == address(0), "deposit funded");
        deposits[id].depositor = msg.sender;
        bool transferSuccess = token.transferFrom(msg.sender, address(this), deposit.value);
        require(transferSuccess, "transfer failed");
    }

    /// @notice Remove an expired deposit and return its associated tokens to the depositor.
    /// @param id ID of the associated deposit.
    function withdraw(uint128 id) public {
        Deposit memory deposit = deposits[id];
        require(block.timestamp >= deposit.expiration, "deposit not expired");
        require(deposit.depositor != address(0), "depositor is zero");
        delete deposits[id];
        bool _transferSuccess = token.transfer(deposit.depositor, deposit.value);
        require(_transferSuccess, "transfer failed");
    }

    /// @notice Remove a deposit prior to expiration and burn its associated tokens. This action can
    /// only be performed by the arbiter of the deposit associated with the given ID.
    /// @param id ID of the associated deposit.
    function slash(uint128 id) public {
        Deposit memory deposit = deposits[id];
        require(msg.sender == deposit.arbiter, "sender not arbiter");
        require(deposit.depositor != address(0), "deposit not funded");
        require(block.timestamp < deposit.expiration, "deposit expired");
        delete deposits[id];
        token.burn(deposit.value);
    }

    /// @notice Returns the deposit associated with the given ID.
    /// @param id ID of the associated deposit.
    function getDeposit(uint128 id) public view returns (Deposit memory) {
        Deposit memory deposit = deposits[id];
        require(deposit.value > 0, "deposit not found");
        return deposit;
    }

    /// @notice Returns true if the deposit associated with the given ID is slashable, false
    /// otherwise. A slashable deposit is one that is funded and has not expired.
    /// @param id ID of the associated deposit.
    function isSlashable(uint128 id) public view returns (bool) {
        return (deposits[id].depositor != address(0)) && (block.timestamp < deposits[id].expiration);
    }
}
