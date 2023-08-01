// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Burnable} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Collateralization} from "../src/Collateralization.sol";
import {DataService} from "../src/examples/DataService.sol";
import {Lender, Limits} from "../src/examples/Lender.sol";
import {
    AggregatedLoan, IDataService, ILender, LoanAggregator, LoanCommitment
} from "../src/examples/LoanAggregator.sol";

contract TestToken is ERC20Burnable {
    constructor(uint256 _initialSupply) ERC20("MockCoin", "MOCK") {
        _mint(msg.sender, _initialSupply);
    }
}

contract CollateralizationUnitTests is Test, ILender {
    TestToken public token;
    Collateralization public collateralization;
    DataService public dataService;
    LoanAggregator public aggregator;
    Lender public lender;

    function onCollateralWithraw(uint256 _value, uint96 _lenderData) public {}

    function setUp() public {
        token = new TestToken(1_000);
        collateralization = new Collateralization(token);
        aggregator = new LoanAggregator(collateralization);
        dataService = new DataService(collateralization, 20 days);
        lender = new Lender(aggregator, Limits({maxValue: 100, maxDuration: 30 days}));
        token.transfer(address(lender), 80);
    }

    function test_Example() public {
        // Add this contract as a data service provider to receive 10 tokens in payment.
        token.approve(address(dataService), 10);
        dataService.addProvider(address(this), 10);

        uint256 _initialBalance = token.balanceOf(address(this));
        uint256 _initialLenderBalance = token.balanceOf(address(lender));

        // Data service requires 10x of payment (100 tokens) in collateralization deposit. Fund deposit with a 20 token
        // loan from self, and a 80 token loan from lender.
        LoanCommitment[] memory _loanCommitments = new LoanCommitment[](2);
        token.approve(address(aggregator), 20);
        _loanCommitments[0] =
            LoanCommitment({loan: AggregatedLoan({lender: this, lenderData: 0, value: 20}), signature: "siggy"});
        // Send lender 5 tokens in collateral and 1 token in payment (6 total) for a 80 token loan.
        token.approve(address(lender), 6);
        _loanCommitments[1] = lender.borrow(80, 5, 1, dataService.disputePeriod());
        // Receive 10 token payment and start dispute period.
        uint64 _unlock = uint64(block.timestamp) + dataService.disputePeriod();
        uint128 _deposit = aggregator.remitPayment(DataService(dataService), _unlock, _loanCommitments);

        assertEq(token.balanceOf(address(this)), _initialBalance + 10 - 26);
        assertEq(token.balanceOf(address(lender)), _initialLenderBalance + 6 - 80);

        // Withdraw deposit at end of dispute period.
        vm.warp(block.number + dataService.disputePeriod());
        aggregator.withdraw(_deposit);
        assertEq(token.balanceOf(address(this)), _initialBalance + 10 - 1);
        assertEq(token.balanceOf(address(lender)), _initialLenderBalance + 1);
    }

    function test_ExampleSlash() public {
        // Add this contract as a data service provider to receive 10 tokens in payment.
        token.approve(address(dataService), 10);
        dataService.addProvider(address(this), 10);

        uint256 _initialBalance = token.balanceOf(address(this));
        uint256 _initialLenderBalance = token.balanceOf(address(lender));

        // Data service requires 10x of payment (100 tokens) in collateralization deposit. Fund deposit with a 20 token
        // loan from self, and a 80 token loan from lender.
        LoanCommitment[] memory _loanCommitments = new LoanCommitment[](2);
        token.approve(address(aggregator), 20);
        _loanCommitments[0] =
            LoanCommitment({loan: AggregatedLoan({lender: this, lenderData: 0, value: 20}), signature: "siggy"});
        // Send lender 5 tokens in collateral and 1 token in payment (6 total) for a 80 token loan.
        token.approve(address(lender), 6);
        _loanCommitments[1] = lender.borrow(80, 5, 1, dataService.disputePeriod());
        // Receive 10 token payment and start dispute period.
        uint64 _unlock = uint64(block.timestamp) + dataService.disputePeriod();
        uint128 _deposit = aggregator.remitPayment(DataService(dataService), _unlock, _loanCommitments);

        assertEq(token.balanceOf(address(this)), _initialBalance + 10 - 26);
        assertEq(token.balanceOf(address(lender)), _initialLenderBalance + 6 - 80);

        // Warp to one block before disoute period end, and slash 80 tokens (80%) of deposit.
        vm.warp(block.number + dataService.disputePeriod() - 1);
        dataService.slash(address(this), 80);
        // Warp to end of dispute period, and withdraw remaining tokens.
        vm.warp(block.number + dataService.disputePeriod());
        aggregator.withdraw(_deposit);
        assertEq(token.balanceOf(address(this)), _initialBalance + 10 - 22);
        assertEq(token.balanceOf(address(lender)), _initialLenderBalance + 6 - 64);
    }
}
