// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BotHireMeteredEscrow} from "../src/BotHireMeteredEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock USDC for testing (6 decimals)
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BotHireMeteredEscrowTest is Test {
    BotHireMeteredEscrow public escrow;
    MockUSDC public usdc;

    address owner = address(this); // deployer = test contract
    address settler = makeAddr("settler");
    address arbiter = makeAddr("arbiter");
    address hirer = makeAddr("hirer");
    address provider = makeAddr("provider");
    address anyone = makeAddr("anyone");

    bytes32 ref = keccak256("hire-001");
    // The on-chain key is namespaced by the depositor (hirer).
    bytes32 escrowId = keccak256(abi.encode(hirer, keccak256("hire-001")));
    uint256 maxAmount = 5_000_000; // 5 USDC max budget

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new BotHireMeteredEscrow(address(usdc), settler, arbiter);

        usdc.mint(hirer, 100_000_000); // 100 USDC
        vm.prank(hirer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _deposit() internal {
        vm.prank(hirer);
        escrow.deposit(ref, provider, maxAmount);
    }

    // ========== Constructor ==========

    function test_constructor_setsRoles() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.settler(), settler);
        assertEq(escrow.arbiter(), arbiter);
        assertEq(address(escrow.usdc()), address(usdc));
    }

    function test_constructor_revert_zeroUsdc() public {
        vm.expectRevert(BotHireMeteredEscrow.ZeroAddress.selector);
        new BotHireMeteredEscrow(address(0), settler, arbiter);
    }

    function test_constructor_revert_zeroSettler() public {
        vm.expectRevert(BotHireMeteredEscrow.ZeroAddress.selector);
        new BotHireMeteredEscrow(address(usdc), address(0), arbiter);
    }

    function test_constructor_revert_zeroArbiter() public {
        vm.expectRevert(BotHireMeteredEscrow.ZeroAddress.selector);
        new BotHireMeteredEscrow(address(usdc), settler, address(0));
    }

    // ========== deposit ==========

    function test_deposit() public {
        _deposit();
        (address h, address p, uint256 a, uint256 d, uint256 dis, BotHireMeteredEscrow.EscrowStatus s) =
            escrow.getEscrow(escrowId);
        assertEq(h, hirer);
        assertEq(p, provider);
        assertEq(a, maxAmount);
        assertGt(d, block.timestamp);
        assertEq(dis, 0);
        assertEq(uint8(s), uint8(BotHireMeteredEscrow.EscrowStatus.Deposited));
        assertEq(usdc.balanceOf(address(escrow)), maxAmount);
    }

    function test_deposit_revert_duplicate() public {
        _deposit();
        vm.prank(hirer);
        vm.expectRevert(BotHireMeteredEscrow.EscrowAlreadyExists.selector);
        escrow.deposit(ref, provider, maxAmount);
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(hirer);
        vm.expectRevert(BotHireMeteredEscrow.ZeroAmount.selector);
        escrow.deposit(ref, provider, 0);
    }

    function test_deposit_revert_zeroProvider() public {
        vm.prank(hirer);
        vm.expectRevert(BotHireMeteredEscrow.ZeroAddress.selector);
        escrow.deposit(ref, address(0), maxAmount);
    }

    // ========== settle (the metered core) ==========

    function test_settle_partial_paysActual_refundsRemainder() public {
        _deposit();
        uint256 actual = 1_800_000; // used 1.8 of 5 USDC
        uint256 hirerBefore = usdc.balanceOf(hirer);
        uint256 providerBefore = usdc.balanceOf(provider);

        vm.prank(settler);
        escrow.settle(escrowId, actual);

        assertEq(usdc.balanceOf(provider), providerBefore + actual, "provider paid actual");
        assertEq(usdc.balanceOf(hirer), hirerBefore + (maxAmount - actual), "hirer refunded remainder");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow emptied");

        (, , , , , BotHireMeteredEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireMeteredEscrow.EscrowStatus.Settled));
    }

    function test_settle_full_paysMax_noRefund() public {
        _deposit();
        uint256 hirerBefore = usdc.balanceOf(hirer);

        vm.prank(settler);
        escrow.settle(escrowId, maxAmount);

        assertEq(usdc.balanceOf(provider), maxAmount);
        assertEq(usdc.balanceOf(hirer), hirerBefore); // no remainder
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_settle_zero_refundsAll() public {
        _deposit();
        uint256 hirerBefore = usdc.balanceOf(hirer);

        vm.prank(settler);
        escrow.settle(escrowId, 0);

        assertEq(usdc.balanceOf(provider), 0);
        assertEq(usdc.balanceOf(hirer), hirerBefore + maxAmount);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_settle_revert_notSettler() public {
        _deposit();
        vm.prank(hirer);
        vm.expectRevert(BotHireMeteredEscrow.NotSettler.selector);
        escrow.settle(escrowId, 1_000_000);
    }

    function test_settle_revert_exceedsBudget() public {
        _deposit();
        vm.prank(settler);
        vm.expectRevert(BotHireMeteredEscrow.AmountExceedsBudget.selector);
        escrow.settle(escrowId, maxAmount + 1);
    }

    function test_settle_revert_notFound() public {
        vm.prank(settler);
        vm.expectRevert(BotHireMeteredEscrow.EscrowNotFound.selector);
        escrow.settle(escrowId, 1_000_000);
    }

    function test_settle_revert_alreadySettled() public {
        _deposit();
        vm.prank(settler);
        escrow.settle(escrowId, 1_000_000);
        vm.prank(settler);
        vm.expectRevert(BotHireMeteredEscrow.NotDeposited.selector);
        escrow.settle(escrowId, 1_000_000);
    }

    // ========== claimRefund (timeout) ==========

    function test_claimRefund_afterDeadline() public {
        _deposit();
        uint256 hirerBefore = usdc.balanceOf(hirer);
        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(anyone);
        escrow.claimRefund(escrowId);

        assertEq(usdc.balanceOf(hirer), hirerBefore + maxAmount);
        (, , , , , BotHireMeteredEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireMeteredEscrow.EscrowStatus.Refunded));
    }

    function test_claimRefund_revert_beforeDeadline() public {
        _deposit();
        vm.prank(anyone);
        vm.expectRevert(BotHireMeteredEscrow.DeadlineNotReached.selector);
        escrow.claimRefund(escrowId);
    }

    function test_claimRefund_revert_afterSettled() public {
        _deposit();
        vm.prank(settler);
        escrow.settle(escrowId, 1_000_000);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(anyone);
        vm.expectRevert(BotHireMeteredEscrow.NotDeposited.selector);
        escrow.claimRefund(escrowId);
    }

    // ========== dispute ==========

    function test_dispute_byHirer() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        (, , , , uint256 dis, BotHireMeteredEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireMeteredEscrow.EscrowStatus.Disputed));
        assertEq(dis, block.timestamp);
    }

    function test_dispute_byProvider() public {
        _deposit();
        vm.prank(provider);
        escrow.dispute(escrowId);
        (, , , , , BotHireMeteredEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireMeteredEscrow.EscrowStatus.Disputed));
    }

    function test_dispute_revert_notParty() public {
        _deposit();
        vm.prank(anyone);
        vm.expectRevert(BotHireMeteredEscrow.NotParty.selector);
        escrow.dispute(escrowId);
    }

    function test_dispute_blocksSettle() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        // settler can no longer unilaterally settle a disputed escrow
        vm.prank(settler);
        vm.expectRevert(BotHireMeteredEscrow.NotDeposited.selector);
        escrow.settle(escrowId, maxAmount);
    }

    // ========== resolveDispute ==========

    function test_resolveDispute_split() public {
        _deposit();
        vm.prank(provider);
        escrow.dispute(escrowId);

        uint256 toProvider = 3_000_000;
        uint256 hirerBefore = usdc.balanceOf(hirer);

        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, toProvider);

        assertEq(usdc.balanceOf(provider), toProvider);
        assertEq(usdc.balanceOf(hirer), hirerBefore + (maxAmount - toProvider));
        assertEq(usdc.balanceOf(address(escrow)), 0);
        (, , , , , BotHireMeteredEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireMeteredEscrow.EscrowStatus.Settled));
    }

    function test_resolveDispute_revert_notArbiter() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.prank(settler); // even settler cannot resolve
        vm.expectRevert(BotHireMeteredEscrow.NotArbiter.selector);
        escrow.resolveDispute(escrowId, 1_000_000);
    }

    function test_resolveDispute_revert_notDisputed() public {
        _deposit();
        vm.prank(arbiter);
        vm.expectRevert(BotHireMeteredEscrow.NotDisputed.selector);
        escrow.resolveDispute(escrowId, 1_000_000);
    }

    function test_resolveDispute_revert_exceedsBudget() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.prank(arbiter);
        vm.expectRevert(BotHireMeteredEscrow.AmountExceedsBudget.selector);
        escrow.resolveDispute(escrowId, maxAmount + 1);
    }

    // ========== claimDisputeTimeout ==========

    function test_claimDisputeTimeout_afterWindow() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        uint256 hirerBefore = usdc.balanceOf(hirer);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(anyone);
        escrow.claimDisputeTimeout(escrowId);

        assertEq(usdc.balanceOf(hirer), hirerBefore + maxAmount);
        (, , , , , BotHireMeteredEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireMeteredEscrow.EscrowStatus.Refunded));
    }

    function test_claimDisputeTimeout_revert_tooEarly() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.prank(anyone);
        vm.expectRevert(BotHireMeteredEscrow.DisputeWindowNotElapsed.selector);
        escrow.claimDisputeTimeout(escrowId);
    }

    function test_claimDisputeTimeout_revert_notDisputed() public {
        _deposit();
        vm.prank(anyone);
        vm.expectRevert(BotHireMeteredEscrow.NotDisputed.selector);
        escrow.claimDisputeTimeout(escrowId);
    }

    // ========== Admin ==========

    function test_setSettler() public {
        address newSettler = makeAddr("newSettler");
        escrow.setSettler(newSettler);
        assertEq(escrow.settler(), newSettler);
        // old settler can no longer settle
        _deposit();
        vm.prank(settler);
        vm.expectRevert(BotHireMeteredEscrow.NotSettler.selector);
        escrow.settle(escrowId, 1_000_000);
        // new settler can
        vm.prank(newSettler);
        escrow.settle(escrowId, 1_000_000);
        assertEq(usdc.balanceOf(provider), 1_000_000);
    }

    function test_setSettler_revert_notOwner() public {
        vm.prank(anyone);
        vm.expectRevert(BotHireMeteredEscrow.NotOwner.selector);
        escrow.setSettler(anyone);
    }

    function test_setSettler_revert_zero() public {
        vm.expectRevert(BotHireMeteredEscrow.ZeroAddress.selector);
        escrow.setSettler(address(0));
    }

    function test_setArbiter() public {
        address newArbiter = makeAddr("newArbiter");
        escrow.setArbiter(newArbiter);
        assertEq(escrow.arbiter(), newArbiter);
    }

    function test_setArbiter_revert_notOwner() public {
        vm.prank(anyone);
        vm.expectRevert(BotHireMeteredEscrow.NotOwner.selector);
        escrow.setArbiter(anyone);
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), newOwner);
        // old owner loses admin
        vm.expectRevert(BotHireMeteredEscrow.NotOwner.selector);
        escrow.setSettler(anyone);
    }

    function test_transferOwnership_revert_notOwner() public {
        vm.prank(anyone);
        vm.expectRevert(BotHireMeteredEscrow.NotOwner.selector);
        escrow.transferOwnership(anyone);
    }

    // ========== Invariant: contract never keeps funds after a terminal state ==========

    function testFuzz_settle_conservesFunds(uint256 budget, uint256 actual) public {
        budget = bound(budget, 1, 50_000_000);
        actual = bound(actual, 0, budget);
        bytes32 fref = keccak256("fuzz");
        bytes32 id = keccak256(abi.encode(hirer, fref));

        usdc.mint(hirer, budget);
        vm.prank(hirer);
        usdc.approve(address(escrow), type(uint256).max);
        uint256 hirerBefore = usdc.balanceOf(hirer);

        vm.prank(hirer);
        escrow.deposit(fref, provider, budget);
        vm.prank(settler);
        escrow.settle(id, actual);

        // provider got exactly `actual`, hirer net-paid exactly `actual`, escrow empty
        assertEq(usdc.balanceOf(provider), actual);
        assertEq(usdc.balanceOf(hirer), hirerBefore - actual);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testFuzz_resolveDispute_conservesFunds(uint256 budget, uint256 toProvider) public {
        budget = bound(budget, 1, 50_000_000);
        toProvider = bound(toProvider, 0, budget);
        bytes32 fref = keccak256("fuzz-dispute");
        bytes32 id = keccak256(abi.encode(hirer, fref));

        usdc.mint(hirer, budget);
        vm.prank(hirer);
        usdc.approve(address(escrow), type(uint256).max);
        uint256 hirerBefore = usdc.balanceOf(hirer);

        vm.prank(hirer);
        escrow.deposit(fref, provider, budget);
        vm.prank(provider);
        escrow.dispute(id);
        vm.prank(arbiter);
        escrow.resolveDispute(id, toProvider);

        assertEq(usdc.balanceOf(provider), toProvider);
        assertEq(usdc.balanceOf(hirer), hirerBefore - toProvider);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // ========== escrowId namespacing (front-run squat defense) ==========

    function test_computeEscrowId_matches() public view {
        assertEq(escrow.computeEscrowId(hirer, ref), escrowId);
    }

    function test_squat_cannotCollideAcrossDepositors() public {
        // Attacker deposits under the SAME ref as the victim would use.
        usdc.mint(anyone, 10_000_000);
        vm.prank(anyone);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(anyone);
        escrow.deposit(ref, provider, 1); // attacker squats `ref`

        // Victim's deposit under the same ref still succeeds — different namespaced key.
        _deposit();
        (address h, , uint256 a, , , BotHireMeteredEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(h, hirer);
        assertEq(a, maxAmount);
        assertEq(uint8(s), uint8(BotHireMeteredEscrow.EscrowStatus.Deposited));

        // The attacker's escrow is a distinct key and untouched.
        bytes32 attackerId = keccak256(abi.encode(anyone, ref));
        (address ah, , uint256 aa, , , ) = escrow.getEscrow(attackerId);
        assertEq(ah, anyone);
        assertEq(aa, 1);
    }

    // ========== state-machine guards ==========

    function test_claimRefund_revert_onDisputed() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(anyone);
        vm.expectRevert(BotHireMeteredEscrow.NotDeposited.selector);
        escrow.claimRefund(escrowId);
    }

    function test_dispute_revert_afterSettled() public {
        _deposit();
        vm.prank(settler);
        escrow.settle(escrowId, 1_000_000);
        vm.prank(hirer);
        vm.expectRevert(BotHireMeteredEscrow.NotDeposited.selector);
        escrow.dispute(escrowId);
    }

    function test_dispute_revert_doubleDispute() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.prank(provider);
        vm.expectRevert(BotHireMeteredEscrow.NotDeposited.selector);
        escrow.dispute(escrowId);
    }

    // ========== event correctness (emitted amounts == transfers) ==========

    function test_settle_emitsSettledWithExactAmounts() public {
        _deposit();
        vm.expectEmit(true, true, false, true, address(escrow));
        emit BotHireMeteredEscrow.Settled(escrowId, provider, 1_800_000, maxAmount - 1_800_000);
        vm.prank(settler);
        escrow.settle(escrowId, 1_800_000);
    }

    function test_resolveDispute_emitsSettledWithExactAmounts() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit BotHireMeteredEscrow.Settled(escrowId, provider, 2_000_000, maxAmount - 2_000_000);
        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, 2_000_000);
    }

    function test_claimRefund_emitsRefunded() public {
        _deposit();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit BotHireMeteredEscrow.Refunded(escrowId, hirer, maxAmount);
        vm.prank(anyone);
        escrow.claimRefund(escrowId);
    }

    function test_dispute_emitsDisputed() public {
        _deposit();
        vm.expectEmit(true, true, false, false, address(escrow));
        emit BotHireMeteredEscrow.Disputed(escrowId, hirer);
        vm.prank(hirer);
        escrow.dispute(escrowId);
    }

    // ========== arbiter rotation is effective end-to-end ==========

    function test_setArbiter_newArbiterResolves_oldCannot() public {
        address newArbiter = makeAddr("newArbiter");
        escrow.setArbiter(newArbiter);

        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);

        // old arbiter is now powerless
        vm.prank(arbiter);
        vm.expectRevert(BotHireMeteredEscrow.NotArbiter.selector);
        escrow.resolveDispute(escrowId, 1_000_000);

        // new arbiter can resolve
        vm.prank(newArbiter);
        escrow.resolveDispute(escrowId, 1_000_000);
        assertEq(usdc.balanceOf(provider), 1_000_000);
        (, , , , , BotHireMeteredEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireMeteredEscrow.EscrowStatus.Settled));
    }
}
