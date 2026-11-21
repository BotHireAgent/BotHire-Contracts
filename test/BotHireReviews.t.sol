// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BotHireReviews} from "../src/BotHireReviews.sol";
import {BotHireEscrowV2} from "../src/BotHireEscrowV2.sol";
import {BotHireEscrowV3} from "../src/BotHireEscrowV3.sol";
import {BotHireMeteredEscrow} from "../src/BotHireMeteredEscrow.sol";
import {BotHireMeteredEscrowV2} from "../src/BotHireMeteredEscrowV2.sol";
import {Mock18, MockPermit2} from "./EscrowMocks.sol";

/// @dev Minimal ERC-721 balanceOf stand-in for the Binance Agent ID NFT.
contract MockAgentId {
    mapping(address => uint256) public balanceOf;
    function set(address who, uint256 b) external { balanceOf[who] = b; }
}

/// @dev Agent ID that always reverts.
contract RevertingAgentId {
    function balanceOf(address) external pure returns (uint256) { revert("nope"); }
}

/// @dev Agent ID that returns nothing (a Solidity try/catch would NOT catch the decode failure).
contract EmptyReturnAgentId {
    fallback() external {
        assembly { return(0, 0) }
    }
}

/// @dev Agent ID that burns all gas.
contract GasBurnAgentId {
    function balanceOf(address) external pure returns (uint256) {
        while (true) {}
        return 1;
    }
}

contract BotHireReviewsTest is Test {
    BotHireReviews reviews;
    BotHireEscrowV2 fixedEscrow;
    BotHireMeteredEscrow metered;
    Mock18 token;
    MockAgentId agent;

    address arbiter = makeAddr("arbiter");
    address settler = makeAddr("settler");
    address hirer = makeAddr("hirer");
    address provider = makeAddr("provider");
    address stranger = makeAddr("stranger");

    uint256 constant AMT = 5e18;

    event Reviewed(
        address indexed subject,
        address indexed reviewer,
        address indexed escrow,
        bytes32 escrowId,
        uint256 escrowAmount,
        uint8 rating,
        bool reviewerIsHirer,
        bool reviewerHasAgentId,
        string comment
    );

    function setUp() public {
        token = new Mock18();
        fixedEscrow = new BotHireEscrowV2(address(token), arbiter);
        metered = new BotHireMeteredEscrow(address(token), settler, arbiter);
        agent = new MockAgentId();
        reviews = _deploy(address(agent));

        token.mint(hirer, 1_000e18);
        token.mint(provider, 1_000e18);
        vm.startPrank(hirer);
        token.approve(address(fixedEscrow), type(uint256).max);
        token.approve(address(metered), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(provider);
        token.approve(address(fixedEscrow), type(uint256).max);
        token.approve(address(metered), type(uint256).max);
        vm.stopPrank();
    }

    // ---------- helpers ----------

    function _deploy(address agentId) internal returns (BotHireReviews) {
        address[] memory list = new address[](2);
        list[0] = address(fixedEscrow);
        list[1] = address(metered);
        return new BotHireReviews(list, agentId, 0);
    }

    function _fixedDeposit(bytes32 ref) internal returns (bytes32 id) {
        vm.prank(hirer);
        fixedEscrow.deposit(ref, provider, AMT);
        id = fixedEscrow.computeEscrowId(hirer, ref);
    }

    function _fixedReleased(bytes32 ref) internal returns (bytes32 id) {
        id = _fixedDeposit(ref);
        vm.prank(hirer);
        fixedEscrow.release(id);
    }

    function _meteredSettled(bytes32 ref) internal returns (bytes32 id) {
        vm.prank(hirer);
        metered.deposit(ref, provider, AMT);
        id = metered.computeEscrowId(hirer, ref);
        vm.prank(settler);
        metered.settle(id, AMT / 2);
    }

    function _review(address who, address escrow, bytes32 id, uint8 rating, string memory c) internal {
        vm.prank(who);
        reviews.review(escrow, id, rating, c);
    }

    function _assertStats(address s, uint64 c, uint64 sum, uint64 ac, uint64 asum) internal view {
        (uint64 c_, uint64 sum_, uint64 ac_, uint64 asum_) = reviews.stats(s);
        assertEq(c_, c, "count");
        assertEq(sum_, sum, "sum");
        assertEq(ac_, ac, "agentCount");
        assertEq(asum_, asum, "agentSum");
    }

    // ---------- constructor ----------

    function test_constructor_state() public view {
        address[] memory l = reviews.escrowList();
        assertEq(l.length, 2);
        assertEq(l[0], address(fixedEscrow));
        assertEq(l[1], address(metered));
        assertTrue(reviews.isEscrow(address(fixedEscrow)));
        assertTrue(reviews.isEscrow(address(metered)));
        assertFalse(reviews.isEscrow(stranger));
        assertEq(reviews.agentId(), address(agent));
    }

    function test_constructor_revert_zeroEscrow() public {
        address[] memory l = new address[](2);
        l[0] = address(fixedEscrow);
        vm.expectRevert(BotHireReviews.ZeroAddress.selector);
        new BotHireReviews(l, address(0), 0);
    }

    function test_constructor_revert_duplicate() public {
        address[] memory l = new address[](2);
        l[0] = address(fixedEscrow);
        l[1] = address(fixedEscrow);
        vm.expectRevert(BotHireReviews.DuplicateEscrow.selector);
        new BotHireReviews(l, address(0), 0);
    }

    function test_constructor_revert_empty() public {
        vm.expectRevert(BotHireReviews.NoEscrows.selector);
        new BotHireReviews(new address[](0), address(0), 0);
    }

    function test_constructor_revert_tooMany() public {
        address[] memory l = new address[](17);
        vm.expectRevert(BotHireReviews.TooManyEscrows.selector);
        new BotHireReviews(l, address(0), 0);
    }

    function test_constructor_revert_eoaEscrow() public {
        address[] memory l = new address[](1);
        l[0] = stranger;
        vm.expectRevert(BotHireReviews.NotContract.selector);
        new BotHireReviews(l, address(0), 0);
    }

    function test_constructor_revert_eoaAgentId() public {
        address[] memory l = new address[](1);
        l[0] = address(fixedEscrow);
        vm.expectRevert(BotHireReviews.NotContract.selector);
        new BotHireReviews(l, stranger, 0);
    }

    function test_constructor_zeroAgentIdAllowed() public {
        BotHireReviews r = _deploy(address(0));
        assertEq(r.agentId(), address(0));
    }

    function test_noFundsAccepted() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(reviews).call{value: 1}("");
        assertFalse(ok);
    }

    // ---------- happy paths ----------

    function test_fixed_bothSides() public {
        bytes32 id = _fixedReleased("r1");

        vm.expectEmit(true, true, true, true, address(reviews));
        emit Reviewed(provider, hirer, address(fixedEscrow), id, AMT, 5, true, false, "great work");
        _review(hirer, address(fixedEscrow), id, 5, "great work");

        vm.expectEmit(true, true, true, true, address(reviews));
        emit Reviewed(hirer, provider, address(fixedEscrow), id, AMT, 4, false, false, "paid fast");
        _review(provider, address(fixedEscrow), id, 4, "paid fast");

        _assertStats(provider, 1, 5, 0, 0);
        _assertStats(hirer, 1, 4, 0, 0);
        assertTrue(reviews.hasReviewed(address(fixedEscrow), id, true));
        assertTrue(reviews.hasReviewed(address(fixedEscrow), id, false));
    }

    function test_metered_bothSides() public {
        bytes32 id = _meteredSettled("m1");
        assertFalse(reviews.hasReviewed(address(metered), id, true));
        _review(provider, address(metered), id, 3, "");
        assertFalse(reviews.hasReviewed(address(metered), id, true));
        assertTrue(reviews.hasReviewed(address(metered), id, false));
        _review(hirer, address(metered), id, 2, "ok");
        _assertStats(provider, 1, 2, 0, 0);
        _assertStats(hirer, 1, 3, 0, 0);
    }

    function test_metered_settleZero_stillCompleted() public {
        vm.prank(hirer);
        metered.deposit("m0", provider, AMT);
        bytes32 id = metered.computeEscrowId(hirer, "m0");
        vm.prank(settler);
        metered.settle(id, 0);
        _review(hirer, address(metered), id, 1, "nothing delivered");
        _assertStats(provider, 1, 1, 0, 0);
    }

    function test_disputeResolvedToProvider_counts() public {
        bytes32 id = _fixedDeposit("d1");
        vm.prank(hirer);
        fixedEscrow.dispute(id);
        vm.prank(arbiter);
        fixedEscrow.resolveDispute(id, true);
        _review(provider, address(fixedEscrow), id, 1, "");
        _assertStats(hirer, 1, 1, 0, 0);
    }

    function test_comment280_ok() public {
        bytes32 id = _fixedReleased("c280");
        _review(hirer, address(fixedEscrow), id, 5, string(new bytes(280)));
        _assertStats(provider, 1, 5, 0, 0);
    }

    function test_compat_V3_and_MeteredV2() public {
        MockPermit2 p2 = new MockPermit2();
        BotHireEscrowV3 v3 = new BotHireEscrowV3(address(token), arbiter, address(p2));
        BotHireMeteredEscrowV2 mv2 = new BotHireMeteredEscrowV2(address(token), settler, arbiter, address(p2));
        address[] memory l = new address[](2);
        l[0] = address(v3);
        l[1] = address(mv2);
        BotHireReviews r = new BotHireReviews(l, address(0), 0);

        vm.startPrank(hirer);
        token.approve(address(v3), type(uint256).max);
        token.approve(address(mv2), type(uint256).max);
        v3.deposit("x", provider, AMT);
        bytes32 a = v3.computeEscrowId(hirer, "x");
        v3.release(a);
        mv2.deposit("y", provider, AMT);
        bytes32 b = mv2.computeEscrowId(hirer, "y");
        vm.stopPrank();
        vm.prank(settler);
        mv2.settle(b, 1);

        vm.startPrank(hirer);
        r.review(address(v3), a, 5, "");
        r.review(address(mv2), b, 3, "");
        vm.stopPrank();
        (uint64 c, uint64 s,,) = r.stats(provider);
        assertEq(c, 2);
        assertEq(s, 8);
    }

    // ---------- reverts ----------

    function test_revert_notAllowlisted() public {
        BotHireEscrowV2 other = new BotHireEscrowV2(address(token), arbiter);
        vm.prank(hirer);
        token.approve(address(other), type(uint256).max);
        vm.prank(hirer);
        other.deposit("o", provider, AMT);
        bytes32 id = other.computeEscrowId(hirer, "o");
        vm.prank(hirer);
        other.release(id);

        vm.expectRevert(BotHireReviews.EscrowNotAllowed.selector);
        _review(hirer, address(other), id, 5, "");
    }

    function test_revert_nonexistentEscrow() public {
        vm.expectRevert(BotHireReviews.EscrowNotCompleted.selector);
        _review(hirer, address(fixedEscrow), keccak256("nope"), 5, "");
    }

    function test_revert_deposited() public {
        bytes32 id = _fixedDeposit("dep");
        vm.expectRevert(BotHireReviews.EscrowNotCompleted.selector);
        _review(hirer, address(fixedEscrow), id, 5, "");
    }

    function test_revert_meteredDeposited() public {
        vm.prank(hirer);
        metered.deposit("md", provider, AMT);
        bytes32 id = metered.computeEscrowId(hirer, "md");
        vm.expectRevert(BotHireReviews.EscrowNotCompleted.selector);
        _review(provider, address(metered), id, 5, "");
    }

    function test_revert_refunded() public {
        bytes32 id = _fixedDeposit("ref");
        vm.prank(hirer);
        fixedEscrow.refund(id);
        vm.expectRevert(BotHireReviews.EscrowNotCompleted.selector);
        _review(hirer, address(fixedEscrow), id, 5, "");
    }

    function test_revert_meteredRefunded() public {
        vm.prank(hirer);
        metered.deposit("mr", provider, AMT);
        bytes32 id = metered.computeEscrowId(hirer, "mr");
        vm.warp(block.timestamp + 25 hours);
        metered.claimRefund(id);
        vm.expectRevert(BotHireReviews.EscrowNotCompleted.selector);
        _review(hirer, address(metered), id, 5, "");
    }

    function test_revert_disputed() public {
        bytes32 id = _fixedDeposit("dis");
        vm.prank(provider);
        fixedEscrow.dispute(id);
        vm.expectRevert(BotHireReviews.EscrowNotCompleted.selector);
        _review(provider, address(fixedEscrow), id, 1, "");
    }

    function test_revert_meteredDisputed() public {
        vm.prank(hirer);
        metered.deposit("mdis", provider, AMT);
        bytes32 id = metered.computeEscrowId(hirer, "mdis");
        vm.prank(hirer);
        metered.dispute(id);
        vm.expectRevert(BotHireReviews.EscrowNotCompleted.selector);
        _review(hirer, address(metered), id, 1, "");
    }

    function test_revert_stranger() public {
        bytes32 id = _fixedReleased("s");
        vm.expectRevert(BotHireReviews.NotParty.selector);
        _review(stranger, address(fixedEscrow), id, 5, "");
        vm.expectRevert(BotHireReviews.NotParty.selector);
        _review(arbiter, address(fixedEscrow), id, 5, "");
    }

    function test_revert_rating0() public {
        bytes32 id = _fixedReleased("r0");
        vm.expectRevert(BotHireReviews.InvalidRating.selector);
        _review(hirer, address(fixedEscrow), id, 0, "");
    }

    function test_revert_rating6() public {
        bytes32 id = _fixedReleased("r6");
        vm.expectRevert(BotHireReviews.InvalidRating.selector);
        _review(hirer, address(fixedEscrow), id, 6, "");
    }

    function test_revert_comment281() public {
        bytes32 id = _fixedReleased("c281");
        vm.expectRevert(BotHireReviews.CommentTooLong.selector);
        _review(hirer, address(fixedEscrow), id, 5, string(new bytes(281)));
    }

    function test_revert_doubleReview() public {
        bytes32 id = _fixedReleased("dbl");
        _review(hirer, address(fixedEscrow), id, 5, "");
        vm.expectRevert(BotHireReviews.AlreadyReviewed.selector);
        _review(hirer, address(fixedEscrow), id, 1, "changed my mind");
        // other side still free
        _review(provider, address(fixedEscrow), id, 4, "");
        vm.expectRevert(BotHireReviews.AlreadyReviewed.selector);
        _review(provider, address(fixedEscrow), id, 4, "");
        _assertStats(provider, 1, 5, 0, 0);
    }

    function test_revert_selfDealing_fixed() public {
        vm.prank(hirer);
        fixedEscrow.deposit("self", hirer, AMT);
        bytes32 id = fixedEscrow.computeEscrowId(hirer, "self");
        vm.prank(hirer);
        fixedEscrow.release(id);
        vm.expectRevert(BotHireReviews.SelfDealing.selector);
        _review(hirer, address(fixedEscrow), id, 5, "");
    }

    function test_revert_selfDealing_metered() public {
        vm.prank(hirer);
        metered.deposit("self", hirer, AMT);
        bytes32 id = metered.computeEscrowId(hirer, "self");
        vm.prank(settler);
        metered.settle(id, AMT);
        vm.expectRevert(BotHireReviews.SelfDealing.selector);
        _review(hirer, address(metered), id, 5, "");
    }

    /// Same escrowId value on two different allowlisted escrows are independent.
    function test_sameIdDifferentEscrow_independent() public {
        bytes32 a = _fixedReleased("same");
        bytes32 b = _meteredSettled("same");
        assertEq(a, b);
        _review(hirer, address(fixedEscrow), a, 5, "");
        _review(hirer, address(metered), b, 3, "");
        _assertStats(provider, 2, 8, 0, 0);
    }

    // ---------- Agent ID flag ----------

    function test_agentId_true() public {
        agent.set(hirer, 1);
        bytes32 id = _fixedReleased("a1");
        vm.expectEmit(true, true, true, true, address(reviews));
        emit Reviewed(provider, hirer, address(fixedEscrow), id, AMT, 4, true, true, "");
        _review(hirer, address(fixedEscrow), id, 4, "");
        _assertStats(provider, 1, 4, 1, 4);
    }

    function test_agentId_false() public {
        agent.set(provider, 1); // subject holding one does not matter
        bytes32 id = _fixedReleased("a2");
        _review(hirer, address(fixedEscrow), id, 4, "");
        _assertStats(provider, 1, 4, 0, 0);
    }

    function test_agentId_disabled() public {
        BotHireReviews r = _deploy(address(0));
        agent.set(hirer, 1);
        bytes32 id = _fixedReleased("a3");
        vm.prank(hirer);
        r.review(address(fixedEscrow), id, 5, "");
        (uint64 c,, uint64 ac,) = r.stats(provider);
        assertEq(c, 1);
        assertEq(ac, 0);
    }

    function test_agentId_reverting_doesNotRevert() public {
        BotHireReviews r = _deploy(address(new RevertingAgentId()));
        bytes32 id = _fixedReleased("a4");
        vm.expectEmit(true, true, true, true, address(r));
        emit Reviewed(provider, hirer, address(fixedEscrow), id, AMT, 5, true, false, "");
        vm.prank(hirer);
        r.review(address(fixedEscrow), id, 5, "");
    }

    function test_agentId_emptyReturn_doesNotRevert() public {
        BotHireReviews r = _deploy(address(new EmptyReturnAgentId()));
        bytes32 id = _fixedReleased("a5");
        vm.prank(hirer);
        r.review(address(fixedEscrow), id, 5, "");
        (uint64 c,, uint64 ac,) = r.stats(provider);
        assertEq(c, 1);
        assertEq(ac, 0);
    }

    function test_agentId_gasBurn_doesNotRevert() public {
        BotHireReviews r = _deploy(address(new GasBurnAgentId()));
        bytes32 id = _fixedReleased("a6");
        vm.prank(hirer);
        r.review(address(fixedEscrow), id, 5, "");
        (uint64 c,, uint64 ac,) = r.stats(provider);
        assertEq(c, 1);
        assertEq(ac, 0);
    }

    // ---------- stats math ----------

    function test_stats_aggregate() public {
        agent.set(hirer, 1);
        uint8[4] memory rs = [uint8(5), 3, 4, 1];
        for (uint256 i; i < 4; ++i) {
            bytes32 ref = bytes32(i + 100);
            bytes32 id = (i % 2 == 0) ? _fixedReleased(ref) : _meteredSettled(ref);
            address esc = (i % 2 == 0) ? address(fixedEscrow) : address(metered);
            if (i == 2) agent.set(hirer, 0); // loses Agent ID for the last two
            _review(hirer, esc, id, rs[i], "");
            _review(provider, esc, id, 5, "");
        }
        _assertStats(provider, 4, 13, 2, 8);
        _assertStats(hirer, 4, 20, 0, 0);
        _assertStats(stranger, 0, 0, 0, 0);
    }

    // ---------- fuzz ----------

    function testFuzz_rating(uint8 rating, bool asHirer) public {
        bytes32 id = _fixedReleased("fz");
        address who = asHirer ? hirer : provider;
        address subject = asHirer ? provider : hirer;
        if (rating < 1 || rating > 5) {
            vm.expectRevert(BotHireReviews.InvalidRating.selector);
            _review(who, address(fixedEscrow), id, rating, "");
            assertFalse(reviews.hasReviewed(address(fixedEscrow), id, asHirer));
        } else {
            _review(who, address(fixedEscrow), id, rating, "");
            _assertStats(subject, 1, rating, 0, 0);
            assertTrue(reviews.hasReviewed(address(fixedEscrow), id, asHirer));
        }
    }

    function testFuzz_commentLength(uint16 len) public {
        len = uint16(bound(len, 0, 600));
        bytes32 id = _fixedReleased("fzc");
        if (len > 280) vm.expectRevert(BotHireReviews.CommentTooLong.selector);
        _review(hirer, address(fixedEscrow), id, 3, string(new bytes(len)));
    }

    // ---------- v2: minimum amount, role split, amount in event ----------

    function _deployMin(uint256 minAmt) internal returns (BotHireReviews) {
        address[] memory list = new address[](2);
        list[0] = address(fixedEscrow);
        list[1] = address(metered);
        return new BotHireReviews(list, address(agent), minAmt);
    }

    function test_minAmount_dustReverts() public {
        BotHireReviews r = _deployMin(1e18);
        vm.prank(hirer);
        fixedEscrow.deposit("dust", provider, 1);
        bytes32 id = fixedEscrow.computeEscrowId(hirer, "dust");
        vm.prank(hirer);
        fixedEscrow.release(id);
        vm.prank(hirer);
        vm.expectRevert(BotHireReviews.AmountBelowMinimum.selector);
        r.review(address(fixedEscrow), id, 1, "smear");
    }

    function test_minAmount_exactlyMinOk() public {
        BotHireReviews r = _deployMin(AMT);
        bytes32 id = _fixedReleased("min");
        vm.prank(hirer);
        r.review(address(fixedEscrow), id, 3, "");
        (uint64 c,,,) = r.stats(provider);
        assertEq(c, 1);
        assertEq(r.minEscrowAmount(), AMT);
    }

    function test_minAmount_belowMinByOne() public {
        BotHireReviews r = _deployMin(AMT + 1);
        bytes32 id = _fixedReleased("min1");
        vm.prank(provider);
        vm.expectRevert(BotHireReviews.AmountBelowMinimum.selector);
        r.review(address(fixedEscrow), id, 3, "");
    }

    function test_statsByRole_split() public {
        bytes32 id = _fixedReleased("role");
        _review(hirer, address(fixedEscrow), id, 5, "");   // provider reviewed as provider
        _review(provider, address(fixedEscrow), id, 2, ""); // hirer reviewed as hirer
        (uint64 pc, uint64 ps,,) = reviews.statsByRole(provider, true);
        (uint64 hc,,,) = reviews.statsByRole(provider, false);
        assertEq(pc, 1); assertEq(ps, 5); assertEq(hc, 0);
        (uint64 hc2, uint64 hs2,,) = reviews.statsByRole(hirer, false);
        (uint64 pc2,,,) = reviews.statsByRole(hirer, true);
        assertEq(hc2, 1); assertEq(hs2, 2); assertEq(pc2, 0);
    }

    function test_stats_sumsBothRoles() public {
        // provider is reviewed as provider on one escrow and as hirer on another
        bytes32 a = _fixedReleased("sum-a");
        _review(hirer, address(fixedEscrow), a, 4, "");
        vm.prank(provider);
        fixedEscrow.deposit("sum-b", hirer, AMT);
        bytes32 b = fixedEscrow.computeEscrowId(provider, "sum-b");
        vm.prank(provider);
        fixedEscrow.release(b);
        _review(hirer, address(fixedEscrow), b, 2, ""); // hirer is now the provider of b, reviews provider-as-hirer
        _assertStats(provider, 2, 6, 0, 0);
        (uint64 pc,,,) = reviews.statsByRole(provider, true);
        (uint64 hc,,,) = reviews.statsByRole(provider, false);
        assertEq(pc, 1); assertEq(hc, 1);
    }

    function test_event_meteredAmountIsBudget() public {
        bytes32 id = _meteredSettled("evm");
        vm.expectEmit(true, true, true, true, address(reviews));
        emit Reviewed(provider, hirer, address(metered), id, AMT, 5, true, false, "");
        _review(hirer, address(metered), id, 5, "");
    }
}
