// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RewardPool} from "src/RewardPool.sol";
import {Params} from "src/Params.sol";
import {MockGameRegistry} from "./mocks/MockGameRegistry.sol";
import "src/lib/Errors.sol";

/// @dev Adversarial external dependency, not a model of the recorded production token.
contract JobATokenBehavior is ERC20 {
    enum Mode {
        Normal,
        ShortDelivery,
        ReturnFalse,
        NoReturn,
        Paused
    }
    Mode public mode;
    address public immutable collector;
    error TokenPaused();

    constructor(address collector_) ERC20("test transfer behavior", "TEST") {
        collector = collector_;
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.Paused) revert TokenPaused();
        bool ok = super.transfer(to, amount);
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.Paused) revert TokenPaused();
        bool ok = super.transferFrom(from, to, amount);
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return ok;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (mode == Mode.ShortDelivery && from != address(0) && to != address(0) && amount != 0) {
            super._update(from, to, amount - 1);
            super._update(from, collector, 1);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract JobAPoolFailurePathsTest is Test {
    uint256 private constant PRINCIPAL = 200_000_000 ether;
    JobATokenBehavior private token;
    RewardPool private pool;
    address private alice;
    address private collector;

    function setUp() public {
        vm.warp(1_800_000_000);
        alice = makeAddr("pool recipient");
        collector = makeAddr("test transfer fee recipient");
        token = new JobATokenBehavior(collector);
        Params params = new Params(0x5cb0686A4475D1F8a6c6e5240579080a4A05B609, 200, 1 ether);
        MockGameRegistry registry = new MockGameRegistry(
            address(token),
            address(params),
            makeAddr("unused pool market"),
            block.timestamp,
            keccak256("pool boundary root"),
            26_182_375,
            PRINCIPAL
        );
        registry.setModule(1, address(this));
        pool = new RewardPool(address(registry));
        token.approve(address(pool), 100 ether);
    }

    function _fund() private {
        token.transfer(address(pool), PRINCIPAL);
        pool.fundEndowment();
    }

    function testShortIncomingTransferRevertsWithoutCountingOrKeepingDonation() public {
        uint256 donor = token.balanceOf(address(this));
        token.setMode(JobATokenBehavior.Mode.ShortDelivery);
        vm.expectRevert(InvalidValue.selector);
        pool.donate(100 ether);
        assertEq(token.balanceOf(address(this)), donor);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(collector), 0);
        assertEq(token.allowance(address(this), address(pool)), 100 ether);
        assertEq(pool.otherInflow(), 0);
    }

    function testFalseAndPausedTokenDonationsRevertWithoutAccountingChanges() public {
        token.setMode(JobATokenBehavior.Mode.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        pool.donate(100 ether);
        token.setMode(JobATokenBehavior.Mode.Paused);
        vm.expectRevert(JobATokenBehavior.TokenPaused.selector);
        pool.donate(100 ether);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(pool.otherInflow(), 0);
        assertEq(token.allowance(address(this), address(pool)), 100 ether);
    }

    function testNoReturnERC20DonationAndPaymentUseActualBalances() public {
        _fund();
        token.setMode(JobATokenBehavior.Mode.NoReturn);
        pool.donate(100 ether);
        assertEq(pool.available(), 100 ether);
        pool.reserve(100 ether);
        pool.pay(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(pool)), PRINCIPAL);
        assertEq(pool.reserved(), 0);
        assertEq(pool.available(), 0);
    }

    function testRejectedRecipientsOverdrawAndTokenFailurePreserveReservation() public {
        _fund();
        pool.donate(100 ether);
        pool.reserve(100 ether);
        vm.expectRevert(InvalidAddress.selector);
        pool.pay(address(0), 1);
        vm.expectRevert(InvalidAddress.selector);
        pool.pay(address(pool), 1);
        vm.expectRevert(stdError.arithmeticError);
        pool.pay(alice, 100 ether + 1);
        token.setMode(JobATokenBehavior.Mode.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        pool.pay(alice, 100 ether);
        token.setMode(JobATokenBehavior.Mode.Paused);
        vm.expectRevert(JobATokenBehavior.TokenPaused.selector);
        pool.pay(alice, 100 ether);
        assertEq(pool.reserved(), 100 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(pool)), PRINCIPAL + 100 ether);
        token.setMode(JobATokenBehavior.Mode.Normal);
        pool.pay(alice, 100 ether);
        assertEq(pool.reserved(), 0);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function testZeroDonationAndUnreservedPaymentCannotCreateFunds() public {
        vm.expectRevert(InvalidValue.selector);
        pool.donate(0);
        _fund();
        vm.expectRevert(InsufficientBalance.selector);
        pool.reserve(1);
        vm.expectRevert(stdError.arithmeticError);
        pool.pay(alice, 1);
        vm.expectRevert(stdError.arithmeticError);
        pool.recycle(1);
        assertEq(token.balanceOf(address(pool)), PRINCIPAL);
        assertEq(pool.reserved(), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function testOneWeiFundingShortfallUsesPlainTransferAndCannotBackdateDrip() public {
        token.transfer(address(pool), PRINCIPAL - 1);
        pool.donate(1);
        vm.expectRevert(InsufficientBalance.selector);
        pool.fundEndowment();
        assertFalse(pool.endowed());
        assertEq(pool.available(), 0);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        token.transfer(address(pool), 1);
        vm.prank(alice); // activation is permissionless; no donor or binder privilege is inferred
        pool.fundEndowment();
        assertEq(pool.dripStart(), vm.getBlockTimestamp());
        assertEq(pool.lockedEndowment(), PRINCIPAL);
        assertEq(pool.available(), 1);
    }
}
