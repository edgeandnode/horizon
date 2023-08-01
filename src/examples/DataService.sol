// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Collateralization} from "../Collateralization.sol";
import {IDataService} from "./LoanAggregator.sol";

contract DataService is Ownable, IDataService {
    struct ProviderState {
        uint128 deposit;
        uint128 payment;
    }

    Collateralization public collateralization;
    mapping(address => ProviderState) public providers;
    uint64 public disputePeriod;

    constructor(Collateralization _collateralization, uint64 _disputePeriod) {
        collateralization = _collateralization;
        disputePeriod = _disputePeriod;
    }

    /// Add provider and fund their future payment.
    function addProvider(address _provider, uint128 _payment) public onlyOwner {
        require(_payment > 0);
        require(providers[_provider].payment == 0, "provider exists");
        providers[_provider] = ProviderState({deposit: 0, payment: _payment});
        collateralization.token().transferFrom(msg.sender, address(this), _payment);
    }

    function removeProvider(address _provider) public onlyOwner {
        ProviderState memory _state = getProviderState(_provider);
        require(_state.deposit == 0, "payment already made");
        delete providers[_provider];
    }

    /// Slash the provider's deposit.
    function slash(address _provider, uint256 _amount) public onlyOwner {
        ProviderState memory _state = getProviderState(_provider);
        collateralization.slash(_state.deposit, _amount);
    }

    /// Called by data service provider to receive payment. This locks the given deposit to begin a dispute period.
    function remitPayment(address _providerAddr, uint128 _depositID, uint64 _unlock) public {
        ProviderState memory _provider = getProviderState(_providerAddr);
        Collateralization.DepositState memory _deposit = collateralization.getDeposit(_depositID);

        uint256 minCollateral = uint256(_provider.payment) * 10;
        require(_deposit.amount >= minCollateral, "collateral below minimum");
        uint128 disputePeriodEnd = uint128(block.timestamp + disputePeriod);
        require(_unlock >= disputePeriodEnd, "collateral unlock before end of dispute period");

        providers[_providerAddr].deposit = _depositID;
        if (_deposit.unlock == 0) {
            collateralization.lock(_depositID, _unlock);
        }
        collateralization.token().transfer(_providerAddr, _provider.payment);
    }

    function getProviderState(address _provider) public view returns (ProviderState memory) {
        ProviderState memory _state = providers[_provider];
        require(_state.payment != 0, "provider not found");
        return _state;
    }
}
