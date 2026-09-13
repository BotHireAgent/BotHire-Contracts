// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BotHireMeteredEscrowV2} from "../src/BotHireMeteredEscrowV2.sol";
import {ISignatureTransfer} from "../src/IPermit2.sol";
import {MockUSDC, Mock18, MockPermit2} from "./EscrowMocks.sol";

contract BotHireMeteredEscrowV2Test is Test {
    BotHireMeteredEscrowV2 public escrow;
    MockUSDC public usdc;
    MockPermit2 public permit2;

    address owner = address(this);
    address settler = makeAddr("settler");
    address arbiter = makeAddr("arbiter");
    address hirer = makeAddr("hirer");
    address provider = makeAddr("provider");
    address attacker = makeAddr("attacker");
    address relayer = makeAddr("relayer");
    address anyone = makeAddr("anyone");

    bytes32 ref = keccak256("hire-001");
    bytes32 escrowId = keccak256(abi.encode(hirer, keccak256("hire-001")));
    uint256 maxAmount = 5_000_000; // 5 USDC (6-dec) budget

    function setUp() public {
        usdc = new MockUSDC();
        permit2 = new MockPermit2();
        escrow = new BotHireMeteredEscrowV2(address(usdc), settler, arbiter, address(permit2));
        usdc.mint(hirer, 100_000_000);
        vm.prank(hirer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _deposit() internal {
        vm.prank(hirer);
        escrow.deposit(ref, provider, maxAmount);
    }

    function _status(bytes32 id) internal view returns (BotHireMeteredEscrowV2.EscrowStatus s) {
        (, , , , , s) = escrow.getEscrow(id);
    }

    // ---------- constructor ----------

    function test_constructor_setsRoles() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.settler(), settler);
        assertEq(escrow.arbiter(), arbiter);
        assertEq(address(escrow.usdc()), address(usdc));
        assertEq(address(escrow.PERMIT2()), address(permit2));
    }

    function test_constructor_revert_zeroPermit2() public {
        vm.expectRevert(BotHireMeteredEscrowV2.ZeroAddress.selector);
        new BotHireMeteredEscrowV2(address(usdc), settler, arbiter, address(0));
    }

    // ---------- classic deposit + settle parity ----------

    function test_deposit_happy() public {
        _deposit();
        (address h, address p, uint256 mx, , , BotHireMeteredEscrowV2.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(h, hirer);
        assertEq(p, provider);
        assertEq(mx, maxAmount);
        assertEq(uint256(s), uint256(BotHireMeteredEscrowV2.EscrowStatus.Deposited));
        assertEq(usdc.balanceOf(address(escrow)), maxAmount);
    }

    function test_settle_actualBelowMax_refundsRemainder() public {
        _deposit();
        uint256 actual = 3_000_000;
        uint256 hirerBefore = usdc.balanceOf(hirer);
        vm.prank(settler);
        escrow.settle(escrowId, actual);
        assertEq(usdc.balanceOf(provider), actual, "provider paid actual");
        assertEq(usdc.balanceOf(hirer), hirerBefore + (maxAmount - actual), "hirer refunded remainder");
        assertEq(uint256(_status(escrowId)), uint256(BotHireMeteredEscrowV2.EscrowStatus.Settled));
    }

    function test_settle_revert_exceedsBudget() public {
        _deposit();
        vm.prank(settler);
        vm.expectRevert(BotHireMeteredEscrowV2.AmountExceedsBudget.selector);
        escrow.settle(escrowId, maxAmount + 1);
    }

    function test_settle_revert_notSettler() public {
        _deposit();
        vm.prank(attacker);
        vm.expectRevert(BotHireMeteredEscrowV2.NotSettler.selector);
        escrow.settle(escrowId, 1);
    }

    function test_claimRefund_afterTimeout() public {
        _deposit();
        vm.warp(block.timestamp + 24 hours + 1);
        uint256 before = usdc.balanceOf(hirer);
        vm.prank(anyone);
        escrow.claimRefund(escrowId);
        assertEq(usdc.balanceOf(hirer), before + maxAmount);
    }

    function test_dispute_resolve_split() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        uint256 hirerBefore = usdc.balanceOf(hirer);
        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, 2_000_000);
        assertEq(usdc.balanceOf(provider), 2_000_000);
        assertEq(usdc.balanceOf(hirer), hirerBefore + (maxAmount - 2_000_000));
    }

    // ============================================================
    // GASLESS deposit via Permit2 — the V2 addition
    // ============================================================

    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant ESCROW_DEPOSIT_WITNESS_TYPEHASH = keccak256("EscrowDeposit(bytes32 ref,address provider)");
    string constant FULL_WITNESS_TYPE =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,EscrowDeposit witness)EscrowDeposit(bytes32 ref,address provider)TokenPermissions(address token,uint256 amount)";

    function _depositDigest(
        address tokenAddr,
        uint256 amt,
        uint256 nonce,
        uint256 deadline,
        bytes32 ref_,
        address provider_
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(bytes(FULL_WITNESS_TYPE)),
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, tokenAddr, amt)),
                address(escrow),
                nonce,
                deadline,
                keccak256(abi.encode(ESCROW_DEPOSIT_WITNESS_TYPEHASH, ref_, provider_))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
    }

    function _signDeposit(
        uint256 buyerPk,
        address tokenAddr,
        uint256 amt,
        uint256 nonce,
        uint256 deadline,
        bytes32 ref_,
        address provider_
    ) internal view returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(buyerPk, _depositDigest(tokenAddr, amt, nonce, deadline, ref_, provider_));
        sig = abi.encodePacked(r, s, v);
    }

    function _buyerSetup(uint256 pk) internal returns (address buyer) {
        buyer = vm.addr(pk);
        usdc.mint(buyer, 100_000_000);
        vm.prank(buyer);
        usdc.approve(address(permit2), type(uint256).max);
    }

    function _permit(uint256 amt, uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdc), amount: amt}),
            nonce: nonce,
            deadline: deadline
        });
    }

    function test_depositWithPermit2_happy_thenSettle() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(usdc), maxAmount, 0, deadline, ref, provider);

        vm.prank(relayer);
        escrow.depositWithPermit2(_permit(maxAmount, 0, deadline), buyer, ref, provider, sig);

        bytes32 id = escrow.computeEscrowId(buyer, ref);
        (address h, , uint256 mx, , , BotHireMeteredEscrowV2.EscrowStatus s) = escrow.getEscrow(id);
        assertEq(h, buyer, "hirer is the signer, not the relayer");
        assertEq(mx, maxAmount);
        assertEq(uint256(s), uint256(BotHireMeteredEscrowV2.EscrowStatus.Deposited));
        assertEq(usdc.balanceOf(address(escrow)), maxAmount);

        // settle actual < max: provider paid, buyer refunded the rest
        uint256 actual = 2_000_000;
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(settler);
        escrow.settle(id, actual);
        assertEq(usdc.balanceOf(provider), actual);
        assertEq(usdc.balanceOf(buyer), buyerBefore + (maxAmount - actual));
    }

    function test_depositWithPermit2_revert_relayerTampersProvider() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(usdc), maxAmount, 0, deadline, ref, provider);
        vm.prank(relayer);
        vm.expectRevert(); // Permit2 InvalidSigner (witness mismatch)
        escrow.depositWithPermit2(_permit(maxAmount, 0, deadline), buyer, ref, makeAddr("evil"), sig);
    }

    function test_depositWithPermit2_revert_relayerTampersAmount() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(usdc), maxAmount, 0, deadline, ref, provider);
        vm.prank(relayer);
        vm.expectRevert(); // permitted.amount differs from signed → InvalidSigner
        escrow.depositWithPermit2(_permit(maxAmount * 2, 0, deadline), buyer, ref, provider, sig);
    }

    function test_depositWithPermit2_revert_wrongToken() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        Mock18 other = new Mock18();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(other), maxAmount, 0, deadline, ref, provider);
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(other), amount: maxAmount}),
            nonce: 0,
            deadline: deadline
        });
        vm.prank(relayer);
        vm.expectRevert(BotHireMeteredEscrowV2.TokenMismatch.selector);
        escrow.depositWithPermit2(permit, buyer, ref, provider, sig);
    }

    function test_depositWithPermit2_revert_replaySameEscrow() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(usdc), maxAmount, 0, deadline, ref, provider);
        vm.prank(relayer);
        escrow.depositWithPermit2(_permit(maxAmount, 0, deadline), buyer, ref, provider, sig);
        vm.prank(relayer);
        vm.expectRevert(BotHireMeteredEscrowV2.EscrowAlreadyExists.selector);
        escrow.depositWithPermit2(_permit(maxAmount, 0, deadline), buyer, ref, provider, sig);
    }
}
