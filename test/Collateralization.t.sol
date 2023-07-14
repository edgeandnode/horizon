// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Burnable} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Collateralization, Deposit, DepositState} from "../src/Collateralization.sol";

contract TestToken is ERC20Burnable {
    constructor(uint256 _initialSupply) ERC20("MockCoin", "MOCK") {
        _mint(msg.sender, _initialSupply);
    }
}

contract CollateralizationHandler is CommonBase, StdUtils {
    Collateralization public collateralization;
    uint256 tokenSupply;
    uint128[] depositIDs;
    address[] actors;

    constructor() {
        tokenSupply = 900;
        collateralization = new Collateralization(new TestToken(tokenSupply));
        actors = [address(1), address(2), address(3)];

        uint256 _index = 0;
        while (_index < actors.length) {
            collateralization.token().transfer(actors[_index], tokenSupply / (actors.length));
            _index += 1;
        }
    }

    function warp(uint256 blocks) public {
        vm.warp(block.timestamp + bound(blocks, 1, 10));
    }

    function deposit(uint256 __sender, uint256 __value, uint256 __expiration, uint256 __arbiter)
        public
        returns (uint128)
    {
        address _depositor = _genActor(__sender);
        uint256 _value = bound(__value, 1, collateralization.token().balanceOf(_depositor));
        vm.startPrank(_depositor);
        collateralization.token().approve(address(collateralization), _value);
        uint128 _id = collateralization.deposit(_value, _genExpiration(__expiration), _genActor(__arbiter));
        vm.stopPrank();
        depositIDs.push(_id);
        return _id;
    }

    function lock(uint256 __sender, uint256 __id) public {
        vm.prank(_genActor(__sender));
        collateralization.lock(_genID(__id));
    }

    function withdraw(uint256 __sender, uint256 __id) public {
        uint128 _id = _genID(__id);
        vm.prank(_genActor(__sender));
        collateralization.withdraw(_id);
        _removeDepositID(_id);
    }

    function slash(uint256 __sender, uint256 __id) public {
        uint128 _id = _genID(__id);
        vm.prank(_genActor(__sender));
        collateralization.slash(_id);
        assert(collateralization.isSlashable(_id));
        _removeDepositID(_id);
    }

    function depositTotal() public view returns (uint256) {
        uint256 total = 0;
        uint64 _index = 0;
        while (_index < depositIDs.length) {
            uint128 _id = depositIDs[_index];
            Deposit memory _deposit = collateralization.getDeposit(_id);
            if (_deposit.depositor != address(0)) {
                total += _deposit.value;
            }
            _index += 1;
        }
        return total;
    }

    function _removeDepositID(uint128 _id) internal {
        uint256 _index = 0;
        while (_index < depositIDs.length) {
            if (depositIDs[_index] == _id) {
                depositIDs[_index] = depositIDs[depositIDs.length - 1];
                depositIDs.pop();
                return;
            }
            _index += 1;
        }
    }

    function _genID(uint256 _seed) internal view returns (uint128) {
        return depositIDs[bound(_seed, 0, depositIDs.length - 1)];
    }

    function _genActor(uint256 _seed) internal view returns (address) {
        return actors[bound(_seed, 0, actors.length - 1)];
    }

    function _genExpiration(uint256 _seed) internal view returns (uint128) {
        return uint128(bound(_seed, 1, 20));
    }
}

contract CollateralizationInvariants is Test {
    CollateralizationHandler public handler;
    ERC20Burnable public token;

    function setUp() public {
        handler = new CollateralizationHandler();
        token = handler.collateralization().token();
        targetContract(address(handler));
    }

    function invariant_depositBalance() public {
        assertEq(token.balanceOf(address(handler.collateralization())), handler.depositTotal());
    }
}

contract CollateralizationUnitTests is Test {
    TestToken public token;
    Collateralization public collateralization;

    function setUp() public {
        token = new TestToken(1_000);
        collateralization = new Collateralization(token);
    }

    function test_Deposit() public {
        uint128 _expiration = uint128(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(0));
        assertEq(token.balanceOf(address(this)), _initialBalance - 1);
        assertEq(token.balanceOf(address(collateralization)), 1);
        assertEq(collateralization.getDeposit(_id).depositor, address(this));
        assertEq(uint256(collateralization.getDeposit(_id).state), uint256(DepositState.Unlocked));
        assertEq(collateralization.isSlashable(_id), false);
    }

    function test_DepositUniqueID() public {
        uint128 _expiration = uint128(block.timestamp) + 1;
        token.approve(address(collateralization), 2);
        uint128 _id1 = collateralization.deposit(1, _expiration, address(0));
        uint128 _id2 = collateralization.deposit(1, _expiration, address(0));
        assertNotEq(_id1, _id2);
    }

    function testFail_DepositExpirationAtBlock() public {
        uint128 _expiration = uint128(block.timestamp);
        token.approve(address(collateralization), 1);
        collateralization.deposit(1, _expiration, address(0));
    }

    function testFail_DepositExpirationBeforeBlock() public {
        uint128 _expiration = uint128(block.timestamp) - 1;
        token.approve(address(collateralization), 1);
        collateralization.deposit(1, _expiration, address(0));
    }

    function test_Lock() public {
        uint128 _expiration = uint128(block.timestamp) + 1;
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        assertEq(uint256(collateralization.getDeposit(_id).state), uint256(DepositState.Unlocked));
        collateralization.lock(_id);
        assertEq(uint256(collateralization.getDeposit(_id).state), uint256(DepositState.Locked));
        assertEq(collateralization.isSlashable(_id), true);
    }

    function testFail_LockAtExpiration() public {
        uint128 _expiration = uint128(block.timestamp) + 1;
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        vm.warp(_expiration);
        collateralization.lock(_id);
    }

    function testFail_LockAfterExpiration() public {
        uint128 _expiration = uint128(block.timestamp) + 1;
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        vm.warp(_expiration + 1);
        collateralization.lock(_id);
    }

    function testFail_getDepositNoDeposit() public view {
        collateralization.getDeposit(0);
    }

    function test_WithdrawAtExpiration() public {
        uint128 _expiration = uint128(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        collateralization.lock(_id);
        vm.warp(_expiration);
        collateralization.withdraw(_id);
        assertEq(token.balanceOf(address(this)), _initialBalance);
        assertEq(token.balanceOf(address(collateralization)), 0);
        assertEq(uint256(collateralization.getDeposit(_id).state), uint256(DepositState.Withdrawn));
    }

    function test_WithdrawAfterExpiration() public {
        uint128 _expiration = uint128(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        collateralization.lock(_id);
        vm.warp(_expiration + 1);
        collateralization.withdraw(_id);
        assertEq(token.balanceOf(address(this)), _initialBalance);
        assertEq(token.balanceOf(address(collateralization)), 0);
    }

    function testFail_WithdrawBeforeExpiration() public {
        token.approve(address(collateralization), 1);
        uint128 _expiration = uint128(block.timestamp) + 3;
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        collateralization.lock(_id);
        vm.warp(_expiration - 1);
        collateralization.withdraw(_id);
    }

    function test_WithdrawLocked() public {
        uint128 _expiration = uint128(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        collateralization.lock(_id);
        vm.warp(_expiration);
        collateralization.withdraw(_id);
        assertEq(token.balanceOf(address(this)), _initialBalance);
        assertEq(token.balanceOf(address(collateralization)), 0);
    }

    function test_WithdrawFromNonDepositor() public {
        uint128 _expiration = uint128(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        address _other = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        collateralization.lock(_id);
        vm.warp(_expiration);
        vm.prank(_other);
        collateralization.withdraw(_id);
        assertEq(token.balanceOf(address(this)), _initialBalance);
    }

    function test_Slash() public {
        uint128 _expiration = uint128(block.timestamp) + 3;
        address _arbiter = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        uint256 _initialSupply = token.totalSupply();
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, _arbiter);
        vm.startPrank(_arbiter);
        collateralization.lock(_id);
        vm.warp(_expiration - 1);
        collateralization.slash(_id);
        vm.stopPrank();
        assertEq(token.totalSupply(), _initialSupply - 1);
        assertEq(uint256(collateralization.getDeposit(_id).state), uint256(DepositState.Slashed));
    }

    function testFail_SlashAtExpiration() public {
        uint128 _expiration = uint128(block.timestamp) + 3;
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        collateralization.lock(_id);
        vm.warp(_expiration);
        collateralization.slash(_id);
    }

    function testFail_SlashAfterExpiration() public {
        uint128 _expiration = uint128(block.timestamp) + 3;
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        collateralization.lock(_id);
        vm.warp(_expiration + 1);
        collateralization.slash(_id);
    }

    function testFail_SlashUnlocked() public {
        uint128 _expiration = uint128(block.timestamp) + 3;
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, address(this));
        vm.warp(_expiration + 1);
        collateralization.slash(_id);
    }

    function testFail_SlashFromNonArbiter() public {
        uint128 _expiration = uint128(block.timestamp) + 3;
        address _arbiter = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        token.approve(address(collateralization), 1);
        uint128 _id = collateralization.deposit(1, _expiration, _arbiter);
        vm.warp(_expiration - 1);
        collateralization.slash(_id);
    }
}
