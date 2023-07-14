// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Collateralization, Deposit, DepositState} from "../Collateralization.sol";

interface IDataService {
    function remitPayment(address _provider, uint128 _deposit) external;
}

struct LoanCommitment {
    AggregatedLoan loan;
    bytes signature;
}

struct AggregatedLoan {
    address lender;
    uint256 value;
    address borrower;
    uint256 borrowerCollateral;
}

contract LoanAggregator {
    Collateralization public collateralization;
    mapping(uint128 => AggregatedLoan[]) public loans;

    constructor(Collateralization _collateralization) {
        collateralization = _collateralization;
    }

    function remitPayment(IDataService _arbiter, uint128 _expiration, LoanCommitment[] calldata _loanCommitments)
        public
        returns (uint128)
    {
        uint256 _index = 0;
        uint256 _value = 0;
        while (_index < _loanCommitments.length) {
            LoanCommitment memory _commitment = _loanCommitments[_index];
            require(_commitment.loan.borrowerCollateral < _commitment.loan.value);
            // TODO: verify signature of (lender, value, arbiter, expiration)
            _value += _commitment.loan.value;
            collateralization.token().transferFrom(_commitment.loan.lender, address(this), _commitment.loan.value);
            _index += 1;
        }
        collateralization.token().approve(address(collateralization), _value);
        uint128 _deposit = collateralization.deposit(_value, _expiration, address(_arbiter));
        _index = 0;
        while (_index < _loanCommitments.length) {
            loans[_deposit].push(_loanCommitments[_index].loan);
            _index += 1;
        }
        _arbiter.remitPayment(msg.sender, _deposit);
        return _deposit;
    }

    function withdraw(uint128 _depositID) public {
        // Note that this sort of check prevents the collateralization contract from reusing the storage for deposit
        // IDs. Since that would result in ABA-style problems. Alternatively we could allow reuse, but restrict
        // withdraw to only the depositor.
        Deposit memory _deposit = collateralization.getDeposit(_depositID);
        if (_deposit.state != DepositState.Withdrawn) {
            collateralization.withdraw(_depositID);
        }
        uint256 _index = 0;
        while (_index < loans[_depositID].length) {
            AggregatedLoan memory _loan = loans[_depositID][_index];
            uint256 _borrowerReturn = _loan.borrowerCollateral;
            uint256 _lenderReturn = _loan.value - _loan.borrowerCollateral;
            collateralization.token().transfer(_loan.lender, _lenderReturn);
            collateralization.token().transfer(_loan.borrower, _borrowerReturn);
            _index += 1;
        }
        delete loans[_depositID];
    }
}
