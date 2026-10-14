// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {FarmItems} from "../src/FarmItems.sol";
import {ItemMath} from "../src/lib/ItemMath.sol";

/// @dev Regression for imported finding 35715a98: document the pinned reveal-time rule.
contract PackMythicTimingTest is BaseTest {
    function testCapturedSeedCanYieldMythicAfterLevelTen() public {
        fund(10_000_000 ether);
        assertEq(d.farm.level(alice), 1);
        uint256 id = payPack(alice);
        (,,,, bool eligible,,,,) = d.packs.commits(id);
        assertFalse(eligible);
        bytes32 seed = _captureMythicRoll(id, 0);
        uint256 itemId = d.items.nextId();
        uint256 saved = vm.snapshotState();

        d.packs.resolve(id, 1);
        FarmItems.Item memory common = d.items.data(itemId);
        assertEq(common.rarity, 0);
        assertEq(ItemMath.baseHash(common.rarity), 10_000);

        assertTrue(vm.revertToState(saved));
        // The shared fixture supplies the actual age and XP gates, without mocking level().
        veteran(alice);
        uint256 balance = token.balanceOf(alice);
        uint256 poolBalance = token.balanceOf(address(d.pool));
        d.packs.resolve(id, 1);
        (,,, uint256 opened, bool mythic,, bytes32 preserved, bool fixedSeed,) = d.packs.commits(id);
        assertEq(preserved, seed);
        assertTrue(fixedSeed);
        assertTrue(mythic);
        assertEq(opened, 1);
        FarmItems.Item memory upgraded = d.items.data(itemId);
        assertEq(upgraded.holder, alice);
        assertEq(upgraded.kind, common.kind);
        assertEq(upgraded.rarity, 4);
        assertEq(ItemMath.baseHash(upgraded.rarity), 800_000);
        assertEq(d.items.inventory(alice), 3);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(address(d.pool)), poolBalance);
    }

    function testPartialReceiptRechecksLevelAndKeepsCapturedSeed() public {
        fund(10_000_000 ether);
        vm.prank(alice);
        uint256 id = d.packs.openPack(2);
        bytes32 seed = _captureMythicRoll(id, 3);
        d.packs.resolve(id, 1);
        (,,, uint256 opened, bool mythic,,,,) = d.packs.commits(id);
        assertEq(opened, 1);
        assertFalse(mythic);
        uint256 itemId = d.items.nextId();

        veteran(alice);
        d.packs.resolve(id, 1);
        bytes32 preserved;
        (,,, opened, mythic,, preserved,,) = d.packs.commits(id);
        assertEq(opened, 2);
        assertTrue(mythic);
        assertEq(preserved, seed);
        assertEq(d.items.data(itemId).rarity, 4);
        assertEq(d.items.inventory(alice), 6);
    }

    function _captureMythicRoll(uint256 id, uint256 slot) private returns (bytes32 seed) {
        (, uint64 target,,,,,,,) = d.packs.commits(id);
        bytes32 entropyHash;
        // Select a deterministic test block hash whose chosen slot rolls in the Mythic range.
        // This is a fixture, not a claim that a player controls production block hashes.
        for (uint256 nonce = 1; nonce <= 10_000; ++nonce) {
            entropyHash = keccak256(abi.encode("mythic timing regression", nonce));
            seed = keccak256(abi.encode(entropyHash, address(d.packs), id));
            if ((uint256(keccak256(abi.encode(seed, slot))) >> 64) % 10_000 >= 9970) break;
        }
        assertGe((uint256(keccak256(abi.encode(seed, slot))) >> 64) % 10_000, 9970);
        vm.roll(uint256(target) + 1);
        vm.setBlockhash(target, entropyHash);
        d.packs.captureEntropy(id);
        (,,,, bool mythic,, bytes32 captured, bool fixedSeed,) = d.packs.commits(id);
        assertEq(captured, seed);
        assertTrue(fixedSeed);
        assertFalse(mythic);
        assertLt(d.farm.level(alice), 10);
    }
}
