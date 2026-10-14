// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import "src/lib/Errors.sol";

/// @notice Exercises the L3 starter/pack entry points on chain 4663 with an offline ArbSys fixture.
/// The fixture deliberately separates the native L2 height from block.number (the L1 estimate).
contract JobAStarterBoundariesTest is BaseTest {
    uint256 private constant FREE_ID = uint256(1) << 255;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        vm.chainId(4663);
        _nativeHeight(9000);
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockHash(uint256)"), abi.encode(bytes32(0)));
        super.setUp();
    }

    function _nativeHeight(uint256 n) private {
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(n));
    }

    function _nativeHash(uint256 n, bytes32 h) private {
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockHash(uint256)", n), abi.encode(h));
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _leaves() private view returns (bytes32[4] memory leaves) {
        leaves[0] = keccak256(abi.encode(uint256(0), alice));
        leaves[1] = keccak256(abi.encode(uint256(1), alice));
        leaves[2] = keccak256(abi.encode(uint256(0), bob));
        leaves[3] = keccak256(abi.encode(uint256(499), bob));
    }

    function freePackRoot() internal view override returns (bytes32) {
        bytes32[4] memory leaves = _leaves();
        return _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
    }

    function _proof(uint256 i) private view returns (bytes32[] memory p) {
        bytes32[4] memory leaves = _leaves();
        p = new bytes32[](2);
        p[0] = leaves[i ^ 1];
        p[1] = i < 2 ? _pair(leaves[2], leaves[3]) : _pair(leaves[0], leaves[1]);
    }

    function testFreeProofBindsBothIndexAndCallerWithoutConsumingEligibility() public {
        bytes32[] memory aliceProof = _proof(0);
        vm.prank(bob);
        vm.expectRevert(InvalidProof.selector);
        d.starter.claimFree(0, aliceProof);
        vm.prank(alice);
        vm.expectRevert(InvalidProof.selector);
        d.starter.claimFree(1, aliceProof);
        assertEq(d.starter.freeClaimed(), 0);
        assertFalse(d.starter.freeIndexClaimed(0));
        assertFalse(d.starter.freeClaimedBy(alice));
        assertFalse(d.farm.hasFarm(alice));
        vm.prank(alice);
        assertEq(d.starter.claimFree(0, aliceProof), FREE_ID);
        assertTrue(d.farm.hasFarm(alice));
    }

    function testDuplicateWalletAndDuplicateIndexCannotClaimTwiceWithValidProofs() public {
        bytes32[] memory p = _proof(0);
        vm.prank(alice);
        d.starter.claimFree(0, p);
        p = _proof(1);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.starter.claimFree(1, p);
        p = _proof(2);
        vm.prank(bob);
        vm.expectRevert(InvalidValue.selector);
        d.starter.claimFree(0, p);
        assertEq(d.starter.freeClaimed(), 1);
        assertFalse(d.starter.freeIndexClaimed(1));
        assertFalse(d.starter.freeClaimedBy(bob));
        p = _proof(3);
        vm.prank(bob);
        assertEq(d.starter.claimFree(499, p), FREE_ID | 499);
        assertEq(d.starter.freeClaimed(), 2);
    }

    function testFreeClaimUpperIndexAndExactDeadline() public {
        bytes32[] memory p = _proof(3);
        vm.prank(bob);
        vm.expectRevert(InvalidValue.selector);
        d.starter.claimFree(500, p);
        vm.warp(d.starter.freeClaimEnds() - 1);
        vm.prank(bob);
        d.starter.claimFree(499, p);
        vm.warp(d.starter.freeClaimEnds());
        p = _proof(0);
        vm.prank(alice);
        vm.expectRevert(TooEarly.selector);
        d.starter.claimFree(0, p);
        assertEq(d.starter.freeClaimed(), 1);
        assertFalse(d.starter.freeClaimedBy(alice));
    }

    function testSnapshotClaimWindowAndNamespaceCannotOverlapFreeReceipts() public {
        bytes32[] memory p = new bytes32[](0);
        vm.warp(tokenLaunch() + 48 hours - 1);
        vm.prank(alice);
        vm.expectRevert(TooEarly.selector);
        d.starter.claim(17, p);
        vm.warp(tokenLaunch() + 48 hours);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.starter.claim(FREE_ID, p);
        vm.prank(alice);
        d.starter.claim(17, p);
        vm.prank(alice);
        vm.expectRevert(AlreadyDone.selector);
        d.starter.claim(17, p);
        (address holder, uint64 target, bool resolved) = d.starter.claims(17);
        assertEq(holder, alice);
        assertEq(target, 9002);
        assertFalse(resolved);
        p = _proof(0);
        vm.prank(alice);
        d.starter.claimFree(0, p);
        (holder,,) = d.starter.claims(FREE_ID);
        assertEq(holder, alice);
        assertEq(d.starter.freeClaimed(), 1);
    }

    function testSnapshotClaimClosesAtExactlySixteenDays() public {
        vm.warp(tokenLaunch() + 16 days);
        vm.prank(alice);
        vm.expectRevert(TooEarly.selector);
        d.starter.claim(17, new bytes32[](0));
        (address holder,,) = d.starter.claims(17);
        assertEq(holder, address(0));
    }

    function testStarterUsesNativeHeightAndNeverSubstitutesMissingEntropy() public {
        bytes32[] memory p = _proof(0);
        vm.prank(alice);
        uint256 id = d.starter.claimFree(0, p);
        // Advancing the L1 estimate cannot make the native L2 target usable.
        vm.roll(100_000);
        vm.expectRevert(TooEarly.selector);
        d.starter.resolve(id);
        _nativeHeight(9002);
        vm.expectRevert(TooEarly.selector);
        d.starter.captureEntropy(id);
        _nativeHeight(9003);
        vm.expectRevert(NotConfigured.selector);
        d.starter.resolve(id);
        assertFalse(d.starter.entropyCaptured(id));
        assertEq(d.items.inventory(alice), 0);
        _nativeHash(9002, keccak256("offline native starter block"));
        d.starter.captureEntropy(id);
        assertEq(d.starter.entropyHash(id), keccak256("offline native starter block"));
        // A captured value remains usable after the precompile's history window expires.
        _nativeHeight(10_000);
        _nativeHash(9002, bytes32(0));
        d.starter.resolve(id);
        assertEq(d.items.inventory(alice), 3);
        (,, bool resolved) = d.starter.claims(id);
        assertTrue(resolved);
        vm.expectRevert(AlreadyDone.selector);
        d.starter.resolve(id);
    }

    function testStarterRearmBoundaryPreservesClaimAndRequiresFreshFutureBlock() public {
        bytes32[] memory p = _proof(0);
        vm.prank(alice);
        uint256 id = d.starter.claimFree(0, p);
        _nativeHeight(9258); // target + 256 is still within the hash window
        vm.expectRevert(TooEarly.selector);
        d.starter.rearm(id);
        vm.expectRevert(NotConfigured.selector);
        d.starter.resolve(id);
        _nativeHeight(9259);
        d.starter.resolve(id); // missing old entropy re-arms; it does not mint a fallback outcome
        (address holder, uint64 target, bool resolved) = d.starter.claims(id);
        assertEq(holder, alice);
        assertEq(target, 9261);
        assertFalse(resolved);
        assertFalse(d.starter.entropyCaptured(id));
        assertEq(d.items.inventory(alice), 0);
        assertEq(d.starter.freeClaimed(), 1);
        _nativeHeight(9262);
        _nativeHash(9261, keccak256("fresh native starter block"));
        d.starter.resolve(id);
        assertEq(d.items.inventory(alice), 3);
        vm.expectRevert(TooEarly.selector);
        d.starter.rearm(id);
    }

    function testPackNativeEntropyBoundaryAndCaptureIsIdempotent() public {
        uint256 id = payPack(alice);
        (, uint64 target,,,,,,,) = d.packs.commits(id);
        assertEq(target, 9002);
        vm.roll(200_000);
        vm.expectRevert(TooEarly.selector);
        d.packs.captureEntropy(id);
        _nativeHeight(9258);
        vm.expectRevert(NotConfigured.selector);
        d.packs.resolve(id, 1);
        _nativeHash(9002, keccak256("last usable native pack block"));
        d.packs.captureEntropy(id);
        (,,,,,, bytes32 seed, bool fixedSeed,) = d.packs.commits(id);
        assertTrue(fixedSeed);
        _nativeHash(9002, keccak256("a later mock response must not replace captured entropy"));
        d.packs.captureEntropy(id);
        (,,,,,, bytes32 unchanged,,) = d.packs.commits(id);
        assertEq(unchanged, seed);
        _nativeHeight(10_000);
        vm.expectRevert(TooEarly.selector);
        d.packs.rearm(id);
        d.packs.resolve(id, 1);
        assertEq(d.items.inventory(alice), 3);
    }
}
