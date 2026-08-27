// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BotHireEscrow} from "../src/BotHireEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BotHireEscrowTest is Test {
    BotHireEscrow public escrow;
    MockUSDC public usdc;

    address hirer = makeAddr("hirer");
    address provider = makeAddr("provider");
    address anyone = makeAddr("anyone");

    bytes32 escrowId = keccak256("hire-001");
    uint256 amount = 5_000_000; // 5 USDC

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new BotHireEscrow(address(usdc));

        // Mint 100 USDC to hirer
        usdc.mint(hirer, 100_000_000);

        // hirer approves the contract
        vm.prank(hirer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ========== deposit tests ==========

    function test_deposit() public {
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        (address h, address p, uint256 a, uint256 d, BotHireEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(h, hirer);
        assertEq(p, provider);
        assertEq(a, amount);
        assertGt(d, block.timestamp);
        assertEq(uint8(s), uint8(BotHireEscrow.EscrowStatus.Deposited));

        // The contract holds the USDC
        assertEq(usdc.balanceOf(address(escrow)), amount);
    }

    function test_deposit_revert_duplicate() public {
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        vm.prank(hirer);
        vm.expectRevert(BotHireEscrow.EscrowAlreadyExists.selector);
        escrow.deposit(escrowId, provider, amount);
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrow.ZeroAmount.selector);
        escrow.deposit(escrowId, provider, 0);
    }

    function test_deposit_revert_zeroAddress() public {
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrow.ZeroAddress.selector);
        escrow.deposit(escrowId, address(0), amount);
    }

    // ========== release tests ==========

    function test_release() public {
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        uint256 providerBefore = usdc.balanceOf(provider);

        vm.prank(hirer);
        escrow.release(escrowId);

        assertEq(usdc.balanceOf(provider), providerBefore + amount);

        (, , , , BotHireEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireEscrow.EscrowStatus.Released));
    }

    function test_release_revert_notHirer() public {
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        vm.prank(anyone);
        vm.expectRevert(BotHireEscrow.NotHirer.selector);
        escrow.release(escrowId);
    }

    function test_release_revert_alreadyReleased() public {
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        vm.prank(hirer);
        escrow.release(escrowId);

        vm.prank(hirer);
        vm.expectRevert(BotHireEscrow.NotDeposited.selector);
        escrow.release(escrowId);
    }

    // ========== refund tests ==========

    function test_refund() public {
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        uint256 hirerBefore = usdc.balanceOf(hirer);

        vm.prank(hirer);
        escrow.refund(escrowId);

        assertEq(usdc.balanceOf(hirer), hirerBefore + amount);

        (, , , , BotHireEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireEscrow.EscrowStatus.Refunded));
    }

    function test_refund_revert_notHirer() public {
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        vm.prank(anyone);
        vm.expectRevert(BotHireEscrow.NotHirer.selector);
        escrow.refund(escrowId);
    }

    // ========== claimRefund tests ==========

    function test_claimRefund_afterDeadline() public {
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        // Fast-forward 24h + 1s
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 hirerBefore = usdc.balanceOf(hirer);

        vm.prank(anyone); // anyone can call
        escrow.claimRefund(escrowId);

        assertEq(usdc.balanceOf(hirer), hirerBefore + amount);

        (, , , , BotHireEscrow.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(uint8(s), uint8(BotHireEscrow.EscrowStatus.Refunded));
    }

    function test_claimRefund_revert_beforeDeadline() public {
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        vm.prank(anyone);
        vm.expectRevert(BotHireEscrow.DeadlineNotReached.selector);
        escrow.claimRefund(escrowId);
    }

    function test_claimRefund_revert_notDeposited() public {
        vm.expectRevert(BotHireEscrow.EscrowNotFound.selector);
        escrow.claimRefund(escrowId);
    }

    // ========== getEscrow tests ==========

    function test_getEscrow_empty() public view {
        (address h, , , , BotHireEscrow.EscrowStatus s) = escrow.getEscrow(keccak256("nonexistent"));
        assertEq(h, address(0));
        assertEq(uint8(s), uint8(BotHireEscrow.EscrowStatus.Empty));
    }

    // ========== Constructor tests ==========

    function test_constructor_revert_zeroUsdc() public {
        vm.expectRevert(BotHireEscrow.ZeroAddress.selector);
        new BotHireEscrow(address(0));
    }

    // ========== Integration flow tests ==========

    function test_fullFlow_depositAndRelease() public {
        // 1. deposit
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        // 2. release
        vm.prank(hirer);
        escrow.release(escrowId);

        // Verify final state
        assertEq(usdc.balanceOf(provider), amount);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_fullFlow_depositAndRefund() public {
        uint256 hirerInitial = usdc.balanceOf(hirer);

        // 1. deposit
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);
        assertEq(usdc.balanceOf(hirer), hirerInitial - amount);

        // 2. refund
        vm.prank(hirer);
        escrow.refund(escrowId);

        // hirer gets everything back
        assertEq(usdc.balanceOf(hirer), hirerInitial);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_fullFlow_depositAndClaimRefund() public {
        uint256 hirerInitial = usdc.balanceOf(hirer);

        // 1. deposit
        vm.prank(hirer);
        escrow.deposit(escrowId, provider, amount);

        // 2. Wait for the timeout
        vm.warp(block.timestamp + 24 hours + 1);

        // 3. Anyone calls claimRefund
        vm.prank(anyone);
        escrow.claimRefund(escrowId);

        assertEq(usdc.balanceOf(hirer), hirerInitial);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}
