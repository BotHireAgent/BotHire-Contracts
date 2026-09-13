// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISignatureTransfer} from "./IPermit2.sol";

/**
 * @title BotHireEscrowV3
 * @notice Fixed-price escrow for BotHire — identical trust model + methods to V2, plus ONE new entrypoint,
 *         `depositWithPermit2`, that lets a relayer fund the escrow from the BUYER's Permit2 signature so the
 *         buyer pays NO gas. Everything else (release/refund/dispute/arbiter/timeout, storage layout, the
 *         namespaced escrow key, events) is byte-for-byte V2.
 *
 * @dev GASLESS DEPOSIT — read before audit:
 *  - `depositWithPermit2` is permissionless (the relayer calls it and pays gas), but it moves only the
 *    BUYER's own tokens, and only into THIS contract: Permit2 verifies the buyer's signature binds
 *    token/amount/spender(=this contract)/nonce/deadline AND the witness `EscrowDeposit(ref, provider)`.
 *    A relayer therefore cannot change the amount, the provider, the ref, or redirect funds — it can only
 *    broadcast the exact deposit the buyer signed. Same "self-settle, non-custodial" model as the direct
 *    x402 rail; the funds never touch the relayer.
 *  - The escrow is keyed by keccak256(abi.encode(hirer, ref)) where `hirer` is the Permit2 `owner` (the
 *    signature signer, which Permit2 checks) — NOT msg.sender (the relayer). So the depositor-namespacing /
 *    front-run-squat defense and the server's computeEscrowId(hirer, ref) derivation are unchanged.
 *  - The escrow's recorded `amount` is the SIGNED `permit.permitted.amount`, and the full amount is pulled
 *    (`requestedAmount == permitted.amount`), so the on-chain record can never disagree with what moved.
 *
 * @dev V2 trust model (unchanged): funds only ever move to the escrow's own `hirer` or `provider`; the
 *      arbiter chooses which, never an arbitrary address or partial amount; owner can only rotate the
 *      arbiter / transfer ownership and can never move funds; no pause, no protocol fee.
 */
contract BotHireEscrowV3 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== State ==========

    enum EscrowStatus {
        Empty,     // 0 - does not exist
        Deposited, // 1 - hirer has deposited, awaiting release/refund/dispute
        Released,  // 2 - released to provider
        Refunded,  // 3 - refunded to hirer
        Disputed   // 4 - frozen, awaiting arbiter ruling
    }

    struct Escrow {
        address hirer;
        address provider;
        uint256 amount;
        uint256 deadline;    // deposit time + TIMEOUT
        uint256 disputedAt;  // timestamp a dispute was opened (0 if never)
        EscrowStatus status;
    }

    /// @notice The ERC-20 held in escrow (immutable; e.g. Base USDC, or BNB USDT/USDC).
    IERC20 public immutable token;

    /// @notice Canonical Permit2 used for gasless deposits. Immutable; the same address on every chain.
    ISignatureTransfer public immutable PERMIT2;

    /// @notice Auto-refund window: if never released, the hirer can be refunded after this.
    uint256 public constant TIMEOUT = 24 hours;

    /// @notice If a dispute is never resolved by the arbiter, the hirer can be refunded after this.
    uint256 public constant DISPUTE_TIMEOUT = 7 days;

    /// @notice EIP-712 type hash of the deposit witness the buyer signs (binds ref + provider).
    bytes32 public constant ESCROW_DEPOSIT_WITNESS_TYPEHASH =
        keccak256("EscrowDeposit(bytes32 ref,address provider)");

    /// @notice The Permit2 witnessTypeString for `permitWitnessTransferFrom`: closes the outer struct with
    ///         `EscrowDeposit witness)` then appends the referenced type defs in EIP-712 alphabetical order
    ///         (EscrowDeposit < TokenPermissions). The client MUST sign the matching typed data.
    string public constant WITNESS_TYPE_STRING =
        "EscrowDeposit witness)EscrowDeposit(bytes32 ref,address provider)TokenPermissions(address token,uint256 amount)";

    /// @notice Contract admin: may rotate the arbiter key and transfer ownership. Cannot move funds.
    address public owner;

    /// @notice Platform key permitted to resolve disputes (pay provider or refund hirer).
    address public arbiter;

    /// @notice escrowId => Escrow
    mapping(bytes32 => Escrow) public escrows;

    // ========== Events ==========

    event Deposited(bytes32 indexed escrowId, address indexed hirer, address indexed provider, uint256 amount, uint256 deadline);
    event Released(bytes32 indexed escrowId, address indexed provider, uint256 amount);
    event Refunded(bytes32 indexed escrowId, address indexed hirer, uint256 amount);
    event Disputed(bytes32 indexed escrowId, address indexed by);
    event ArbiterUpdated(address indexed previous, address indexed current);
    event OwnershipTransferred(address indexed previous, address indexed current);

    // ========== Errors ==========

    error EscrowAlreadyExists();
    error EscrowNotFound();
    error NotHirer();
    error NotParty();
    error NotArbiter();
    error NotOwner();
    error NotDeposited();
    error NotDisputed();
    error DeadlineNotReached();
    error DisputeWindowNotElapsed();
    error ZeroAmount();
    error ZeroAddress();
    error TokenMismatch();

    // ========== Constructor ==========

    /**
     * @param _token   The ERC-20 to escrow (Base USDC 0x8335…2913, or a chain stablecoin).
     * @param _arbiter Platform arbiter key (resolves disputes).
     * @param _permit2 Canonical Permit2 (0x0000…78BA3). A constructor param (not a literal) so tests can
     *                 inject a mock; deploy scripts pass the canonical address.
     */
    constructor(address _token, address _arbiter, address _permit2) {
        if (_token == address(0) || _arbiter == address(0) || _permit2 == address(0)) revert ZeroAddress();
        token = IERC20(_token);
        arbiter = _arbiter;
        PERMIT2 = ISignatureTransfer(_permit2);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        emit ArbiterUpdated(address(0), _arbiter);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ========== Hirer: deposit ==========

    /**
     * @notice Hirer deposits the fixed price into escrow (pays their own gas). Unchanged from V2.
     * @param ref      Caller-chosen reference (e.g. keccak256(hireId)); the on-chain key is derived from it + msg.sender.
     * @param provider Provider wallet address.
     * @param amount   The price to escrow (raw token units).
     */
    function deposit(bytes32 ref, address provider, uint256 amount) external nonReentrant {
        bytes32 escrowId = _recordDeposit(msg.sender, ref, provider, amount);
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(escrowId, msg.sender, provider, amount, escrows[escrowId].deadline);
    }

    /**
     * @notice GASLESS deposit: a relayer funds the escrow from the buyer's Permit2 signature. The buyer
     *         pays no gas; the relayer (msg.sender) pays it. Non-custodial — Permit2 pulls the buyer's
     *         tokens straight into this contract, and the witness binds the deal so the relayer can't cheat.
     * @param permit    The buyer-signed Permit2 PermitTransferFrom (permitted.token/amount, nonce, deadline).
     * @param hirer     The buyer — MUST equal the Permit2 signature signer (Permit2 enforces owner == signer).
     * @param ref       Caller-chosen reference (e.g. keccak256(hireId)); on-chain key = keccak256(hirer, ref).
     * @param provider  Provider wallet address (bound in the witness).
     * @param signature The buyer's EIP-712 signature over PermitWitnessTransferFrom + EscrowDeposit(ref,provider).
     */
    function depositWithPermit2(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        address hirer,
        bytes32 ref,
        address provider,
        bytes calldata signature
    ) external nonReentrant {
        // The escrow amount IS the signed permitted.amount; the full amount is pulled below so the recorded
        // amount can never disagree with what actually moved. token must match this escrow's token.
        uint256 amount = permit.permitted.amount;
        if (permit.permitted.token != address(token)) revert TokenMismatch();

        bytes32 escrowId = _recordDeposit(hirer, ref, provider, amount);

        bytes32 witness = keccak256(abi.encode(ESCROW_DEPOSIT_WITNESS_TYPEHASH, ref, provider));
        PERMIT2.permitWitnessTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
            hirer,          // Permit2 recovers the signer and reverts unless it == hirer
            witness,
            WITNESS_TYPE_STRING,
            signature
        );

        emit Deposited(escrowId, hirer, provider, amount, escrows[escrowId].deadline);
    }

    /**
     * @dev Shared record-keeping for both deposit paths: validates, reserves the namespaced escrow key,
     *      and stores the Deposited escrow. Does NOT move tokens (each caller pulls its own way). Returns
     *      the escrowId. Reverts if the key is already used (front-run-squat safe: keyed by the hirer).
     */
    function _recordDeposit(address hirer, bytes32 ref, address provider, uint256 amount)
        internal
        returns (bytes32 escrowId)
    {
        if (amount == 0) revert ZeroAmount();
        if (provider == address(0)) revert ZeroAddress();

        escrowId = keccak256(abi.encode(hirer, ref));
        if (escrows[escrowId].status != EscrowStatus.Empty) revert EscrowAlreadyExists();

        escrows[escrowId] = Escrow({
            hirer: hirer,
            provider: provider,
            amount: amount,
            deadline: block.timestamp + TIMEOUT,
            disputedAt: 0,
            status: EscrowStatus.Deposited
        });
    }

    /// @notice The effective escrow key that a deposit for `hirer` + `ref` maps to.
    function computeEscrowId(address hirer, bytes32 ref) external pure returns (bytes32) {
        return keccak256(abi.encode(hirer, ref));
    }

    // ========== Hirer: release / refund ==========

    /// @notice Hirer releases the funds to the provider (task completed).
    function release(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Deposited) revert NotDeposited();
        if (msg.sender != e.hirer) revert NotHirer();

        e.status = EscrowStatus.Released;
        token.safeTransfer(e.provider, e.amount);
        emit Released(escrowId, e.provider, e.amount);
    }

    /// @notice Hirer voluntarily refunds themselves (cancel before delivery).
    function refund(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Deposited) revert NotDeposited();
        if (msg.sender != e.hirer) revert NotHirer();

        e.status = EscrowStatus.Refunded;
        token.safeTransfer(e.hirer, e.amount);
        emit Refunded(escrowId, e.hirer, e.amount);
    }

    // ========== Timeout: refund hirer if never released ==========

    /// @notice After TIMEOUT with no release, anyone may refund the hirer in full.
    function claimRefund(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Deposited) revert NotDeposited();
        if (block.timestamp < e.deadline) revert DeadlineNotReached();

        e.status = EscrowStatus.Refunded;
        uint256 amt = e.amount;
        token.safeTransfer(e.hirer, amt);
        emit Refunded(escrowId, e.hirer, amt);
    }

    // ========== Dispute path ==========

    /// @notice Either party freezes the escrow pending arbiter resolution.
    function dispute(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Deposited) revert NotDeposited();
        if (msg.sender != e.hirer && msg.sender != e.provider) revert NotParty();

        e.status = EscrowStatus.Disputed;
        e.disputedAt = block.timestamp;
        emit Disputed(escrowId, msg.sender);
    }

    /**
     * @notice Arbiter resolves a dispute all-or-nothing.
     * @param toProvider true → pay the full amount to the provider; false → refund the hirer.
     */
    function resolveDispute(bytes32 escrowId, bool toProvider) external nonReentrant {
        if (msg.sender != arbiter) revert NotArbiter();

        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Disputed) revert NotDisputed();

        uint256 amt = e.amount;
        if (toProvider) {
            e.status = EscrowStatus.Released;
            token.safeTransfer(e.provider, amt);
            emit Released(escrowId, e.provider, amt);
        } else {
            e.status = EscrowStatus.Refunded;
            token.safeTransfer(e.hirer, amt);
            emit Refunded(escrowId, e.hirer, amt);
        }
    }

    /// @notice If the arbiter never resolves a dispute, anyone may refund the hirer after DISPUTE_TIMEOUT.
    function claimDisputeTimeout(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Disputed) revert NotDisputed();
        if (block.timestamp < e.disputedAt + DISPUTE_TIMEOUT) revert DisputeWindowNotElapsed();

        e.status = EscrowStatus.Refunded;
        uint256 amt = e.amount;
        token.safeTransfer(e.hirer, amt);
        emit Refunded(escrowId, e.hirer, amt);
    }

    // ========== Admin (no fund access) ==========

    function setArbiter(address _arbiter) external onlyOwner {
        if (_arbiter == address(0)) revert ZeroAddress();
        emit ArbiterUpdated(arbiter, _arbiter);
        arbiter = _arbiter;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ========== View ==========

    /// @notice Query the escrow state (6 fields; `disputedAt` before `status`, matching the server ABI).
    function getEscrow(bytes32 escrowId) external view returns (
        address hirer,
        address provider,
        uint256 amount,
        uint256 deadline,
        uint256 disputedAt,
        EscrowStatus status
    ) {
        Escrow storage e = escrows[escrowId];
        return (e.hirer, e.provider, e.amount, e.deadline, e.disputedAt, e.status);
    }
}
