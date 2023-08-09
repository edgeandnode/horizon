// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {HorizonCore} from "../HorizonCore.sol";

interface IDataService {
    function remitPayment(address _provider, uint128 _deposit, uint64 _unlock) external;
}

interface ILender {
    function onCollateralWithraw(uint256 _amount, uint96 _lenderData) external;
}

struct LoanCommitment {
    AggregatedLoan loan;
    bytes signature;
}

struct AggregatedLoan {
    ILender lender;
    uint96 lenderData;
    uint256 amount;
}

contract LoanAggregator {
    HorizonCore public core;
    mapping(uint128 => AggregatedLoan[]) public loans;

    constructor(HorizonCore _core) {
        core = _core;
    }

    function remitPayment(IDataService _arbiter, uint64 _unlock, LoanCommitment[] calldata _loanCommitments)
        public
        returns (uint128)
    {
        uint256 _index = 0;
        uint256 _amount = 0;
        while (_index < _loanCommitments.length) {
            LoanCommitment memory _commitment = _loanCommitments[_index];
            // TODO: verify signature of (lender, amount, arbiter, unlock)
            _amount += _commitment.loan.amount;
            core.token().transferFrom(address(_commitment.loan.lender), address(this), _commitment.loan.amount);
            _index += 1;
        }
        core.token().approve(address(core), _amount);
        uint128 _deposit = core.deposit(address(_arbiter), _amount, _unlock);
        _index = 0;
        while (_index < _loanCommitments.length) {
            loans[_deposit].push(_loanCommitments[_index].loan);
            _index += 1;
        }
        _arbiter.remitPayment(msg.sender, _deposit, _unlock);
        return _deposit;
    }

    function withdraw(uint128 _depositID) public {
        HorizonCore.DepositState memory _deposit = core.getDepositState(_depositID);
        core.withdraw(_depositID);
        // calculate original deposit amount
        uint256 _index = 0;
        uint256 _initialAmount = 0;
        while (_index < loans[_depositID].length) {
            _initialAmount += loans[_depositID][_index].amount;
            _index += 1;
        }
        // distribute remaining deposit amount back to lenders
        _index = 0;
        while (_index < loans[_depositID].length) {
            AggregatedLoan memory _loan = loans[_depositID][_index];
            uint256 _lenderReturn = (_loan.amount * _deposit.amount) / _initialAmount;
            core.token().transfer(address(_loan.lender), _lenderReturn);
            _loan.lender.onCollateralWithraw(_lenderReturn, _loan.lenderData);
            _index += 1;
        }
        delete loans[_depositID];
    }
}
