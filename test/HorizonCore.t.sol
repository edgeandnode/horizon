// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Burnable} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {HorizonCore} from "../src/HorizonCore.sol";

contract TestToken is ERC20Burnable {
    constructor(uint256 _initialSupply) ERC20("MockCoin", "MOCK") {
        _mint(msg.sender, _initialSupply);
    }
}

contract HorizonCoreHandler is CommonBase, StdUtils {
    HorizonCore public core;
    uint256 tokenSupply;
    uint128[] depositIDs;
    address[] actors;

    constructor() {
        tokenSupply = 900;
        core = new HorizonCore(new TestToken(tokenSupply));
        actors = [address(1), address(2), address(3)];

        uint256 _index = 0;
        while (_index < actors.length) {
            core.token().transfer(actors[_index], tokenSupply / (actors.length));
            _index += 1;
        }
    }

    function warp(uint256 blocks) public {
        vm.warp(block.timestamp + bound(blocks, 1, 10));
    }

    function deposit(uint256 __sender, uint256 __arbiter, uint256 __amount, uint256 __unlock)
        public
        returns (uint128)
    {
        address _depositor = _genActor(__sender);
        uint256 _amount = bound(__amount, 1, core.token().balanceOf(_depositor));
        vm.startPrank(_depositor);
        core.token().approve(address(core), _amount);
        uint128 _id = core.deposit(_genActor(__arbiter), _amount, _genTimestamp(__unlock));
        vm.stopPrank();
        depositIDs.push(_id);
        return _id;
    }

    function lock(uint256 __sender, uint256 __id, uint256 __unlock) public {
        vm.prank(_genActor(__sender));
        core.lock(_genID(__id), _genTimestamp(__unlock));
    }

    function withdraw(uint256 __sender, uint256 __id) public {
        uint128 _id = _genID(__id);
        vm.prank(_genActor(__sender));
        core.withdraw(_id);
        _removeDepositID(_id);
    }

    function slash(uint256 __sender, uint256 __id, uint256 __amount) public {
        uint128 _id = _genID(__id);
        vm.prank(_genActor(__sender));
        core.slash(_id, bound(__amount, 0, core.getDepositState(_id).amount));
        assert(core.isSlashable(_id));
        _removeDepositID(_id);
    }

    function depositTotal() public view returns (uint256) {
        uint256 total = 0;
        uint64 _index = 0;
        while (_index < depositIDs.length) {
            uint128 _id = depositIDs[_index];
            HorizonCore.DepositState memory _deposit = core.getDepositState(_id);
            if (_deposit.depositor != address(0)) {
                total += _deposit.amount;
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

    function _genTimestamp(uint256 _seed) internal view returns (uint64) {
        return uint64(bound(_seed, 1, 20));
    }
}

contract HorizonCoreInvariants is Test {
    HorizonCoreHandler public handler;
    ERC20Burnable public token;

    function setUp() public {
        handler = new HorizonCoreHandler();
        token = handler.core().token();
        targetContract(address(handler));
    }

    function invariant_depositBalance() public {
        assertEq(token.balanceOf(address(handler.core())), handler.depositTotal());
    }
}

contract HorizonCoreUnitTests is Test {
    TestToken public token;
    HorizonCore public core;

    function setUp() public {
        token = new TestToken(1_000);
        core = new HorizonCore(token);
    }

    function test_UnlockedDeposit() public {
        uint256 _initialBalance = token.balanceOf(address(this));
        token.approve(address(core), 1);
        uint128 _next_id = core.nextID(address(this));
        uint128 _id = core.deposit(address(0), 1, 0);
        assertEq(_id, _next_id);
        assertEq(token.balanceOf(address(this)), _initialBalance - 1);
        assertEq(token.balanceOf(address(core)), 1);
        assertEq(core.getDepositState(_id).depositor, address(this));
        assertEq(core.isSlashable(_id), false);
    }

    function test_LockedDeposit() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(0), 1, _unlock);
        assertEq(token.balanceOf(address(this)), _initialBalance - 1);
        assertEq(token.balanceOf(address(core)), 1);
        assertEq(core.getDepositState(_id).depositor, address(this));
        assertEq(core.isSlashable(_id), true);
    }

    function test_DepositUniqueID() public {
        token.approve(address(core), 2);
        uint128 _id1 = core.deposit(address(0), 1, 0);
        uint128 _id2 = core.deposit(address(0), 1, 0);
        assertNotEq(_id1, _id2);
    }

    function test_Lock() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, 0);
        assertEq(core.isSlashable(_id), false);
        core.lock(_id, _unlock);
        assertEq(core.isSlashable(_id), true);
    }

    function testFail_LockLocked() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        core.lock(_id, _unlock);
    }

    function testFail_LockLockedModify() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        core.lock(_id, _unlock - 1);
    }

    function testFail_LockAfterUnlock() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        vm.warp(_unlock + 1);
        core.lock(_id, _unlock + 1);
    }

    function testFail_getDepositNoDeposit() public view {
        core.getDepositState(0);
    }

    function test_Slash() public {
        uint64 _unlock = uint64(block.timestamp) + 3;
        address _arbiter = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        uint256 _initialSupply = token.totalSupply();
        token.approve(address(core), 1);
        uint128 _id = core.deposit(_arbiter, 1, _unlock);
        vm.warp(_unlock - 1);
        vm.prank(_arbiter);
        core.slash(_id, 1);
        assertEq(token.totalSupply(), _initialSupply - 1);
    }

    function testFail_SlashAtUnlock() public {
        uint64 _unlock = uint64(block.timestamp) + 3;
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        vm.warp(_unlock);
        core.slash(_id, 1);
    }

    function testFail_SlashAfterUnlock() public {
        uint64 _unlock = uint64(block.timestamp) + 3;
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        vm.warp(_unlock + 1);
        core.slash(_id, 1);
    }

    function testFail_SlashUnlocked() public {
        uint64 _unlock = uint64(block.timestamp) + 3;
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        vm.warp(_unlock + 1);
        core.slash(_id, 1);
    }

    function testFail_SlashFromNonArbiter() public {
        uint64 _unlock = uint64(block.timestamp) + 3;
        address _arbiter = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        token.approve(address(core), 1);
        uint128 _id = core.deposit(_arbiter, 1, _unlock);
        vm.warp(_unlock - 1);
        core.slash(_id, 1);
    }

    function test_WithdrawAtUnlock() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        vm.warp(_unlock);
        core.withdraw(_id);
        assertEq(token.balanceOf(address(this)), _initialBalance);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function test_WithdrawAfterUnlock() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        vm.warp(_unlock + 1);
        core.withdraw(_id);
        assertEq(token.balanceOf(address(this)), _initialBalance);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function testFail_WithdrawBeforeUnlock() public {
        token.approve(address(core), 1);
        uint64 _unlock = uint64(block.timestamp) + 3;
        uint128 _id = core.deposit(address(this), 1, _unlock);
        vm.warp(_unlock - 1);
        core.withdraw(_id);
    }

    function test_WithdrawLocked() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        vm.warp(_unlock);
        core.withdraw(_id);
        assertEq(token.balanceOf(address(this)), _initialBalance);
        assertEq(token.balanceOf(address(core)), 0);
    }

    function testFail_WithdrawTwice() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        token.approve(address(core), 2);
        uint128 _id = core.deposit(address(this), 2, _unlock);
        vm.warp(_unlock);
        core.withdraw(_id);
        core.withdraw(_id);
    }

    function testFail_WithdrawFromNonDepositor() public {
        uint64 _unlock = uint64(block.timestamp) + 1;
        uint256 _initialBalance = token.balanceOf(address(this));
        address _other = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        token.approve(address(core), 1);
        uint128 _id = core.deposit(address(this), 1, _unlock);
        vm.warp(_unlock);
        vm.prank(_other);
        core.withdraw(_id);
        assertEq(token.balanceOf(address(this)), _initialBalance);
    }
}
