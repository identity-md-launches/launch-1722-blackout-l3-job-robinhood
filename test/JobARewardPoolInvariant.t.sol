// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {RewardPool} from "src/RewardPool.sol";
import {Params} from "src/Params.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockGameRegistry} from "./mocks/MockGameRegistry.sol";
import "src/lib/Errors.sol";

/// @dev Isolates the pool's custody boundary. The handler acts as the authorized rewards module;
/// core/router inflows are backed by actual transfers before notification. No storage is overwritten.
contract JobAPoolHandler is Test {
    uint256 public constant PRINCIPAL = 200_000_000 ether;
    uint256 public constant ACTOR_FUNDS = 100_000_000 ether;
    RewardPool public immutable pool;
    MockToken public immutable token;
    Params public immutable params;
    address public immutable core;
    address public immutable router;
    address[3] public actors;
    uint256 public rawFunding;
    uint256 public ordinaryIn;
    uint256 public excludedBeforeFunding;
    uint256 public booked;
    uint256 public cancelled;
    uint256 public paid;
    uint256 public fundedAt;
    uint256 public frozenPeriod;
    bool public activated;
    mapping(address => uint256) public donatedBy;
    mapping(address => uint256) public paidTo;

    constructor(RewardPool p, MockToken t, Params cfg, address c, address r, address[3] memory users) {
        pool = p;
        token = t;
        params = cfg;
        core = c;
        router = r;
        actors = users;
    }

    function transferPrincipal(uint256 amount) public {
        amount = bound(amount, 0, PRINCIPAL - rawFunding);
        token.transfer(address(pool), amount);
        rawFunding += amount;
    }

    function donate(uint256 who, uint256 amount) public {
        address p = actors[who % 3];
        uint256 balance = token.balanceOf(p);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(p);
        pool.donate(amount);
        ordinaryIn += amount;
        donatedBy[p] += amount;
        if (!activated) excludedBeforeFunding += amount;
    }

    function notifiedInflow(uint256 who, uint256 amount, bool viaCore) public {
        address p = actors[who % 3];
        amount = bound(amount, 0, token.balanceOf(p));
        vm.prank(p);
        token.transfer(address(pool), amount);
        vm.prank(viaCore ? core : router);
        pool.recordInflow(amount);
        ordinaryIn += amount;
        donatedBy[p] += amount;
        if (!activated) excludedBeforeFunding += amount;
    }

    function activate() public {
        if (activated) {
            vm.expectRevert(AlreadyDone.selector);
            pool.fundEndowment();
        } else if (rawFunding != PRINCIPAL) {
            vm.expectRevert(InsufficientBalance.selector);
            pool.fundEndowment();
        } else {
            frozenPeriod = params.get(Params.Key.DripPeriod);
            fundedAt = vm.getBlockTimestamp();
            pool.fundEndowment();
            activated = true;
        }
    }

    function reserve(uint256 amount) public {
        amount = bound(amount, 0, pool.available());
        pool.reserve(amount);
        booked += amount;
    }

    function pay(uint256 who, uint256 amount) public {
        address p = actors[who % 3];
        amount = bound(amount, 0, pool.reserved());
        pool.pay(p, amount);
        paid += amount;
        paidTo[p] += amount;
    }

    function recycle(uint256 amount) public {
        amount = bound(amount, 0, pool.reserved());
        pool.recycle(amount);
        cancelled += amount;
    }

    function elapse(uint256 seconds_) public {
        uint256 locked = pool.lockedEndowment();
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 14 days));
        assertLe(pool.lockedEndowment(), locked, "vesting cannot relock principal");
    }

    function changeFutureDrip(bool shorten) public {
        uint256 old = params.get(Params.Key.DripPeriod);
        uint256 next = shorten ? old - old / 10 : old + old / 10;
        if (next < 14 days) next = 14 days;
        if (next > 56 days) next = 56 days;
        uint256 readyAt = params.lastChanged(Params.Key.DripPeriod) + 1 days;
        if (vm.getBlockTimestamp() < readyAt) vm.warp(readyAt);
        vm.prank(params.swarmWallet());
        if (next == old) vm.expectRevert(InvalidValue.selector);
        params.set(Params.Key.DripPeriod, next, "test: future schedules only");
    }

    function rejectUnprivileged(uint256 who, uint256 amount) public {
        address p = actors[who % 3];
        vm.startPrank(p);
        vm.expectRevert(Unauthorized.selector);
        pool.reserve(amount);
        vm.expectRevert(Unauthorized.selector);
        pool.recycle(amount);
        vm.expectRevert(Unauthorized.selector);
        pool.pay(p, amount);
        vm.expectRevert(Unauthorized.selector);
        pool.recordInflow(amount);
        vm.stopPrank();
    }

    function rejectOverdraw() public {
        uint256 excess = pool.available() + 1;
        vm.expectRevert(InsufficientBalance.selector);
        pool.reserve(excess);
        excess = pool.reserved() + 1;
        vm.expectRevert(stdError.arithmeticError);
        pool.recycle(excess);
        vm.expectRevert(stdError.arithmeticError);
        pool.pay(actors[0], excess);
    }

    function rejectPaymentFailure(uint256 who, uint256 amount) public {
        if (pool.reserved() == 0) return;
        amount = bound(amount, 1, pool.reserved());
        token.setFail(true);
        vm.expectRevert("test transfer failure");
        pool.pay(actors[who % 3], amount);
        token.setFail(false);
    }

    /// @dev Not a fuzz target: proves withdrawal liveness at the end of every random sequence.
    function finishAndDrain() external {
        if (!activated) {
            transferPrincipal(PRINCIPAL - rawFunding);
            activate();
        }
        if (vm.getBlockTimestamp() < fundedAt + frozenPeriod) vm.warp(fundedAt + frozenPeriod);
        reserve(pool.available());
        pay(0, pool.reserved());
        assertEq(token.balanceOf(address(pool)), 0, "all vested funds remain payable");
    }
}

abstract contract JobAPoolInvariantBase is Test {
    MockToken internal token;
    RewardPool internal pool;
    Params internal params;
    JobAPoolHandler internal handler;
    address[3] internal actors;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        token = new MockToken();
        params = new Params(0x5cb0686A4475D1F8a6c6e5240579080a4A05B609, 200, 1 ether);
        // The registry stand-in is used only for isolated pool accounting, never for launch authentication.
        MockGameRegistry registry = new MockGameRegistry(
            address(token),
            address(params),
            makeAddr("pool market fixture"),
            block.timestamp,
            keccak256("pool test root"),
            26_182_375,
            200_000_000 ether
        );
        pool = new RewardPool(address(registry));
        address core = makeAddr("pool core fixture");
        address router = makeAddr("pool router fixture");
        actors = [makeAddr("pool alice"), makeAddr("pool bob"), makeAddr("pool carol")];
        handler = new JobAPoolHandler(pool, token, params, core, router, actors);
        registry.setModule(1, address(handler));
        registry.setModule(2, core);
        registry.setModule(6, router);
        token.transfer(address(handler), 200_000_000 ether);
        for (uint256 i; i < 3; ++i) {
            token.transfer(actors[i], 100_000_000 ether);
            vm.prank(actors[i]);
            token.approve(address(pool), type(uint256).max);
            targetSender(actors[i]);
        }
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.transferPrincipal.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.notifiedInflow.selector;
        selectors[3] = handler.activate.selector;
        selectors[4] = handler.reserve.selector;
        selectors[5] = handler.pay.selector;
        selectors[6] = handler.recycle.selector;
        selectors[7] = handler.elapse.selector;
        selectors[8] = handler.changeFutureDrip.selector;
        selectors[9] = handler.rejectUnprivileged.selector;
        selectors[10] = handler.rejectOverdraw.selector;
        selectors[11] = handler.rejectPaymentFailure.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_CashAndReservationsMatchIndependentFlows() public view {
        assertEq(token.balanceOf(address(pool)) + handler.paid(), handler.rawFunding() + handler.ordinaryIn());
        assertEq(pool.reserved() + handler.paid() + handler.cancelled(), handler.booked());
        assertEq(pool.otherInflow(), handler.excludedBeforeFunding());
        assertLe(pool.reserved(), token.balanceOf(address(pool)));
        for (uint256 i; i < 3; ++i) {
            address p = actors[i];
            assertEq(token.balanceOf(p) + handler.donatedBy(p), 100_000_000 ether + handler.paidTo(p));
        }
    }

    function invariant_PrincipalIsLockedUntilFundedAndScheduleIsFrozen() public view {
        assertEq(pool.endowed(), handler.activated());
        if (!handler.activated()) {
            assertEq(pool.available(), 0);
            assertEq(pool.reserved(), 0);
            assertEq(pool.lockedEndowment(), 200_000_000 ether);
            assertEq(pool.dripStart(), 0);
        } else {
            assertEq(pool.dripStart(), handler.fundedAt());
            assertEq(pool.dripPeriod(), handler.frozenPeriod());
            // Bound payouts by the promised linear schedule independently of available()/lockedEndowment().
            uint256 elapsed = vm.getBlockTimestamp() - handler.fundedAt();
            if (elapsed > handler.frozenPeriod()) elapsed = handler.frozenPeriod();
            uint256 vested = 200_000_000 ether * elapsed / handler.frozenPeriod();
            assertEq(pool.lockedEndowment() + vested, 200_000_000 ether);
            assertEq(token.balanceOf(address(pool)), pool.available() + pool.reserved() + pool.lockedEndowment());
            assertLe(handler.paid() + pool.reserved(), handler.ordinaryIn() + vested);
        }
    }

    function invariant_FixedTokenSupplyIsConserved() public view {
        uint256 sum =
            token.balanceOf(address(this)) + token.balanceOf(address(handler)) + token.balanceOf(address(pool));
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum);
    }

    function afterInvariant() public {
        handler.finishAndDrain();
        invariant_CashAndReservationsMatchIndependentFlows();
        invariant_PrincipalIsLockedUntilFundedAndScheduleIsFrozen();
        invariant_FixedTokenSupplyIsConserved();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract JobAPoolUnfundedInvariantTest is JobAPoolInvariantBase {
    function setUp() public override {
        super.setUp();
        // Even ordinary inflows large enough to cover principal cannot activate it.
        handler.donate(0, 100_000_000 ether);
        handler.notifiedInflow(1, 100_000_000 ether, true);
        handler.activate();
        handler.transferPrincipal(200_000_000 ether - 1);
        handler.activate();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract JobAPoolFundedInvariantTest is JobAPoolInvariantBase {
    function setUp() public override {
        super.setUp();
        handler.transferPrincipal(200_000_000 ether);
        handler.activate();
        handler.elapse(1 days);
        handler.reserve(1_000 ether);
        handler.pay(1, 100 ether);
        handler.recycle(100 ether);
    }
}
