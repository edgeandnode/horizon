// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Collateralization, DepositState} from "../Collateralization.sol";

interface IDataService {
    function remitPayment(address _provider, uint128 _deposit, uint64 _unlock) external;
}

interface ILender {
    function onCollateralWithraw(uint256 _value, uint96 _lenderData) external;
}

struct LoanCommitment {
    AggregatedLoan loan;
    bytes signature;
}

struct AggregatedLoan {
    ILender lender;
    uint96 lenderData;
    uint256 value;
}

contract LoanAggregator {
    Collateralization public collateralization;
    mapping(uint128 => AggregatedLoan[]) public loans;

    constructor(Collateralization _collateralization) {
        collateralization = _collateralization;
    }

    function remitPayment(IDataService _arbiter, uint64 _unlock, LoanCommitment[] calldata _loanCommitments)
        public
        returns (uint128)
    {
        uint256 _index = 0;
        uint256 _value = 0;
        while (_index < _loanCommitments.length) {
            LoanCommitment memory _commitment = _loanCommitments[_index];
            // TODO: verify signature of (lender, value, arbiter, unlock)
            _value += _commitment.loan.value;
            collateralization.token().transferFrom(
                address(_commitment.loan.lender), address(this), _commitment.loan.value
            );
            _index += 1;
        }
        collateralization.token().approve(address(collateralization), _value);
        uint128 _deposit = collateralization.deposit(address(_arbiter), _value, _unlock);
        _index = 0;
        while (_index < _loanCommitments.length) {
            loans[_deposit].push(_loanCommitments[_index].loan);
            _index += 1;
        }
        _arbiter.remitPayment(msg.sender, _deposit, _unlock);
        return _deposit;
    }

    function withdraw(uint128 _depositID) public {
        DepositState memory _deposit = collateralization.getDeposit(_depositID);
        collateralization.withdraw(_depositID);
        // calculate original deposit value
        uint256 _index = 0;
        uint256 _initialValue = 0;
        while (_index < loans[_depositID].length) {
            _initialValue += loans[_depositID][_index].value;
            _index += 1;
        }
        // distribute remaining deposit value back to lenders
        _index = 0;
        while (_index < loans[_depositID].length) {
            AggregatedLoan memory _loan = loans[_depositID][_index];
            uint256 _lenderReturn = (_loan.value * _deposit.value) / _initialValue;
            collateralization.token().transfer(address(_loan.lender), _lenderReturn);
            _loan.lender.onCollateralWithraw(_lenderReturn, _loan.lenderData);
            _index += 1;
        }
        delete loans[_depositID];
    }
}
