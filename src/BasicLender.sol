// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {Collateralization, Deposit} from "./Collateralization.sol";

/*

Expected use-case:

Some payment protocol prepares a deposit in the Collateralization contract, and requires the deposit
to be funded for the borrower to receive payment. The borrower uses this contract to fund the
deposit.

Notes:
- Borrower collateral is the deterrent for attack on lender.
- This contract doesn't bother allowlisting arbiters, since the worst case of a borrower setting
  themselves as the arbiter and slashing the lender's deposit is equivalent to the borrower
  performing a slashable offense on purpose.

Invariants:
- all id | some loans[id] => isFundedDeposit(id)
- all loan: loans | loan.lenderCollateral <= getDeposit(id).value

*/

struct Limits {
    uint256 maxValue;
    uint64 maxDuration;
}

contract BasicLender is Ownable {
    struct Loan {
        address lender;
        uint256 lenderCollateral;
    }

    /// @notice Collateralization contract where deposits are funded.
    Collateralization public collateralization;
    /// @notice Mapping of collateralization deposit ID to loan.
    mapping(uint128 => Loan) public loans;
    /// @notice Limits on acceptable loans.
    Limits public limits;

    constructor(Collateralization _collateralization, Limits memory _limits) {
        collateralization = _collateralization;
        limits = _limits;
    }

    /// @notice Transfer tokens from this contract to its owner.
    /// @param amount Amount of tokens to transfer.
    function collect(uint256 amount) public onlyOwner returns (bool) {
        return collateralization.token().transfer(owner(), amount);
    }

    /// @notice Fund a deposit using this lender's tokens. This function will transfer
    /// `collateral + payment` to this contract.
    /// @param id ID associated with the deposit to fund.
    /// @param collateral Borrower collateral, returned to the borrower when calling withdraw. Note
    /// that the borrower will not be able to withdraw if the deposit is slashed.
    /// @param payment Payment to the lender, this amount will not be returned to the borrower.
    function fund(uint128 id, uint256 collateral, uint256 payment) public {
        // We don't need to check if the loan already exists, since that's implied by the deposit
        // being funded.
        Deposit memory deposit = collateralization.getDeposit(id);
        // precondition for withdraw
        require(collateral <= deposit.value, "collateral > deposit.value");
        uint64 duration = SafeCast.toUint64(deposit.expiration - block.timestamp);
        require(duration <= limits.maxDuration, "duration over maximum");
        require(deposit.value <= limits.maxValue, "value over maximum");
        require(payment >= expectedPayment(deposit.value, duration), "payment below expected");
        loans[id] = Loan({lender: msg.sender, lenderCollateral: collateral});
        uint256 transferAmount = collateral + payment;
        collateralization.token().transferFrom(msg.sender, address(this), transferAmount);
        collateralization.fund(id);
    }

    /// @notice Withdraw the deposit and return the borrower's collateral.
    /// @param id ID of the associated deposit.
    function withdraw(uint128 id) public {
        Loan memory loan = loans[id];
        require(loan.lender != address(0), "loan not found");
        delete loans[id];
        collateralization.withdraw(id);
        // We expect this to succeed because `lenderCollateral <= deposit.value` and the withdraw
        // from collateralization occurs first.
        collateralization.token().transfer(loan.lender, loan.lenderCollateral);
    }

    /// @notice Return the expected payment for a loan, based on its value and duration.
    /// @param value Deposit value.
    /// @param duration Deposit duration from the block at which the deposit is funded, in seconds.
    function expectedPayment(uint256 value, uint64 duration) public view returns (uint256) {
        // TODO: Now for the tricky bit!
        // Ideally the owner would be able to set an expected annualized return. However, I did not
        // figure out an obvious way to calculate the annualized return given the loan duration
        // using standard Solidity math operations or those provided by OpenZeppelin. And using a
        // table would not be ideal, since storage space is more difficult to justify than compute.
    }
}
