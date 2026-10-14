// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Params} from "src/Params.sol";
import "src/lib/Errors.sol";

contract JobAParamsBoundariesTest is Test {
    address private constant DESK = 0x5cb0686A4475D1F8a6c6e5240579080a4A05B609;
    Params private params;
    uint256 private constant START = 1_800_000_000;

    function setUp() public {
        vm.warp(START);
        params = new Params(DESK, 200, 1 ether);
    }

    function _key(uint256 seed) private pure returns (Params.Key k) {
        k = Params.Key(seed % 45);
        // The cap has a singleton domain and therefore no permitted change; tested separately below.
        if (k == Params.Key.HeartbeatCap) k = Params.Key.EmissionBps;
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EachMutableKeyChangesOnlyAfterItsOwnExactCooldown(uint8 seed, uint96 value) public {
        Params.Key k = _key(seed);
        uint256 old = params.get(k);
        (uint256 low, uint256 high) = params.bounds(k);
        uint256 lo = old - old / 10 > low ? old - old / 10 : low;
        uint256 hi = old + old / 10 < high ? old + old / 10 : high;
        uint256 next = bound(value, lo, hi);
        if (next == old) next = old > lo ? old - 1 : old + 1;
        vm.warp(START + 1 days - 1);
        vm.prank(DESK);
        vm.expectRevert(TooEarly.selector);
        params.set(k, next, "one second early");
        assertEq(params.get(k), old);
        assertEq(params.lastChanged(k), START);
        vm.warp(START + 1 days);
        vm.prank(DESK);
        params.set(k, next, "the exact boundary");
        assertEq(params.get(k), next);
        assertEq(params.lastChanged(k), START + 1 days);
        // A distinct key is still on its original clock.
        Params.Key other = k == Params.Key.EmissionBps ? Params.Key.TariffBps : Params.Key.EmissionBps;
        assertEq(params.lastChanged(other), START);
        uint256 delta = next > old ? next - old : old - next;
        assertLe(delta * 10, old);
        assertGe(next, low);
        assertLe(next, high);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_OutOfBoundsOrOverTenPercentChangesAreAtomic(uint8 seed, bool increase) public {
        Params.Key k = _key(seed);
        uint256 old = params.get(k);
        vm.warp(START + 1 days);
        uint256 rejected = increase ? old + old / 10 + 1 : old - old / 10 - 1;
        vm.prank(DESK);
        vm.expectRevert(InvalidValue.selector);
        params.set(k, rejected, "step too large");
        (uint256 lo, uint256 hi) = params.bounds(k);
        vm.prank(DESK);
        vm.expectRevert(InvalidValue.selector);
        params.set(k, increase ? hi + 1 : lo - 1, "outside hard bounds");
        assertEq(params.get(k), old);
        assertEq(params.lastChanged(k), START);
    }

    function testLetterLimitsAndNoOpDoNotConsumeCooldown() public {
        vm.warp(START + 1 days);
        vm.startPrank(DESK);
        vm.expectRevert(InvalidValue.selector);
        params.set(Params.Key.EmissionBps, 351, "");
        vm.expectRevert(InvalidValue.selector);
        params.set(Params.Key.EmissionBps, 351, string(new bytes(1025)));
        vm.expectRevert(InvalidValue.selector);
        params.set(Params.Key.EmissionBps, 350, "unchanged");
        vm.stopPrank();
        assertEq(params.lastChanged(Params.Key.EmissionBps), START);
        vm.prank(DESK);
        params.set(Params.Key.EmissionBps, 351, string(new bytes(1024)));
        assertEq(params.get(Params.Key.EmissionBps), 351);
        assertEq(params.lastChanged(Params.Key.EmissionBps), START + 1 days);
    }

    function testEveryKeyRejectsPublicCallerWithoutChangingValueOrCooldown() public {
        vm.warp(START + 10 days);
        for (uint256 i; i < 45; ++i) {
            Params.Key k = Params.Key(i);
            uint256 old = params.get(k);
            vm.expectRevert(Unauthorized.selector);
            params.set(k, old + 1, "no Desk authority");
            assertEq(params.get(k), old);
            assertEq(params.lastChanged(k), START);
        }
    }

    function testHeartbeatCapCannotChangeEvenAfterCooldown() public {
        vm.warp(START + 100 days);
        uint256[4] memory values = [uint256(0), 1 ether - 1, 1 ether, 1 ether + 1];
        for (uint256 i; i < values.length; ++i) {
            vm.prank(DESK);
            vm.expectRevert(InvalidValue.selector);
            params.set(Params.Key.HeartbeatCap, values[i], "fixed cap");
        }
        assertEq(params.get(Params.Key.HeartbeatCap), 1 ether);
        assertEq(params.lastChanged(Params.Key.HeartbeatCap), START);
    }

    function testConstructorRejectsBadDeskHeartbeatRateAndCap() public {
        vm.expectRevert(InvalidAddress.selector);
        new Params(address(0), 200, 1 ether);
        vm.expectRevert(InvalidValue.selector);
        new Params(DESK, 199, 1 ether);
        vm.expectRevert(InvalidValue.selector);
        new Params(DESK, 5001, 1 ether);
        vm.expectRevert(InvalidValue.selector);
        new Params(DESK, 200, 1 ether - 1);
        vm.expectRevert(InvalidValue.selector);
        new Params(DESK, 200, 1 ether + 1);
    }
}
