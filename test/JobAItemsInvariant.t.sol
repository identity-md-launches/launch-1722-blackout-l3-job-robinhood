// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FarmItems} from "src/FarmItems.sol";
import {MockGameRegistry} from "./mocks/MockGameRegistry.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "src/lib/Errors.sol";

contract JobAItemCoreReceiver is ERC1155Holder {}

/// @dev Exercises the item ledger's authorized transitions in isolation. The core receiver models custody;
/// gameplay/room eligibility is tested separately against the actual FarmCore in JobAFailurePathsTest.
contract JobAItemsHandler is Test {
    FarmItems public immutable items;
    address public immutable core;
    address public immutable minter;
    address[3] public actors;
    uint256 public minted;
    uint256 public burned;
    mapping(uint256 => address) public originalHolder;
    mapping(uint256 => bool) public destroyed;
    mapping(uint256 => bool) public inCore;

    constructor(FarmItems items_, address core_, address minter_, address[3] memory actors_) {
        items = items_;
        core = core_;
        minter = minter_;
        actors = actors_;
    }

    function mint(uint256 who, uint8 kind, uint8 rarity, bool starter) public {
        address p = actors[who % 3];
        if (items.inventory(p) == items.capacity(p)) {
            vm.prank(minter);
            vm.expectRevert(InvalidValue.selector);
            items.mint(p, kind % 12, rarity % 5, starter);
            return;
        }
        vm.prank(minter);
        uint256 id = items.mint(p, kind % 12, rarity % 5, starter);
        assertEq(id, ++minted, "IDs must not be reused after a burn");
        originalHolder[id] = p;
    }

    function equip(uint256 seed) public {
        uint256 id = bound(seed, 1, minted);
        if (destroyed[id] || inCore[id]) return;
        vm.prank(core);
        items.equip(originalHolder[id], id);
        inCore[id] = true;
    }

    function unequip(uint256 seed) public {
        uint256 id = bound(seed, 1, minted);
        if (destroyed[id] || !inCore[id]) return;
        address p = originalHolder[id];
        if (items.inventory(p) == items.capacity(p)) {
            vm.prank(core);
            vm.expectRevert(InvalidValue.selector);
            items.unequip(p, id);
        } else {
            vm.prank(core);
            items.unequip(p, id);
            inCore[id] = false;
        }
    }

    function destroy(uint256 seed) public {
        uint256 id = bound(seed, 1, minted);
        vm.prank(core);
        if (destroyed[id]) {
            vm.expectRevert(InvalidValue.selector);
            items.destroy(id);
        } else {
            items.destroy(id);
            destroyed[id] = true;
            inCore[id] = false;
            ++burned;
        }
    }

    function maintain(uint256 seed, uint16 health, uint8 clock) public {
        uint256 id = bound(seed, 1, minted);
        if (destroyed[id]) return;
        health = uint16(bound(health, 0, 10_000));
        clock = uint8(bound(clock, 0, 16));
        FarmItems.Item memory before_ = items.data(id);
        vm.prank(core);
        items.maintain(id, health, clock);
        FarmItems.Item memory after_ = items.data(id);
        assertEq(after_.holder, before_.holder);
        assertEq(after_.kind, before_.kind);
        assertEq(after_.rarity, before_.rarity);
        assertEq(after_.starter, before_.starter);
        assertEq(after_.equipped, before_.equipped);
        assertEq(after_.durability, health);
        assertEq(after_.overclock, clock);
    }

    function expand(uint256 who) public {
        address p = actors[who % 3];
        uint256 old = items.capacity(p);
        vm.prank(core);
        items.expand(p);
        assertEq(items.capacity(p), old + 5);
    }

    function rejectWrongOwner(uint256 seed) public {
        uint256 id = bound(seed, 1, minted);
        if (destroyed[id]) return;
        address owner = originalHolder[id];
        address stranger = owner == actors[0] ? actors[1] : actors[0];
        vm.prank(core);
        vm.expectRevert(Unauthorized.selector);
        items.equip(stranger, id);
    }

    function rejectPublicMutation(uint256 seed, uint256 who) public {
        uint256 id = bound(seed, 1, minted);
        address p = actors[who % 3];
        vm.startPrank(p);
        vm.expectRevert(Unauthorized.selector);
        items.mint(p, 0, 0, false);
        vm.expectRevert(Unauthorized.selector);
        items.destroy(id);
        vm.expectRevert(Unauthorized.selector);
        items.maintain(id, 10_000, 0);
        vm.expectRevert(Unauthorized.selector);
        items.expand(p);
        vm.expectRevert(Unauthorized.selector);
        items.setApprovalForAll(actors[(who % 3 + 1) % 3], true);
        vm.stopPrank();
    }

    function rejectDirectTransfer(uint256 seed) public {
        uint256 id = bound(seed, 1, minted);
        if (destroyed[id] || inCore[id]) return;
        address p = originalHolder[id];
        address to = p == actors[0] ? actors[1] : actors[0];
        vm.prank(p);
        vm.expectRevert(Unauthorized.selector);
        items.safeTransferFrom(p, to, id, 1, "");
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = 1;
        vm.prank(p);
        vm.expectRevert(Unauthorized.selector);
        items.safeBatchTransferFrom(p, to, ids, amounts, "");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract JobAItemsInvariantTest is Test {
    FarmItems private items;
    JobAItemsHandler private handler;
    address private core;
    address[3] private actors;

    function setUp() public {
        actors = [makeAddr("items alice"), makeAddr("items bob"), makeAddr("items carol")];
        MockGameRegistry registry = new MockGameRegistry(
            makeAddr("unused item token"),
            makeAddr("unused item params"),
            makeAddr("unused item market"),
            1_800_000_000,
            keccak256("item test root"),
            26_182_375,
            200_000_000 ether
        );
        core = address(new JobAItemCoreReceiver());
        address minter = makeAddr("item pack minter");
        registry.setModule(2, core);
        registry.setModule(4, minter);
        registry.setModule(5, makeAddr("item starter fixture"));
        registry.setModule(8, makeAddr("item season fixture"));
        registry.setModule(9, makeAddr("item engine fixture"));
        registry.setModule(10, makeAddr("item economy fixture"));
        registry.setModule(11, makeAddr("item enhancement fixture"));
        registry.setModule(12, makeAddr("item civic fixture"));
        items = new FarmItems(address(registry));
        handler = new JobAItemsHandler(items, core, minter, actors);
        for (uint256 i; i < 3; ++i) {
            handler.mint(i, uint8(i), 0, false);
            targetSender(actors[i]);
        }
        handler.equip(1);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.equip.selector;
        selectors[2] = handler.unequip.selector;
        selectors[3] = handler.destroy.selector;
        selectors[4] = handler.maintain.selector;
        selectors[5] = handler.expand.selector;
        selectors[6] = handler.rejectWrongOwner.selector;
        selectors[7] = handler.rejectPublicMutation.selector;
        selectors[8] = handler.rejectDirectTransfer.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_EveryLiveItemHasExactlyOneUnitInCorrectCustody() public view {
        uint256 live;
        for (uint256 id = 1; id <= handler.minted(); ++id) {
            uint256 supply = items.balanceOf(core, id);
            for (uint256 j; j < 3; ++j) {
                supply += items.balanceOf(actors[j], id);
            }
            FarmItems.Item memory x = items.data(id);
            if (handler.destroyed(id)) {
                assertEq(supply, 0);
                assertEq(x.holder, address(0));
            } else {
                ++live;
                assertEq(supply, 1);
                address owner = handler.originalHolder(id);
                assertEq(x.holder, owner);
                assertEq(x.equipped, handler.inCore(id));
                assertEq(items.balanceOf(handler.inCore(id) ? core : owner, id), 1);
            }
        }
        assertEq(live + handler.burned(), handler.minted());
        assertEq(items.nextId(), handler.minted() + 1);
    }

    function invariant_OwnerEnumerationContainsEveryLiveItemOnce() public view {
        uint256 totalOwned;
        for (uint256 a; a < 3; ++a) {
            address p = actors[a];
            uint256[] memory ids = items.itemsByOwner(p, 0, 100);
            assertEq(ids.length, items.ownedCount(p));
            totalOwned += ids.length;
            uint256 inventory;
            bool[] memory seen = new bool[](handler.minted() + 1);
            for (uint256 i; i < ids.length; ++i) {
                uint256 id = ids[i];
                assertFalse(seen[id], "swap-and-pop must not duplicate an item");
                seen[id] = true;
                assertFalse(handler.destroyed(id));
                assertEq(handler.originalHolder(id), p);
                if (!handler.inCore(id)) ++inventory;
            }
            for (uint256 id = 1; id <= handler.minted(); ++id) {
                if (handler.originalHolder(id) == p && !handler.destroyed(id)) assertTrue(seen[id]);
            }
            assertEq(items.inventory(p), inventory);
            assertLe(inventory, items.capacity(p));
        }
        assertEq(totalOwned + handler.burned(), handler.minted());
    }

    function testSwapAndPopOfMiddleAndLastItemsPreservesEnumeration() public {
        handler.mint(0, 3, 1, false); // Alice's second item
        handler.mint(0, 4, 1, false); // Alice's third item
        handler.destroy(4);
        invariant_OwnerEnumerationContainsEveryLiveItemOnce();
        handler.destroy(5);
        handler.destroy(1); // destruction from the core's custody
        invariant_OwnerEnumerationContainsEveryLiveItemOnce();
        invariant_EveryLiveItemHasExactlyOneUnitInCorrectCustody();
    }
}
