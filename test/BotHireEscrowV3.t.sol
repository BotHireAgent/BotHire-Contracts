// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BotHireEscrowV3, ISignatureTransfer} from "../src/BotHireEscrowV3.sol";
import {MockUSDC, Mock18, MockPermit2} from "./EscrowMocks.sol";

contract BotHireEscrowV3Test is Test {
    BotHireEscrowV3 public escrow;
    MockUSDC public usdc;
    MockPermit2 public permit2;

    address owner = address(this);
    address arbiter = makeAddr("arbiter");
    address hirer = makeAddr("hirer");
    address provider = makeAddr("provider");
    address attacker = makeAddr("attacker");
    address relayer = makeAddr("relayer");
    address anyone = makeAddr("anyone");

    bytes32 ref = keccak256("hire-001");
    bytes32 escrowId = keccak256(abi.encode(hirer, keccak256("hire-001")));
    uint256 amount = 5_000_000; // 5 USDC (6-dec)

    function setUp() public {
        usdc = new MockUSDC();
        permit2 = new MockPermit2();
        escrow = new BotHireEscrowV3(address(usdc), arbiter, address(permit2));
        usdc.mint(hirer, 100_000_000);
        vm.prank(hirer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _deposit() internal {
        vm.prank(hirer);
        escrow.deposit(ref, provider, amount);
    }

    function _status(bytes32 id) internal view returns (BotHireEscrowV3.EscrowStatus s) {
        (, , , , , s) = escrow.getEscrow(id);
    }

    // ============================================================
    // Constructor
    // ============================================================

    function test_constructor_setsRoles() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.arbiter(), arbiter);
        assertEq(address(escrow.token()), address(usdc));
        assertEq(address(escrow.PERMIT2()), address(permit2));
    }

    function test_constructor_revert_zeroToken() public {
        vm.expectRevert(BotHireEscrowV3.ZeroAddress.selector);
        new BotHireEscrowV3(address(0), arbiter, address(permit2));
    }

    function test_constructor_revert_zeroArbiter() public {
        vm.expectRevert(BotHireEscrowV3.ZeroAddress.selector);
        new BotHireEscrowV3(address(usdc), address(0), address(permit2));
    }

    function test_constructor_revert_zeroPermit2() public {
        vm.expectRevert(BotHireEscrowV3.ZeroAddress.selector);
        new BotHireEscrowV3(address(usdc), arbiter, address(0));
    }

    // ============================================================
    // Classic deposit — behavioral parity with V2
    // ============================================================

    function test_deposit_happy() public {
        _deposit();
        (address h, address p, uint256 a, uint256 dl, uint256 dAt, BotHireEscrowV3.EscrowStatus s) = escrow.getEscrow(escrowId);
        assertEq(h, hirer);
        assertEq(p, provider);
        assertEq(a, amount);
        assertEq(dl, block.timestamp + 24 hours);
        assertEq(dAt, 0);
        assertEq(uint256(s), uint256(BotHireEscrowV3.EscrowStatus.Deposited));
        assertEq(usdc.balanceOf(address(escrow)), amount);
    }

    function test_deposit_computeEscrowId_matches() public view {
        assertEq(escrow.computeEscrowId(hirer, ref), escrowId);
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV3.ZeroAmount.selector);
        escrow.deposit(ref, provider, 0);
    }

    function test_deposit_revert_zeroProvider() public {
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV3.ZeroAddress.selector);
        escrow.deposit(ref, address(0), amount);
    }

    function test_deposit_revert_doubleDeposit() public {
        _deposit();
        vm.prank(hirer);
        vm.expectRevert(BotHireEscrowV3.EscrowAlreadyExists.selector);
        escrow.deposit(ref, provider, amount);
    }

    /// @dev Namespacing: an attacker front-running the SAME ref gets a DIFFERENT key, can't brick the hirer.
    function test_deposit_namespaced_noFrontRun() public {
        usdc.mint(attacker, 100_000_000);
        vm.prank(attacker);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(attacker);
        escrow.deposit(ref, provider, amount); // attacker's key = keccak(attacker, ref) — different
        // hirer's deposit under the same ref still succeeds at its own namespaced key
        _deposit();
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV3.EscrowStatus.Deposited));
    }

    // ============================================================
    // release / refund / timeout / dispute — parity
    // ============================================================

    function test_release_happy() public {
        _deposit();
        vm.prank(hirer);
        escrow.release(escrowId);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV3.EscrowStatus.Released));
        assertEq(usdc.balanceOf(provider), amount);
    }

    function test_release_revert_notHirer() public {
        _deposit();
        vm.prank(attacker);
        vm.expectRevert(BotHireEscrowV3.NotHirer.selector);
        escrow.release(escrowId);
    }

    function test_refund_happy() public {
        _deposit();
        uint256 balBefore = usdc.balanceOf(hirer);
        vm.prank(hirer);
        escrow.refund(escrowId);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV3.EscrowStatus.Refunded));
        assertEq(usdc.balanceOf(hirer), balBefore + amount);
    }

    function test_claimRefund_afterTimeout() public {
        _deposit();
        vm.warp(block.timestamp + 24 hours + 1);
        uint256 balBefore = usdc.balanceOf(hirer);
        vm.prank(anyone); // permissionless
        escrow.claimRefund(escrowId);
        assertEq(usdc.balanceOf(hirer), balBefore + amount);
    }

    function test_claimRefund_revert_beforeDeadline() public {
        _deposit();
        vm.prank(anyone);
        vm.expectRevert(BotHireEscrowV3.DeadlineNotReached.selector);
        escrow.claimRefund(escrowId);
    }

    function test_dispute_resolve_toProvider() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        assertEq(uint256(_status(escrowId)), uint256(BotHireEscrowV3.EscrowStatus.Disputed));
        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, true);
        assertEq(usdc.balanceOf(provider), amount);
    }

    function test_dispute_resolve_toHirer() public {
        _deposit();
        uint256 balBefore = usdc.balanceOf(hirer);
        vm.prank(provider);
        escrow.dispute(escrowId);
        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, false);
        assertEq(usdc.balanceOf(hirer), balBefore + amount);
    }

    function test_resolveDispute_revert_notArbiter() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.prank(attacker);
        vm.expectRevert(BotHireEscrowV3.NotArbiter.selector);
        escrow.resolveDispute(escrowId, true);
    }

    function test_claimDisputeTimeout() public {
        _deposit();
        vm.prank(hirer);
        escrow.dispute(escrowId);
        vm.warp(block.timestamp + 7 days + 1);
        uint256 balBefore = usdc.balanceOf(hirer);
        vm.prank(anyone);
        escrow.claimDisputeTimeout(escrowId);
        assertEq(usdc.balanceOf(hirer), balBefore + amount);
    }

    // ============================================================
    // GASLESS deposit via Permit2 — the V3 addition
    // ============================================================

    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant ESCROW_DEPOSIT_WITNESS_TYPEHASH = keccak256("EscrowDeposit(bytes32 ref,address provider)");
    // Full EIP-712 type, written out INDEPENDENTLY of the contract's constant. If the contract's
    // WITNESS_TYPE_STRING disagrees, Permit2 reconstructs a different typeHash → the signature we build
    // here fails to recover the owner → permitWitnessTransferFrom reverts. So a green test proves the
    // contract's witness type string is correct.
    string constant FULL_WITNESS_TYPE =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,EscrowDeposit witness)EscrowDeposit(bytes32 ref,address provider)TokenPermissions(address token,uint256 amount)";

    /// @dev Build a buyer's Permit2 PermitWitnessTransferFrom signature for an EscrowDeposit(ref,provider).
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

    /// @dev The EIP-712 digest a buyer signs, built from the INDEPENDENT full type string (not the
    ///      contract's constant), so a wrong witness string in the contract fails verification.
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

    function _buyerSetup(uint256 pk) internal returns (address buyer) {
        buyer = vm.addr(pk);
        usdc.mint(buyer, 100_000_000);
        vm.prank(buyer);
        usdc.approve(address(permit2), type(uint256).max); // gasless path: buyer approves Permit2, once
    }

    function test_depositWithPermit2_happy() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(usdc), amount, nonce, deadline, ref, provider);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdc), amount: amount}),
            nonce: nonce,
            deadline: deadline
        });

        uint256 buyerBalBefore = usdc.balanceOf(buyer);
        // The RELAYER submits and pays gas — the buyer sent no tx.
        vm.prank(relayer);
        escrow.depositWithPermit2(permit, buyer, ref, provider, sig);

        bytes32 id = escrow.computeEscrowId(buyer, ref);
        (address h, address p, uint256 a, , , BotHireEscrowV3.EscrowStatus s) = escrow.getEscrow(id);
        assertEq(h, buyer, "hirer is the signer, not the relayer");
        assertEq(p, provider);
        assertEq(a, amount);
        assertEq(uint256(s), uint256(BotHireEscrowV3.EscrowStatus.Deposited));
        assertEq(usdc.balanceOf(address(escrow)), amount, "funds pulled into escrow");
        assertEq(usdc.balanceOf(buyer), buyerBalBefore - amount, "pulled from the buyer");
    }

    /// @dev A gasless-deposited escrow releases to the provider exactly like a classic one.
    function test_depositWithPermit2_thenRelease() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(usdc), amount, 0, deadline, ref, provider);
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdc), amount: amount}),
            nonce: 0,
            deadline: deadline
        });
        vm.prank(relayer);
        escrow.depositWithPermit2(permit, buyer, ref, provider, sig);

        bytes32 id = escrow.computeEscrowId(buyer, ref);
        vm.prank(buyer); // the real hirer releases
        escrow.release(id);
        assertEq(usdc.balanceOf(provider), amount);
    }

    /// @dev A relayer that tampers the provider (differs from what the buyer signed) can't succeed:
    ///      the witness no longer matches the signature → Permit2 rejects it.
    function test_depositWithPermit2_revert_relayerTampersProvider() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(usdc), amount, 0, deadline, ref, provider);
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdc), amount: amount}),
            nonce: 0,
            deadline: deadline
        });
        address evilProvider = makeAddr("evilProvider");
        vm.prank(relayer);
        vm.expectRevert(); // Permit2 InvalidSigner (witness mismatch)
        escrow.depositWithPermit2(permit, buyer, ref, evilProvider, sig);
    }

    /// @dev A relayer that inflates the amount can't succeed either (amount is signed into the permit).
    function test_depositWithPermit2_revert_relayerTampersAmount() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(usdc), amount, 0, deadline, ref, provider);
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdc), amount: amount * 2}),
            nonce: 0,
            deadline: deadline
        });
        vm.prank(relayer);
        vm.expectRevert(); // Permit2 InvalidSigner (permitted.amount differs from signed)
        escrow.depositWithPermit2(permit, buyer, ref, provider, sig);
    }

    /// @dev Token that isn't this escrow's token is refused before touching Permit2.
    function test_depositWithPermit2_revert_wrongToken() public {
        uint256 buyerPk = 0xB0B;
        _buyerSetup(buyerPk);
        Mock18 other = new Mock18();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(other), amount, 0, deadline, ref, provider);
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(other), amount: amount}),
            nonce: 0,
            deadline: deadline
        });
        vm.prank(relayer);
        vm.expectRevert(BotHireEscrowV3.TokenMismatch.selector);
        escrow.depositWithPermit2(permit, vm.addr(buyerPk), ref, provider, sig);
    }

    /// @dev The same signed permit can't be replayed (Permit2 nonce is single-use); and the same
    ///      (buyer,ref) can't be re-deposited (EscrowAlreadyExists).
    function test_depositWithPermit2_revert_replaySameEscrow() public {
        uint256 buyerPk = 0xB0B;
        address buyer = _buyerSetup(buyerPk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signDeposit(buyerPk, address(usdc), amount, 0, deadline, ref, provider);
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdc), amount: amount}),
            nonce: 0,
            deadline: deadline
        });
        vm.prank(relayer);
        escrow.depositWithPermit2(permit, buyer, ref, provider, sig);
        // replay the identical call → EscrowAlreadyExists (hit before Permit2 even runs)
        vm.prank(relayer);
        vm.expectRevert(BotHireEscrowV3.EscrowAlreadyExists.selector);
        escrow.depositWithPermit2(permit, buyer, ref, provider, sig);
    }
}
