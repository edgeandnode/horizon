// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Burnable} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Collateralization, Deposit, DepositState, UnexpectedState} from "../src/Collateralization.sol";
import {DataService} from "../src/examples/DataService.sol";
import {Lender, Limits} from "../src/examples/Lender.sol";
import {AggregatedLoan, IDataService, LoanAggregator, LoanCommitment} from "../src/examples/LoanAggregator.sol";

contract TestToken is ERC20Burnable {
    constructor(uint256 _initialSupply) ERC20("MockCoin", "MOCK") {
        _mint(msg.sender, _initialSupply);
    }
}

contract CollateralizationUnitTests is Test {
    TestToken public token;
    Collateralization public collateralization;

    function setUp() public {
        token = new TestToken(1_000);
        collateralization = new Collateralization(token);
    }

    function test_Example() public {
        DataService _dataService = new DataService(collateralization, 20 days);
        LoanAggregator _agg = new LoanAggregator(collateralization);
        Lender _lender = new Lender(_agg, Limits({maxValue: 100, maxDuration: 30 days}));
        token.transfer(address(_lender), 80);

        token.approve(address(_dataService), 10);
        _dataService.addProvider(address(this), 10);

        uint256 _initialBalance = token.balanceOf(address(this));
        uint256 _initialLenderBalance = token.balanceOf(address(_lender));

        LoanCommitment[] memory _loanCommitments = new LoanCommitment[](2);
        token.approve(address(_agg), 20);
        _loanCommitments[0] = LoanCommitment({
            loan: AggregatedLoan({lender: address(this), value: 20, borrower: address(this), borrowerCollateral: 0}),
            signature: "siggy"
        });
        token.approve(address(_lender), 6);
        _loanCommitments[1] = _lender.borrow(80, 5, 1, _dataService.disputePeriod());

        uint128 _expiration = uint128(block.timestamp) + _dataService.disputePeriod();
        uint128 _deposit = _agg.remitPayment(DataService(_dataService), _expiration, _loanCommitments);

        assertEq(token.balanceOf(address(this)), _initialBalance + 10 - 26);
        assertEq(token.balanceOf(address(_lender)), _initialLenderBalance - 80 + 6);

        vm.warp(block.number + _dataService.disputePeriod());
        _agg.withdraw(_deposit);

        assertEq(token.balanceOf(address(this)), _initialBalance + 10 - 1);
        assertEq(token.balanceOf(address(_lender)), _initialLenderBalance + 1);
    }

    function test_ExampleSlash() public {
        DataService _dataService = new DataService(collateralization, 20 days);
        LoanAggregator _agg = new LoanAggregator(collateralization);
        Lender _lender = new Lender(_agg, Limits({maxValue: 100, maxDuration: 30 days}));
        token.transfer(address(_lender), 80);

        token.approve(address(_dataService), 10);
        _dataService.addProvider(address(this), 10);

        uint256 _initialBalance = token.balanceOf(address(this));
        uint256 _initialLenderBalance = token.balanceOf(address(_lender));

        LoanCommitment[] memory _loanCommitments = new LoanCommitment[](2);
        token.approve(address(_agg), 20);
        _loanCommitments[0] = LoanCommitment({
            loan: AggregatedLoan({lender: address(this), value: 20, borrower: address(this), borrowerCollateral: 0}),
            signature: "siggy"
        });
        token.approve(address(_lender), 6);
        _loanCommitments[1] = _lender.borrow(80, 5, 1, _dataService.disputePeriod());

        uint128 _expiration = uint128(block.timestamp) + _dataService.disputePeriod();
        uint128 _deposit = _agg.remitPayment(DataService(_dataService), _expiration, _loanCommitments);

        assertEq(token.balanceOf(address(this)), _initialBalance + 10 - 26);
        assertEq(token.balanceOf(address(_lender)), _initialLenderBalance - 80 + 6);

        vm.warp(block.number + _dataService.disputePeriod() - 1);
        _dataService.slash(address(this));

        vm.warp(block.number + _dataService.disputePeriod());
        vm.expectRevert(abi.encodeWithSelector(UnexpectedState.selector, DepositState.Slashed));
        _agg.withdraw(_deposit);
    }
}
