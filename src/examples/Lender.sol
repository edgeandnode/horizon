// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {AggregatedLoan, ILender, LoanAggregator, LoanCommitment} from "./LoanAggregator.sol";

struct Limits {
    uint256 maxAmount;
    uint64 maxDuration;
}

contract Lender is Ownable, ILender {
    struct LoanState {
        address borrower;
        uint256 initialAmount;
        uint256 borrowerCollateral;
    }

    LoanAggregator public agg;
    Limits public limits;
    LoanState[] public loans;

    constructor(LoanAggregator _agg, Limits memory _limits) {
        agg = _agg;
        limits = _limits;
    }

    function collect(uint256 _amount) public onlyOwner returns (bool) {
        return agg.collateralization().token().transfer(owner(), _amount);
    }

    function borrow(uint256 _amount, uint256 _collateral, uint256 _payment, uint64 _unlock)
        public
        returns (LoanCommitment memory)
    {
        require(_collateral <= _amount, "collateral > amount");
        uint64 _duration = SafeCast.toUint64(_unlock - block.timestamp);
        require(_duration <= limits.maxDuration, "duration over maximum");
        require(_amount <= limits.maxAmount, "amount over maximum");
        require(_payment >= expectedPayment(_amount, _duration), "payment below expected");
        uint256 _transferAmount = _collateral + _payment;
        agg.collateralization().token().transferFrom(msg.sender, address(this), _transferAmount);

        uint96 _loanIndex = uint96(loans.length);
        loans.push(LoanState({borrower: msg.sender, initialAmount: _amount, borrowerCollateral: _collateral}));
        agg.collateralization().token().approve(address(agg), _amount);
        return LoanCommitment({
            loan: AggregatedLoan({lender: this, lenderData: _loanIndex, amount: _amount}),
            signature: "siggy"
        });
    }

    /// Return the expected payment for a loan, based on its amount and duration.
    /// @param _amount Deposit amount.
    /// @param _duration Deposit duration from the block at which the deposit is funded, in seconds.
    function expectedPayment(uint256 _amount, uint64 _duration) public view returns (uint256) {
        // TODO: Now for the tricky bit!
        // Ideally the owner would be able to set an expected annualized return. However, I did not
        // figure out an obvious way to calculate the annualized return given the loan duration
        // using standard Solidity math operations or those provided by OpenZeppelin. And using a
        // table would not be ideal, since storage space is more difficult to justify than compute.
        return 1;
    }

    function onCollateralWithraw(uint256 _amount, uint96 _lenderData) public {
        LoanState memory _loan = loans[_lenderData];
        delete loans[_lenderData];
        uint256 _loss = _loan.initialAmount - _amount;
        if (_loss < _loan.borrowerCollateral) {
            agg.collateralization().token().transfer(_loan.borrower, _loan.borrowerCollateral - _loss);
        }
    }
}
