// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BotHireEscrowV2} from "../src/BotHireEscrowV2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock 6-decimal token (USDC-like, Base).
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Mock 18-decimal token (BNB USDT/USDC-like) — proves the contract is decimal-agnostic.
contract Mock18 is ERC20 {
    constructor() ERC20("BSC USD", "USDT") {}
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract BotHireEscrowV2Test is Test {
    BotHireEscrowV2 public escrow;
    MockUSDC public usdc;

    address owner = address(this);
    address arbiter = makeAddr("arbiter");
    address hirer = makeAddr("hirer");
    address provider = makeAddr("provider");
    address attacker = makeAddr("attacker");
    address anyone = makeAddr("anyone");

    bytes32 ref = keccak256("hire-001");
    bytes32 escrowId = keccak256(abi.encode(hirer, keccak256("hire-001")));
    uint256 amount = 5_000_000; // 5 USDC (6-dec)

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new BotHireEscrowV2(address(usdc), arbiter);
        usdc.mint(hirer, 100_000_000);
        vm.prank(hirer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _deposit() internal {
        vm.prank(hirer);
        escrow.deposit(ref, provider, amount);
    }

    function _status(bytes32 id) internal view returns (BotHireEscrowV2.EscrowStatus s) {
        (, , , , , s) = escrow.getEscrow(id);
    }

    // ---------- constructor ----------

    function test_constructor_setsRoles() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.arbiter(), arbiter);
        assertEq(address(escrow.token()), address(usdc));
    }

    function test_constructor_revert_zeroToken() public {
        vm.expectRevert(BotHireEscrowV2.ZeroAddress.selector);
        new BotHireEscrowV2(address(0), arbiter);
    }

    function test_constructor_revert_zeroArbiter() public {
        vm.expectRevert(BotHireEscrowV2.ZeroAddress.selector);
        new BotHireEscrowV2(address(usdc), address(0));
    }

    // ---------- deposit ----------

    function test_deposit_happy() public {
        _deposit();
        (address h, address p, uint256 a, uint256 dl, uint256 dAt, BotHireEscrowV2.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(h, hirer);
        assertEq(p, provider);
        assertEq(a, amount);
        assertEq(dl, block.timestamp + 24 hours);
        assertEq(dAt, 0);
        assertEq(uint256(s), uint256(BotHireEscrowV2.EscrowStatus.Deposited));
        assertEq(usdc.balanceOf(address(escrow)), amount);
    }

    function test_deposit_computeEscrowId_matches() public view {
        assertEq(escrow.computeEscrowId(hirer, ref), escrowId);
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV2.ZeroAmount.selector);
        escrow.deposit(ref, provider, 0);
    }

    function test_deposit_revert_zeroProvider() public {
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV2.ZeroAddress.selector);
        escrow.deposit(ref, address(0), amount);
    }

    function test_deposit_revert_alreadyExists() public {
        _deposit();
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV2.EscrowAlreadyExists.selector);
        escrow.deposit(ref, provider, amount);
    }

    /// @dev The attacker using the SAME ref gets a DIFFERENT (namespaced) id — cannot brick the hirer.
    function test_deposit_frontrunSquat_resistant() public {
        usdc.mint(attacker, 100_000_000);
        vm.prank(attacker);
        usdc.approve(address(escrow), type(uint256).max);
        // Attacker front-runs with the victim's ref.
        vm.prank(attacker);
        escrow.deposit(ref, provider, amount);
        // Victim's deposit still succeeds — different key.
        _deposit();
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV2.EscrowStatus.Deposited));
        bytes32 attackerId = keccak256(abi.encode(attacker, ref));
        assertTrue(attackerId != escrowId);
        assertEq(uint256(_status(attackerId)), uint256(BotHireEscrowV2.EscrowStatus.Deposited));
    }

    // ---------- release ----------

    function test_release_happy() public {
        _deposit();
        vm.prank(hirer);
        escrow.release(escrowId);
        assertEq(usdc.balanceOf(provider), amount);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV2.EscrowStatus.Released));
    }

    function test_release_revert_notHirer() public {
        _deposit();
        vm.prank(provider);
        vm.expectRevert(BotHireEscrowV2.NotHirer.selector);
        escrow.release(escrowId);
    }

    function test_release_revert_notFound() public {
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV2.EscrowNotFound.selector);
        escrow.release(escrowId);
    }

    function test_release_revert_alreadyReleased() public {
        _deposit();
        vm.prank(hirer);
        escrow.release(escrowId);
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV2.NotDeposited.selector);
        escrow.release(escrowId);
    }

    // ---------- refund (voluntary) ----------

    function test_refund_happy() public {
        _deposit();
        uint256 before = usdc.balanceOf(hirer);
        vm.prank(hirer);
        escrow.refund(escrowId);
        assertEq(usdc.balanceOf(hirer), before + amount);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV2.EscrowStatus.Refunded));
    }

    function test_refund_revert_notHirer() public {
        _deposit();
        vm.prank(anyone);
        vm.expectRevert(BotHireEscrowV2.NotHirer.selector);
        escrow.refund(escrowId);
    }

    // ---------- claimRefund (timeout) ----------

    function test_claimRefund_revert_beforeDeadline() public {
        _deposit();
        vm.prank(anyone);
        vm.expectRevert(BotHireEscrowV2.DeadlineNotReached.selector);
        escrow.claimRefund(escrowId);
    }

    function test_claimRefund_happy_afterDeadline_byAnyone() public {
        _deposit();
        uint256 before = usdc.balanceOf(hirer);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(anyone); // permissionless
        escrow.claimRefund(escrowId);
        assertEq(usdc.balanceOf(hirer), before + amount);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV2.EscrowStatus.Refunded));
    }

    function test_claimRefund_revert_afterReleased() public {
        _deposit();
        vm.prank(hirer);
        escrow.release(escrowId);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(anyone);
        vm.expectRevert(BotHireEscrowV2.NotDeposited.selector);
        escrow.claimRefund(escrowId);
    }

    // ---------- dispute ----------

    function test_dispute_byHirer() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        (, , , , uint256 dAt, BotHireEscrowV2.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint256(s), uint256(BotHireEscrowV2.EscrowStatus.Disputed));
        assertEq(dAt, block.timestamp);
    }

    function test_dispute_byProvider() public {
        _deposit();
        vm.prank(provider);
        escrow.dispute(escrowId);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV2.EscrowStatus.Disputed));
    }

    function test_dispute_revert_notParty() public {
        _deposit();
        vm.prank(anyone);
        vm.expectRevert(BotHireEscrowV2.NotParty.selector);
        escrow.dispute(escrowId);
    }

    function test_dispute_revert_notDeposited() public {
        _deposit();
        vm.prank(hirer);
        escrow.release(escrowId);
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV2.NotDeposited.selector);
        escrow.dispute(escrowId);
    }

    // ---------- resolveDispute ----------

    function test_resolveDispute_toProvider() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, true);
        assertEq(usdc.balanceOf(provider), amount);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV2.EscrowStatus.Released));
    }

    function test_resolveDispute_toHirer() public {
        _deposit();
        uint256 before = usdc.balanceOf(hirer);
        vm.prank(provider);
        escrow.dispute(escrowId);
        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, false);
        assertEq(usdc.balanceOf(hirer), before + amount);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV2.EscrowStatus.Refunded));
    }

    function test_resolveDispute_revert_notArbiter() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV2.NotArbiter.selector);
        escrow.resolveDispute(escrowId, true);
    }

    function test_resolveDispute_revert_notDisputed() public {
        _deposit();
        vm.prank(arbiter);
        vm.expectRevert(BotHireEscrowV2.NotDisputed.selector);
        escrow.resolveDispute(escrowId, true);
    }

    // ---------- claimDisputeTimeout ----------

    function test_claimDisputeTimeout_revert_beforeWindow() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.prank(anyone);
        vm.expectRevert(BotHireEscrowV2.DisputeWindowNotElapsed.selector);
        escrow.claimDisputeTimeout(escrowId);
    }

    function test_claimDisputeTimeout_happy() public {
        _deposit();
        uint256 before = usdc.balanceOf(hirer);
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(anyone);
        escrow.claimDisputeTimeout(escrowId);
        assertEq(usdc.balanceOf(hirer), before + amount);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV2.EscrowStatus.Refunded));
    }

    function test_claimDisputeTimeout_revert_notDisputed() public {
        _deposit();
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(anyone);
        vm.expectRevert(BotHireEscrowV2.NotDisputed.selector);
        escrow.claimDisputeTimeout(escrowId);
    }

    // ---------- admin ----------

    function test_setArbiter_onlyOwner() public {
        address newArb = makeAddr("newArb");
        escrow.setArbiter(newArb);
        assertEq(escrow.arbiter(), newArb);
    }

    function test_setArbiter_revert_notOwner() public {
        vm.prank(anyone);
        vm.expectRevert(BotHireEscrowV2.NotOwner.selector);
        escrow.setArbiter(anyone);
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), newOwner);
    }

    /// @dev owner has NO fund access — there is no drain function; confirm via the ABI surface.
    function test_owner_cannot_drain() public {
        _deposit();
        // The only owner functions are setArbiter/transferOwnership; neither moves tokens.
        escrow.setArbiter(makeAddr("x"));
        assertEq(usdc.balanceOf(address(escrow)), amount); // funds untouched
    }

    // ---------- decimal-agnostic (18-dec BNB token) ----------

    function test_decimalAgnostic_18dec_fullFlow() public {
        Mock18 t = new Mock18();
        BotHireEscrowV2 e = new BotHireEscrowV2(address(t), arbiter);
        uint256 amt18 = 5 ether; // 5 * 1e18
        t.mint(hirer, 100 ether);
        vm.startPrank(hirer);
        t.approve(address(e), type(uint256).max);
        e.deposit(ref, provider, amt18);
        e.release(escrowId);
        vm.stopPrank();
        assertEq(t.balanceOf(provider), amt18);
    }
}
