// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {AggregatedLoan, LoanAggregator, LoanCommitment} from "./LoanAggregator.sol";

struct Limits {
    uint256 maxValue;
    uint64 maxDuration;
}

contract Lender is Ownable {
    LoanAggregator public agg;
    Limits public limits;

    constructor(LoanAggregator _agg, Limits memory _limits) {
        agg = _agg;
        limits = _limits;
    }

    function collect(uint256 _amount) public onlyOwner returns (bool) {
        return agg.collateralization().token().transfer(owner(), _amount);
    }

    function borrow(uint256 _value, uint256 _collateral, uint256 _payment, uint128 _expiration)
        public
        returns (LoanCommitment memory)
    {
        require(_collateral <= _value, "collateral > value");
        uint64 _duration = SafeCast.toUint64(_expiration - block.timestamp);
        require(_duration <= limits.maxDuration, "duration over maximum");
        require(_value <= limits.maxValue, "value over maximum");
        require(_payment >= expectedPayment(_value, _duration), "payment below expected");
        uint256 _transferAmount = _collateral + _payment;
        agg.collateralization().token().transferFrom(msg.sender, address(this), _transferAmount);

        agg.collateralization().token().approve(address(agg), _value);
        return LoanCommitment({
            loan: AggregatedLoan({
                lender: address(this),
                value: _value,
                borrower: msg.sender,
                borrowerCollateral: _collateral
            }),
            signature: "siggy"
        });
    }

    /// Return the expected payment for a loan, based on its value and duration.
    /// @param _value Deposit value.
    /// @param _duration Deposit duration from the block at which the deposit is funded, in seconds.
    function expectedPayment(uint256 _value, uint64 _duration) public view returns (uint256) {
        // TODO: Now for the tricky bit!
        // Ideally the owner would be able to set an expected annualized return. However, I did not
        // figure out an obvious way to calculate the annualized return given the loan duration
        // using standard Solidity math operations or those provided by OpenZeppelin. And using a
        // table would not be ideal, since storage space is more difficult to justify than compute.
        return 1;
    }
}
