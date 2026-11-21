// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BotHireReviews, IBotHireEscrowView} from "../src/BotHireReviews.sol";
import {BotHireEscrowV2} from "../src/BotHireEscrowV2.sol";
import {BotHireMeteredEscrow} from "../src/BotHireMeteredEscrow.sol";
import {Mock18} from "./EscrowMocks.sol";

contract InvMockAgentId {
    mapping(address => uint256) public balanceOf;
    function set(address who, uint256 b) external { balanceOf[who] = b; }
}

contract ReviewsHandler is Test {
    BotHireReviews public reviews;
    BotHireEscrowV2 public fixedEscrow;
    BotHireMeteredEscrow public metered;
    Mock18 public token;
    InvMockAgentId public agent;
    address public arbiter;
    address public settler;
    uint256 public constant MIN = 1e18;

    address[] public actors;
    address public stranger;

    struct Rec {
        address escrow;
        bytes32 id;
        address hirer;
        address provider;
        uint256 amount;
        uint8 status; // handler-tracked
        bool revH;
        bool revP;
    }
    Rec[] public recs;

    // ghost: subject => role(0 = as provider, 1 = as hirer) => [count, sum, aCount, aSum]
    mapping(address => uint256[4][2]) internal g;

    uint256 public nonce;
    uint256 public calls;
    uint256 public reviewAttempts;
    uint256 public reviewSuccesses;
    uint256 public violations; // review outcome disagreed with prediction
    uint256 public escrowViolations;

    constructor(
        BotHireReviews r,
        BotHireEscrowV2 f,
        BotHireMeteredEscrow m,
        Mock18 t,
        InvMockAgentId a,
        address arb,
        address set_
    ) {
        (reviews, fixedEscrow, metered, token, agent, arbiter, settler) = (r, f, m, t, a, arb, set_);
        for (uint256 i; i < 5; ++i) {
            address act = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(act);
            token.mint(act, 1e30);
            vm.startPrank(act);
            token.approve(address(f), type(uint256).max);
            token.approve(address(m), type(uint256).max);
            vm.stopPrank();
        }
        stranger = makeAddr("stranger");
        agent.set(actors[0], 1);
        agent.set(actors[1], 1);
    }

    function actorsLen() external view returns (uint256) { return actors.length; }
    function recsLen() external view returns (uint256) { return recs.length; }
    function ghost(address s, uint256 role) external view returns (uint256[4] memory) { return g[s][role]; }
    function rec(uint256 i) external view returns (Rec memory) { return recs[i]; }

    function _amount(uint256 seed) internal pure returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed, "amt")));
        uint256 k = seed % 4;
        if (k == 0) return bound(seed, 1, MIN - 1); // below min
        if (k == 1) return MIN; // exactly min
        if (k == 2) return MIN - 1;
        return bound(seed, MIN + 1, 1_000e18);
    }

    function create(uint256 hSeed, uint256 pSeed, uint256 amtSeed, bool isMetered) external {
        calls++;
        address h = actors[hSeed % actors.length];
        // self-dealing ~1/8 of the time, otherwise a distinct counterparty
        uint256 hp = uint256(keccak256(abi.encode(pSeed, nonce)));
        address p = hp % 8 == 0 ? h : actors[(hSeed % actors.length + 1 + (hp >> 8) % (actors.length - 1)) % actors.length];
        uint256 amt = _amount(amtSeed);
        bytes32 ref = bytes32(++nonce);
        vm.prank(h);
        if (isMetered) {
            metered.deposit(ref, p, amt);
            recs.push(Rec(address(metered), metered.computeEscrowId(h, ref), h, p, amt, 1, false, false));
        } else {
            fixedEscrow.deposit(ref, p, amt);
            recs.push(Rec(address(fixedEscrow), fixedEscrow.computeEscrowId(h, ref), h, p, amt, 1, false, false));
        }
    }

    /// @dev create + immediately complete (release / settle) to raise review-success coverage.
    function createCompleted(uint256 hSeed, uint256 pSeed, uint256 amtSeed, bool isMetered, uint256 payout) public {
        calls++;
        address h = actors[hSeed % actors.length];
        // self-dealing ~1/8 of the time, otherwise a distinct counterparty
        uint256 hp = uint256(keccak256(abi.encode(pSeed, nonce)));
        address p = hp % 8 == 0 ? h : actors[(hSeed % actors.length + 1 + (hp >> 8) % (actors.length - 1)) % actors.length];
        uint256 amt = _amount(amtSeed);
        bytes32 ref = bytes32(++nonce);
        vm.prank(h);
        if (isMetered) {
            metered.deposit(ref, p, amt);
            bytes32 id = metered.computeEscrowId(h, ref);
            vm.prank(settler);
            metered.settle(id, bound(payout, 0, amt));
            recs.push(Rec(address(metered), id, h, p, amt, 2, false, false));
        } else {
            fixedEscrow.deposit(ref, p, amt);
            bytes32 id = fixedEscrow.computeEscrowId(h, ref);
            vm.prank(h);
            fixedEscrow.release(id);
            recs.push(Rec(address(fixedEscrow), id, h, p, amt, 2, false, false));
        }
    }

    function _pick(uint256 s) internal view returns (bool ok, uint256 i) {
        if (recs.length == 0) return (false, 0);
        return (true, s % recs.length);
    }

    function _caller(uint256 s, Rec storage r, address right) internal view returns (address) {
        uint256 k = s % 4;
        if (k == 0) return actors[(s / 4) % actors.length];
        if (k == 1) return stranger;
        if (k == 2) return r.provider;
        return right;
    }

    function _check(Rec storage r, bool ok, bool expected, uint8 newStatus) internal {
        if (ok != expected) escrowViolations++;
        if (ok) r.status = newStatus;
        (,,,,, uint8 st) = IBotHireEscrowView(r.escrow).getEscrow(r.id);
        if (st != r.status) escrowViolations++;
    }

    function release(uint256 s, uint256 cs) external {
        calls++;
        (bool has, uint256 i) = _pick(s);
        if (!has) return;
        Rec storage r = recs[i];
        if (r.escrow != address(fixedEscrow)) return;
        address c = _caller(cs, r, r.hirer);
        vm.prank(c);
        bool ok;
        try fixedEscrow.release(r.id) { ok = true; } catch {}
        _check(r, ok, r.status == 1 && c == r.hirer, 2);
    }

    function refund(uint256 s, uint256 cs) external {
        calls++;
        (bool has, uint256 i) = _pick(s);
        if (!has) return;
        Rec storage r = recs[i];
        if (r.escrow != address(fixedEscrow)) return;
        address c = _caller(cs, r, r.hirer);
        vm.prank(c);
        bool ok;
        try fixedEscrow.refund(r.id) { ok = true; } catch {}
        _check(r, ok, r.status == 1 && c == r.hirer, 3);
    }

    function dispute(uint256 s, uint256 cs) external {
        calls++;
        (bool has, uint256 i) = _pick(s);
        if (!has) return;
        Rec storage r = recs[i];
        address c = _caller(cs, r, r.hirer);
        vm.prank(c);
        bool ok;
        try BotHireEscrowV2(r.escrow).dispute(r.id) { ok = true; } catch {}
        _check(r, ok, r.status == 1 && (c == r.hirer || c == r.provider), 4);
    }

    function resolve(uint256 s, uint256 cs, uint256 payout, bool toProvider) external {
        calls++;
        (bool has, uint256 i) = _pick(s);
        if (!has) return;
        Rec storage r = recs[i];
        address c = cs % 3 == 0 ? r.hirer : arbiter;
        vm.prank(c);
        bool ok;
        if (r.escrow == address(fixedEscrow)) {
            try fixedEscrow.resolveDispute(r.id, toProvider) { ok = true; } catch {}
            _check(r, ok, r.status == 4 && c == arbiter, toProvider ? 2 : 3);
        } else {
            payout = bound(payout, 0, r.amount);
            try metered.resolveDispute(r.id, payout) { ok = true; } catch {}
            _check(r, ok, r.status == 4 && c == arbiter, 2);
        }
    }

    function settle(uint256 s, uint256 cs, uint256 payout) external {
        calls++;
        (bool has, uint256 i) = _pick(s);
        if (!has) return;
        Rec storage r = recs[i];
        if (r.escrow != address(metered)) return;
        address c = cs % 3 == 0 ? r.provider : settler;
        payout = bound(payout, 0, r.amount);
        vm.prank(c);
        bool ok;
        try metered.settle(r.id, payout) { ok = true; } catch {}
        _check(r, ok, r.status == 1 && c == settler, 2);
    }

    function timeoutRefund(uint256 s, uint256 cs) external {
        calls++;
        (bool has, uint256 i) = _pick(s);
        if (!has) return;
        Rec storage r = recs[i];
        vm.warp(block.timestamp + 8 days);
        vm.prank(_caller(cs, r, stranger));
        bool ok;
        if (r.status == 1) {
            try BotHireEscrowV2(r.escrow).claimRefund(r.id) { ok = true; } catch {}
        } else if (r.status == 4) {
            try BotHireEscrowV2(r.escrow).claimDisputeTimeout(r.id) { ok = true; } catch {}
        }
        _check(r, ok, r.status == 1 || r.status == 4, 3);
    }

    function toggleAgentId(uint256 a, bool hold) external {
        calls++;
        agent.set(actors[a % actors.length], hold ? 1 : 0);
    }

    function review(uint256 s, uint256 cs, uint8 rating, uint256 commentLen, uint256 mode) external {
        calls++;
        mode = uint256(keccak256(abi.encode(mode, nonce, reviewAttempts)));
        cs = uint256(keccak256(abi.encode(cs, "cs", reviewAttempts)));
        if (mode % 2 == 0) createCompleted(s, cs, mode >> 16, mode % 4 == 0, mode >> 32);
        reviewAttempts++;
        // occasionally out-of-range ratings / long comments / bogus escrow ids
        if (mode % 5 != 0) rating = uint8(bound(rating, 1, 5));
        commentLen = mode % 7 == 0 ? bound(commentLen, 0, 400) : bound(commentLen, 0, 280);
        string memory comment = string(new bytes(commentLen));

        address escrowAddr;
        bytes32 id;
        Rec storage r = recs.length == 0 ? _dummy() : recs[_pickForReview(s, mode)];
        bool bogus = recs.length == 0 || mode % 11 == 0;
        if (bogus) {
            escrowAddr = mode % 2 == 0 ? address(fixedEscrow) : address(metered);
            id = keccak256(abi.encode("bogus", s));
        } else {
            escrowAddr = r.escrow;
            id = r.id;
        }
        address c = bogus ? actors[cs % actors.length] : _caller(cs, r, cs % 8 < 4 ? r.hirer : r.provider);

        bool expected = !bogus && rating >= 1 && rating <= 5 && commentLen <= 280 && r.status == 2
            && r.hirer != r.provider && r.amount >= MIN
            && ((c == r.hirer && !r.revH) || (c == r.provider && !r.revP));
        bool agentHeld = agent.balanceOf(c) > 0;

        vm.prank(c);
        bool ok;
        try reviews.review(escrowAddr, id, rating, comment) { ok = true; } catch {}

        if (ok != expected) {
            violations++;
            return;
        }
        if (!ok) return;
        reviewSuccesses++;
        bool byHirer = c == r.hirer;
        address subject = byHirer ? r.provider : r.hirer;
        uint256 role = byHirer ? 0 : 1;
        if (byHirer) r.revH = true; else r.revP = true;
        g[subject][role][0] += 1;
        g[subject][role][1] += rating;
        if (agentHeld) {
            g[subject][role][2] += 1;
            g[subject][role][3] += rating;
        }
    }

    /// @dev bias: most of the time walk forward to a completed escrow.
    function _pickForReview(uint256 s, uint256 mode) internal view returns (uint256 idx) {
        idx = s % recs.length;
        if (mode % 3 == 0) return idx;
        for (uint256 j; j < recs.length; ++j) {
            uint256 k = (idx + j) % recs.length;
            if (recs[k].status == 2) return k;
        }
    }

    Rec internal dummy;
    function _dummy() internal view returns (Rec storage) { return dummy; }
}

contract BotHireReviewsInvariantTest is Test {
    BotHireReviews reviews;
    ReviewsHandler h;

    function setUp() public {
        Mock18 token = new Mock18();
        address arbiter = makeAddr("arbiter");
        address settler = makeAddr("settler");
        BotHireEscrowV2 f = new BotHireEscrowV2(address(token), arbiter);
        BotHireMeteredEscrow m = new BotHireMeteredEscrow(address(token), settler, arbiter);
        InvMockAgentId agent = new InvMockAgentId();
        address[] memory list = new address[](2);
        list[0] = address(f);
        list[1] = address(m);
        reviews = new BotHireReviews(list, address(agent), 1e18);
        h = new ReviewsHandler(reviews, f, m, token, agent, arbiter, settler);
        targetContract(address(h));
    }

    /// (a) statsByRole == ghost; stats() == sum of both roles.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_a_statsMatchGhost() public view {
        for (uint256 i; i < h.actorsLen(); ++i) {
            address s = h.actors(i);
            uint256[4] memory tot;
            for (uint256 role; role < 2; ++role) {
                (uint64 c, uint64 sum, uint64 ac, uint64 asum) = reviews.statsByRole(s, role == 0);
                uint256[4] memory gh = h.ghost(s, role);
                assertEq(c, gh[0], "count");
                assertEq(sum, gh[1], "sum");
                assertEq(ac, gh[2], "aCount");
                assertEq(asum, gh[3], "aSum");
                tot[0] += c; tot[1] += sum; tot[2] += ac; tot[3] += asum;
            }
            (uint64 c2, uint64 s2, uint64 a2, uint64 as2) = reviews.stats(s);
            assertEq(c2, tot[0]); assertEq(s2, tot[1]); assertEq(a2, tot[2]); assertEq(as2, tot[3]);
        }
        (uint64 cs,,,) = reviews.stats(h.stranger());
        assertEq(cs, 0, "stranger has stats");
    }

    /// (b) bounds.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_b_bounds() public view {
        for (uint256 i; i < h.actorsLen(); ++i) {
            for (uint256 role; role < 2; ++role) {
                (uint64 c, uint64 sum, uint64 ac, uint64 asum) = reviews.statsByRole(h.actors(i), role == 0);
                assertLe(ac, c);
                assertLe(asum, sum);
                assertGe(sum, c);
                assertLe(uint256(sum), uint256(c) * 5);
                assertGe(asum, ac);
                assertLe(uint256(asum), uint256(ac) * 5);
            }
        }
    }

    /// (c) every review outcome matched the eligibility predicate (and escrow transitions matched the model).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_c_reviewEligibility() public view {
        assertEq(h.violations(), 0, "review outcome != prediction");
        assertEq(h.escrowViolations(), 0, "escrow model drift");
    }

    /// (d) hasReviewed matches ghost.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_d_hasReviewed() public view {
        for (uint256 i; i < h.recsLen(); ++i) {
            ReviewsHandler.Rec memory r = h.rec(i);
            assertEq(reviews.hasReviewed(r.escrow, r.id, true), r.revH, "hirer side");
            assertEq(reviews.hasReviewed(r.escrow, r.id, false), r.revP, "provider side");
            if (r.revH || r.revP) {
                assertEq(r.status, 2);
                assertTrue(r.hirer != r.provider);
                assertGe(r.amount, 1e18);
            }
        }
    }

    uint256 internal sumSucc;
    uint256 internal sumAtt;

    function afterInvariant() public {
        console2.log("reviewAttempts", h.reviewAttempts(), "reviewSuccesses", h.reviewSuccesses());
        console2.log("escrows", h.recsLen(), "handlerCalls", h.calls());
    }
}

contract BotHireReviewsFuzzTest is Test {
    BotHireReviews reviews;
    BotHireEscrowV2 f;
    Mock18 token;
    address hirer = makeAddr("hirer");
    address provider = makeAddr("provider");
    bytes32 id;

    function setUp() public {
        token = new Mock18();
        f = new BotHireEscrowV2(address(token), makeAddr("arbiter"));
        address[] memory list = new address[](1);
        list[0] = address(f);
        reviews = new BotHireReviews(list, address(0), 1e18);
        token.mint(hirer, 10e18);
        vm.startPrank(hirer);
        token.approve(address(f), type(uint256).max);
        f.deposit(bytes32(uint256(1)), provider, 5e18);
        id = f.computeEscrowId(hirer, bytes32(uint256(1)));
        f.release(id);
        vm.stopPrank();
    }

    function testFuzz_ratingOutOfRangeReverts(uint8 rating) public {
        vm.assume(rating == 0 || rating > 5);
        vm.prank(hirer);
        vm.expectRevert(BotHireReviews.InvalidRating.selector);
        reviews.review(address(f), id, rating, "x");
    }

    function testFuzz_commentTooLongReverts(uint256 len, uint8 rating) public {
        len = bound(len, 281, 2000);
        rating = uint8(bound(rating, 1, 5));
        vm.prank(hirer);
        vm.expectRevert(BotHireReviews.CommentTooLong.selector);
        reviews.review(address(f), id, rating, string(new bytes(len)));
    }

    function testFuzz_validRatingAndCommentSucceeds(uint8 rating, uint256 len) public {
        rating = uint8(bound(rating, 1, 5));
        len = bound(len, 0, 280);
        vm.prank(hirer);
        reviews.review(address(f), id, rating, string(new bytes(len)));
        (uint64 c, uint64 s,,) = reviews.stats(provider);
        assertEq(c, 1);
        assertEq(s, rating);
    }
}

