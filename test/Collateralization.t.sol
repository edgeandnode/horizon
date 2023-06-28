// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Burnable} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Collateralization, Deposit} from "../src/Collateralization.sol";

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

        uint256 index = 0;
        while (index < actors.length) {
            collateralization.token().transfer(actors[index], tokenSupply / (actors.length));
            index += 1;
        }
    }

    function warp(uint256 blocks) public {
        vm.warp(block.timestamp + bound(blocks, 1, 10));
    }

    function prepare(uint256 value, uint256 expiration, uint256 sender, uint256 arbiter, bool _fund)
        public
        returns (uint128)
    {
        uint256 _value = bound(value, 0, tokenSupply / 10);
        vm.startPrank(_genActor(sender));
        collateralization.token().approve(address(collateralization), _value);
        uint128 id = collateralization.prepare(_value, _genExpiration(expiration), _genActor(arbiter), _fund);
        vm.stopPrank();
        depositIDs.push(id);
        return id;
    }

    function fund(uint256 sender, uint256 id) public {
        vm.prank(_genActor(sender));
        collateralization.fund(_genID(id));
    }

    function withdraw(uint256 sender, uint256 id) public {
        uint128 id_ = _genID(id);
        vm.prank(_genActor(sender));
        collateralization.withdraw(id_);
        _removeDepositID(id_);
    }

    function slash(uint256 sender, uint256 id) public {
        uint128 _id = _genID(id);
        vm.prank(_genActor(sender));
        collateralization.slash(_id);
        _removeDepositID(_id);
    }

    function fundedDepositTotal() public view returns (uint256) {
        uint256 total = 0;
        uint64 index = 0;
        while (index < depositIDs.length) {
            uint128 id = depositIDs[index];
            Deposit memory deposit = collateralization.getDeposit(id);
            if (deposit.depositor != address(0)) {
                total += deposit.value;
            }
            index += 1;
        }
        return total;
    }

    function _removeDepositID(uint128 id) internal {
        uint256 index = 0;
        while (index < depositIDs.length) {
            if (depositIDs[index] == id) {
                depositIDs[index] = depositIDs[depositIDs.length - 1];
                depositIDs.pop();
                return;
            }
            index += 1;
        }
    }

    function _genID(uint256 seed) internal view returns (uint128) {
        uint256 index = bound(seed, 0, depositIDs.length);
        if (index == depositIDs.length) {
            return type(uint128).max;
        }
        return depositIDs[index];
    }

    function _genActor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _genExpiration(uint256 seed) internal view returns (uint128) {
        return uint128(bound(seed, 0, 20));
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
        assertEq(token.balanceOf(address(handler.collateralization())), handler.fundedDepositTotal());
    }
}

contract CollateralizationUnitTests is Test {
    TestToken public token;
    Collateralization public collateralization;

    function setUp() public {
        token = new TestToken(1_000);
        collateralization = new Collateralization(token);
    }

    function test_Prepare() public {
        uint128 expiration = uint128(block.timestamp) + 1;
        uint256 initialBalance = token.balanceOf(address(this));

        uint128 id1 = collateralization.prepare(1, expiration, address(0), false);
        assertEq(token.balanceOf(address(this)), initialBalance);
        assertEq(token.balanceOf(address(collateralization)), 0);
        assertEq(collateralization.getDeposit(id1).depositor, address(0));
        assert(!collateralization.isSlashable(id1));

        token.approve(address(collateralization), 1);
        uint128 id2 = collateralization.prepare(1, expiration, address(0), true);
        assertEq(token.balanceOf(address(this)), initialBalance - 1);
        assertEq(token.balanceOf(address(collateralization)), 1);
        assertEq(collateralization.getDeposit(id2).depositor, address(this));
        assert(collateralization.isSlashable(id2));

        assertNotEq(id1, id2);
    }

    function testFail_PrepareExpirationAtBlock() public {
        token.approve(address(collateralization), 10);
        uint128 expiration = uint128(block.timestamp);
        collateralization.prepare(10, expiration, address(0), false);
    }

    function testFail_PrepareExpirationBeforeBlock() public {
        token.approve(address(collateralization), 10);
        uint128 expiration = uint128(block.timestamp) - 1;
        collateralization.prepare(10, expiration, address(0), false);
    }

    function test_Fund() public {
        uint128 expiration = uint128(block.timestamp) + 1;
        uint256 initialBalance = token.balanceOf(address(this));
        uint128 id = collateralization.prepare(1, expiration, address(0), false);
        token.approve(address(collateralization), 1);
        collateralization.fund(id);
        assertEq(token.balanceOf(address(this)), initialBalance - 1);
        assertEq(token.balanceOf(address(collateralization)), 1);
        assertEq(collateralization.getDeposit(id).depositor, address(this));
        assert(collateralization.isSlashable(id));
    }

    function testFail_FundAtExpiration() public {
        uint128 expiration = uint128(block.timestamp) + 1;
        uint128 id = collateralization.prepare(1, expiration, address(0), false);
        token.approve(address(collateralization), 1);
        vm.warp(expiration);
        collateralization.fund(id);
    }

    function testFail_FundAfterExpiration() public {
        uint128 expiration = uint128(block.timestamp) + 1;
        uint128 id = collateralization.prepare(1, expiration, address(0), false);
        token.approve(address(collateralization), 1);
        vm.warp(expiration + 1);
        collateralization.fund(id);
    }

    function testFail_FundNoPrepare() public {
        token.approve(address(collateralization), 1);
        collateralization.fund(1);
    }

    function test_WithdrawAtExpiration() public {
        uint128 expiration = uint128(block.timestamp) + 1;
        uint256 initialBalance = token.balanceOf(address(this));
        token.approve(address(collateralization), 1);
        uint128 id = collateralization.prepare(1, expiration, address(0), true);
        vm.warp(expiration);
        collateralization.withdraw(id);
        assertEq(token.balanceOf(address(this)), initialBalance);
        assertEq(token.balanceOf(address(collateralization)), 0);
        assertEq(collateralization.isSlashable(id), false);
    }

    function test_WithdrawAfterExpiration() public {
        uint128 expiration = uint128(block.timestamp) + 1;
        uint256 initialBalance = token.balanceOf(address(this));
        token.approve(address(collateralization), 1);
        uint128 id = collateralization.prepare(1, expiration, address(0), true);
        vm.warp(expiration + 1);
        collateralization.withdraw(id);
        assertEq(token.balanceOf(address(this)), initialBalance);
        assertEq(token.balanceOf(address(collateralization)), 0);
    }

    function testFail_WithdrawBeforeExpiration() public {
        token.approve(address(collateralization), 1);
        uint128 expiration = uint128(block.timestamp) + 3;
        uint128 id = collateralization.prepare(1, expiration, address(0), true);
        vm.warp(expiration - 1);
        collateralization.withdraw(id);
    }

    function testFail_WithdrawNoPrepare() public {
        collateralization.withdraw(0);
    }

    function test_WithdrawFromNonDepositor() public {
        uint128 expiration = uint128(block.timestamp) + 1;
        uint256 initialBalance = token.balanceOf(address(this));
        address other = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        vm.prank(other);
        uint128 id = collateralization.prepare(1, expiration, address(0), false);
        token.approve(address(collateralization), 1);
        collateralization.fund(id);
        assertEq(token.balanceOf(address(this)), initialBalance - 1);
        vm.warp(expiration);
        vm.prank(other);
        collateralization.withdraw(id);
        assertEq(token.balanceOf(address(this)), initialBalance);
    }

    function test_Slash() public {
        uint128 expiration = uint128(block.timestamp) + 3;
        address arbiter = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        uint256 initialSupply = token.totalSupply();
        token.approve(address(collateralization), 1);
        uint128 id = collateralization.prepare(1, expiration, arbiter, true);
        vm.warp(expiration - 1);
        vm.prank(arbiter);
        collateralization.slash(id);
        assertEq(collateralization.isSlashable(id), false);
        assertEq(token.totalSupply(), initialSupply - 1);
    }

    function testFail_SlashAtExpiration() public {
        uint128 expiration = uint128(block.timestamp) + 3;
        token.approve(address(collateralization), 1);
        uint128 id = collateralization.prepare(1, expiration, address(this), true);
        vm.warp(expiration);
        collateralization.slash(id);
    }

    function testFail_SlashAfterExpiration() public {
        uint128 expiration = uint128(block.timestamp) + 3;
        token.approve(address(collateralization), 1);
        uint128 id = collateralization.prepare(1, expiration, address(this), true);
        vm.warp(expiration + 1);
        collateralization.slash(id);
    }

    function testFail_SlashFromNonArbiter() public {
        uint128 expiration = uint128(block.timestamp) + 3;
        address arbiter = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        token.approve(address(collateralization), 1);
        uint128 id = collateralization.prepare(1, expiration, arbiter, true);
        vm.warp(expiration - 1);
        collateralization.slash(id);
    }

    function testFail_SlashNoFund() public {
        uint128 expiration = uint128(block.timestamp) + 1;
        uint128 id = collateralization.prepare(1, expiration, address(this), false);
        collateralization.slash(id);
    }
}
