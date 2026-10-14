// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PackSale} from "src/PackSale.sol";
import {FarmItems} from "src/FarmItems.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "src/lib/Errors.sol";

/// @dev A recipient which can refuse a later item in a three-item pack, or attempt recursive resolution.
contract JobAReceiver is ERC1155Holder {
    error RefusedItem();
    uint256 public received;
    uint256 public rejectAt;
    PackSale public packs;
    uint256 public receipt;
    bytes4 public callbackError;
    bool public callbackSucceeded;

    function configure(uint256 rejectAt_, PackSale packs_, uint256 receipt_) external {
        rejectAt = rejectAt_;
        packs = packs_;
        receipt = receipt_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public override returns (bytes4) {
        ++received;
        if (received == rejectAt) revert RefusedItem();
        if (address(packs) != address(0)) {
            bytes memory reason;
            (callbackSucceeded, reason) = address(packs).call(abi.encodeCall(packs.resolve, (receipt, 1)));
            if (reason.length >= 4) callbackError = bytes4(reason);
        }
        return this.onERC1155Received.selector;
    }
}

/// @notice The real pinned game graph from BaseTest, with external market/token/oracle fixtures.
/// Launch-disabled features stay disabled; no Economy.lock path is used to hide the accepted resync finding.
contract JobAFailurePathsTest is BaseTest {
    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function _purchaseState(address recipient) private view returns (bytes32) {
        bytes32 farmState = keccak256(
            abi.encode(
                d.packs.sold(),
                d.packs.nextId(),
                d.farm.paidPacks(recipient),
                d.farm.xp(recipient),
                d.farm.hasFarm(recipient),
                d.rewards.nextTotalHash(),
                d.rewards.epochData(d.rewards.epoch()).sales
            )
        );
        bytes32 cashState = keccak256(
            abi.encode(
                token.balanceOf(alice),
                token.balanceOf(recipient),
                token.balanceOf(address(d.packs)),
                token.balanceOf(address(d.fees)),
                token.balanceOf(address(d.pool)),
                d.fees.teamTokens(),
                d.fees.heartbeatTokens(),
                d.pool.otherInflow()
            )
        );
        return keccak256(abi.encode(farmState, cashState));
    }

    function _receipt(uint256 id) private view returns (PackSale.Commit memory c) {
        (bool ok, bytes memory encoded) = address(d.packs).staticcall(abi.encodeCall(d.packs.commits, (id)));
        require(ok, "receipt getter failed");
        c = abi.decode(encoded, (PackSale.Commit));
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_MaxCostFailureDoesNotConsumePaymentOrCreateGift(uint8 count) public {
        uint256 n = bound(count, 1, 12);
        uint256 quote = d.packs.quote(n);
        bytes32 before_ = _purchaseState(bob);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.packs.buyPacksFor(bob, n, quote - 1);
        assertEq(_purchaseState(bob), before_);
        vm.prank(alice);
        uint256 id = d.packs.buyPacksFor(bob, n, quote);
        assertEq(_receipt(id).player, bob);
        assertEq(_receipt(id).count, n);
        assertEq(d.farm.paidPacks(bob), n);
    }

    function testRejectedPurchaseInputsLeaveNoReceiptOrRegisteredFarm() public {
        bytes32 before_ = _purchaseState(bob);
        vm.startPrank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.packs.buyPacksFor(bob, 0, type(uint256).max);
        vm.expectRevert(InvalidAddress.selector);
        d.packs.buyPacksFor(address(0), 1, type(uint256).max);
        vm.expectRevert(InvalidValue.selector);
        d.packs.openPack{value: 1}(1);
        vm.stopPrank();
        assertEq(_purchaseState(bob), before_);
        assertEq(address(d.packs).balance, 0);
    }

    function test_ERC20PaymentFailureRollsBackGiftXPAndSalesBeforeRetry() public {
        uint256 cost = d.packs.quote(2);
        bytes32 before_ = _purchaseState(bob);
        token.setFail(true);
        vm.prank(alice);
        vm.expectRevert("test transfer failure");
        d.packs.buyPacksFor(bob, 2, cost);
        assertEq(_purchaseState(bob), before_);
        token.setFail(false);
        vm.prank(alice);
        uint256 id = d.packs.buyPacksFor(bob, 2, cost);
        assertEq(id, 1);
        assertEq(d.farm.paidPacks(bob), 2);
        assertEq(d.farm.paidPacks(alice), 0);
        assertEq(d.farm.xp(bob), 50);
    }

    function testMissingAllowanceRollsBackEffectsBeforeTransferFrom() public {
        vm.prank(alice);
        token.approve(address(d.packs), 0);
        bytes32 before_ = _purchaseState(bob);
        uint256 cost = d.packs.price();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(d.packs), 0, cost)
        );
        d.packs.buyPackFor(bob);
        assertEq(_purchaseState(bob), before_);
    }

    function testUnfundedPoolAndWrongHookRouterRefusePayment() public {
        bytes32 before_ = _purchaseState(bob);
        vm.mockCall(address(d.pool), abi.encodeWithSignature("endowed()"), abi.encode(false));
        vm.prank(alice);
        vm.expectRevert(NotConfigured.selector);
        d.packs.buyPackFor(bob);
        assertEq(_purchaseState(bob), before_);
        vm.mockCall(address(d.pool), abi.encodeWithSignature("endowed()"), abi.encode(true));
        market.configureLaunch(tokenLaunch(), bob);
        vm.prank(alice);
        vm.expectRevert(NotConfigured.selector);
        d.packs.buyPackFor(bob);
        assertEq(_purchaseState(bob), before_);
    }

    function test_ETHGiftFailureUndoesCompletedMarketSwap() public {
        uint256 cost = d.packs.price();
        uint256 ethIn = cost / 1_000_000 + 1 ether;
        uint256 ethBefore = alice.balance;
        uint256 marketETH = address(market).balance;
        uint256 marketTokens = token.balanceOf(address(market));
        bytes32 before_ = _purchaseState(bob);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.packs.buyWithETH{value: ethIn}(bob, 1, cost, cost - 1);
        assertEq(_purchaseState(bob), before_);
        assertEq(alice.balance, ethBefore);
        assertEq(address(market).balance, marketETH);
        assertEq(token.balanceOf(address(market)), marketTokens);
        assertEq(address(d.packs).balance, 0);
    }

    function testETHGiftRefundGoesToPayerAndCannotSpendPreexistingPackTokens() public {
        uint256 cost = d.packs.price();
        uint256 ethIn = cost / 1_000_000 + 1 ether;
        uint256 quotedTokens = market.quote(ethIn);
        uint256 aliceTokens = token.balanceOf(alice);
        uint256 bobTokens = token.balanceOf(bob);
        // Unsolicited transfers must not be included in this buyer's refund.
        token.transfer(address(d.packs), 17 ether);
        vm.prank(alice);
        uint256 id = d.packs.buyWithETH{value: ethIn}(bob, 1, cost, cost);
        assertEq(token.balanceOf(alice), aliceTokens + quotedTokens - cost);
        assertEq(token.balanceOf(bob), bobTokens);
        assertEq(token.balanceOf(address(d.packs)), 17 ether);
        assertEq(_receipt(id).player, bob);
    }

    function testERC20CallbackCannotBuyASecondPackDuringPayment() public {
        uint256 cost = d.packs.price();
        // Give the callback caller real buying power, so a missing guard cannot be hidden by
        // an unrelated balance or allowance failure in the recursive purchase.
        token.transfer(address(token), cost * 3);
        vm.prank(address(token));
        token.approve(address(d.packs), type(uint256).max);
        token.setCallback(address(d.packs), abi.encodeCall(d.packs.buyPackFor, (bob)));
        uint256 before_ = token.balanceOf(alice);
        vm.prank(alice);
        d.packs.buyPackFor(bob);
        assertFalse(token.callbackSucceeded());
        assertEq(before_ - token.balanceOf(alice), cost);
        assertEq(d.packs.sold(), 1);
        assertEq(d.packs.nextId(), 2);
        assertEq(d.farm.paidPacks(bob), 1);
        assertEq(token.balanceOf(address(token)), cost * 3);
        // The same caller and purchase succeed outside the payment callback.
        token.setCallback(address(0), "");
        vm.prank(address(token));
        d.packs.buyPackFor(bob);
        assertEq(d.packs.sold(), 2);
        assertEq(d.farm.paidPacks(bob), 2);
    }

    function testSecondItemReceiverFailureRollsBackEntireResolutionAndCanRetry() public {
        JobAReceiver recipient = new JobAReceiver();
        recipient.configure(2, PackSale(address(0)), 0);
        vm.prank(alice);
        uint256 id = d.packs.buyPackFor(address(recipient));
        entropy();
        PackSale.Commit memory before_ = _receipt(id);
        uint256 nextItem = d.items.nextId();
        vm.expectRevert(JobAReceiver.RefusedItem.selector);
        d.packs.resolve(id, 1);
        assertEq(abi.encode(_receipt(id)), abi.encode(before_));
        assertEq(d.items.nextId(), nextItem);
        assertEq(d.items.inventory(address(recipient)), 0);
        assertEq(d.items.ownedCount(address(recipient)), 0);
        assertEq(recipient.received(), 0, "even the first callback rolled back");
        recipient.configure(0, PackSale(address(0)), 0);
        d.packs.resolve(id, 1);
        assertEq(d.items.nextId(), nextItem + 3);
        assertEq(d.items.inventory(address(recipient)), 3);
        assertEq(recipient.received(), 3);
        assertEq(_receipt(id).opened, 1);
        vm.expectRevert(InvalidValue.selector);
        d.packs.resolve(id, 1);
    }

    function testERC1155CallbackCannotResolveReceiptTwice() public {
        JobAReceiver recipient = new JobAReceiver();
        vm.prank(alice);
        uint256 id = d.packs.buyPacksFor(address(recipient), 2, type(uint256).max);
        recipient.configure(0, d.packs, id);
        entropy();
        d.packs.resolve(id, 1);
        assertFalse(recipient.callbackSucceeded());
        assertEq(recipient.callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(_receipt(id).opened, 1);
        assertEq(d.items.inventory(address(recipient)), 3);
        d.packs.resolve(id, 1);
        assertEq(_receipt(id).opened, 2);
        assertEq(d.items.inventory(address(recipient)), 6);
    }

    function testInvalidResolveCountsCannotCaptureEntropyOrMintItems() public {
        vm.prank(alice);
        uint256 id = d.packs.openPack(10);
        entropy();
        bytes memory before_ = abi.encode(_receipt(id));
        uint256[4] memory counts = [uint256(0), 9, 11, type(uint256).max];
        for (uint256 i; i < counts.length; ++i) {
            vm.expectRevert(InvalidValue.selector);
            d.packs.resolve(id, counts[i]);
            assertEq(abi.encode(_receipt(id)), before_);
        }
        vm.expectRevert(InvalidValue.selector);
        d.packs.resolve(id + 1, 1);
        assertEq(d.items.inventory(alice), 0);
        assertEq(d.items.nextId(), 1);
    }

    function test_UnplaceFailureKeepsCustodyAndLoadoutWhenInventoryIsFull() public {
        uint256 id = place(alice, 0, 0, 0);
        for (uint256 i; i < 15; ++i) {
            mintItem(alice, 1, 0);
        }
        uint256 weight = d.rewards.configuredWeight(alice);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.farm.unplace(0, 0);
        assertEq(d.farm.itemAt(alice, 0, 0), id);
        assertTrue(d.items.data(id).equipped);
        assertEq(d.items.balanceOf(address(d.farm), id), 1);
        assertEq(d.items.balanceOf(alice, id), 0);
        assertEq(d.items.inventory(alice), 15);
        assertEq(d.rewards.configuredWeight(alice), weight);
    }

    function testPublicCallersCannotManufactureCreditOrItems() public {
        vm.startPrank(alice);
        vm.expectRevert(Unauthorized.selector);
        d.rewards.initialize(alice);
        vm.expectRevert(Unauthorized.selector);
        d.rewards.setWeight(alice, 1 ether);
        vm.expectRevert(Unauthorized.selector);
        d.rewards.recordSales(1);
        vm.expectRevert(Unauthorized.selector);
        d.rewards.flagResync(alice);
        vm.expectRevert(Unauthorized.selector);
        d.rewards.award(alice, 1 ether);
        vm.expectRevert(Unauthorized.selector);
        d.rewards.releasePrize(1);
        vm.expectRevert(Unauthorized.selector);
        d.rewards.spend(alice, 1);
        vm.expectRevert(Unauthorized.selector);
        d.rewards.spendTo(alice, 1, alice);
        vm.expectRevert(Unauthorized.selector);
        d.rewards.scrap(alice, 1 ether, 0);
        vm.expectRevert(Unauthorized.selector);
        d.packs.tokenPack(alice);
        vm.expectRevert(Unauthorized.selector);
        d.packs.rewardPack(alice);
        vm.expectRevert(Unauthorized.selector);
        d.items.mint(alice, 0, 0, false);
        vm.expectRevert(Unauthorized.selector);
        d.items.expand(alice);
        vm.expectRevert(Unauthorized.selector);
        d.farm.paidPackBought(alice, 1, 1);
        vm.stopPrank();
        assertEq(d.rewards.pending(alice), 0);
        assertEq(d.rewards.nextTotalHash(), 0);
        assertEq(d.packs.nextId(), 1);
        assertEq(d.items.nextId(), 1);
        assertFalse(d.farm.hasFarm(alice));
    }

    function testClaimZeroOrAboveCreditCannotConsumeTaxOrReservations() public {
        fund(100_000_000 ether);
        payPack(alice);
        place(alice, 0, 0, 0);
        calmNext();
        step();
        uint256 credit = d.rewards.pending(alice);
        assertGt(credit, 0);
        uint256 reserved = d.pool.reserved();
        uint256 queued = d.rewards.queuedTax();
        uint256 balance = token.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        d.rewards.claim(0);
        vm.expectRevert(InsufficientBalance.selector);
        d.rewards.claim(credit + 1);
        vm.stopPrank();
        assertEq(d.rewards.pending(alice), credit);
        assertEq(d.pool.reserved(), reserved);
        assertEq(d.rewards.queuedTax(), queued);
        assertEq(token.balanceOf(alice), balance);
        vm.prank(alice);
        uint256 net = d.rewards.claim(credit);
        assertEq(token.balanceOf(alice) - balance, net);
        assertEq(d.rewards.pending(alice), 0);
        assertEq(d.pool.reserved(), reserved - net);
        assertEq(d.rewards.queuedTax() - queued, credit - net);
    }
}
