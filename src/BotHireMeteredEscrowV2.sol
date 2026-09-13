// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISignatureTransfer} from "./IPermit2.sol";

/**
 * @title BotHireMeteredEscrowV2
 * @notice Usage-metered escrow for BotHire — identical trust model + methods to BotHireMeteredEscrow,
 *         plus ONE new entrypoint, `depositWithPermit2`, that lets a relayer lock the buyer's MAX budget
 *         from the buyer's Permit2 signature so the buyer pays NO gas. Everything else (settle / dispute /
 *         arbiter / timeout, storage layout, the namespaced escrow key, events) is byte-for-byte V1.
 *
 * @dev GASLESS DEPOSIT — read before audit (same reasoning as BotHireEscrowV3.depositWithPermit2):
 *  - `depositWithPermit2` is permissionless (the relayer pays gas), but moves only the BUYER's own tokens,
 *    and only into THIS contract: Permit2 verifies the buyer's signature binds token/amount(=maxAmount)/
 *    spender(=this)/nonce/deadline AND the witness `EscrowDeposit(ref, provider)`. The relayer cannot
 *    change the budget, provider, ref, or redirect funds — only broadcast the exact deposit the buyer signed.
 *  - The escrow is keyed by keccak256(abi.encode(hirer, ref)) where `hirer` is the Permit2 `owner` (the
 *    signer Permit2 checks) — NOT msg.sender (the relayer). Namespacing / front-run defense unchanged.
 *  - The locked `maxAmount` is the SIGNED `permit.permitted.amount`, and the full amount is pulled, so the
 *    on-chain record can never disagree with what moved.
 *  - The gasless deposit changes only HOW the budget is funded; settle/dispute/timeout are untouched, so
 *    the hirer's on-chain exposure is still bounded by the maxAmount THEY signed.
 */
contract BotHireMeteredEscrowV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== State ==========

    enum EscrowStatus {
        Empty,     // 0 - does not exist
        Deposited, // 1 - hirer locked maxAmount, awaiting settlement
        Settled,   // 2 - provider paid actual, hirer refunded remainder
        Refunded,  // 3 - hirer refunded in full (timeout / abandoned dispute)
        Disputed   // 4 - frozen, awaiting arbiter ruling
    }

    struct Escrow {
        address hirer;
        address provider;
        uint256 maxAmount;   // authorized budget = upper bound on the provider payout
        uint256 deadline;    // deposit time + TIMEOUT
        uint256 disputedAt;  // timestamp a dispute was opened (0 if never)
        EscrowStatus status;
    }

    /// @notice The ERC-20 held in escrow (immutable; decimal-agnostic).
    IERC20 public immutable usdc;

    /// @notice Canonical Permit2 used for gasless deposits. Immutable; the same address on every chain.
    ISignatureTransfer public immutable PERMIT2;

    /// @notice Auto-refund window: if never settled, the hirer can be refunded after this.
    uint256 public constant TIMEOUT = 24 hours;

    /// @notice If a dispute is never resolved by the arbiter, the hirer can be refunded after this.
    uint256 public constant DISPUTE_TIMEOUT = 7 days;

    /// @notice EIP-712 type hash of the deposit witness the buyer signs (binds ref + provider). Same shape
    ///         as BotHireEscrowV3 so a client can build one witness for either escrow kind.
    bytes32 public constant ESCROW_DEPOSIT_WITNESS_TYPEHASH =
        keccak256("EscrowDeposit(bytes32 ref,address provider)");

    /// @notice The Permit2 witnessTypeString: closes the outer struct then appends referenced type defs in
    ///         EIP-712 alphabetical order (EscrowDeposit < TokenPermissions). The client MUST sign the match.
    string public constant WITNESS_TYPE_STRING =
        "EscrowDeposit witness)EscrowDeposit(bytes32 ref,address provider)TokenPermissions(address token,uint256 amount)";

    /// @notice Contract admin: may rotate the settler / arbiter keys and transfer ownership.
    address public owner;

    /// @notice Platform key permitted to settle actual usage (<= maxAmount).
    address public settler;

    /// @notice Platform key permitted to resolve disputes with a split.
    address public arbiter;

    /// @notice escrowId => Escrow
    mapping(bytes32 => Escrow) public escrows;

    // ========== Events ==========

    event Deposited(bytes32 indexed escrowId, address indexed hirer, address indexed provider, uint256 maxAmount, uint256 deadline);
    event Settled(bytes32 indexed escrowId, address indexed provider, uint256 providerAmount, uint256 refundAmount);
    event Refunded(bytes32 indexed escrowId, address indexed hirer, uint256 amount);
    event Disputed(bytes32 indexed escrowId, address indexed by);
    event SettlerUpdated(address indexed previous, address indexed current);
    event ArbiterUpdated(address indexed previous, address indexed current);
    event OwnershipTransferred(address indexed previous, address indexed current);

    // ========== Errors ==========

    error EscrowAlreadyExists();
    error EscrowNotFound();
    error NotParty();
    error NotDeposited();
    error NotDisputed();
    error NotSettler();
    error NotArbiter();
    error NotOwner();
    error DeadlineNotReached();
    error DisputeWindowNotElapsed();
    error AmountExceedsBudget();
    error ZeroAmount();
    error ZeroAddress();
    error TokenMismatch();

    // ========== Constructor ==========

    /**
     * @param _usdc    The ERC-20 to escrow (Base USDC 0x8335…2913, or a chain stablecoin).
     * @param _settler Platform settler key (settles actual usage).
     * @param _arbiter Platform arbiter key (resolves disputes).
     * @param _permit2 Canonical Permit2 (0x0000…78BA3). Constructor param (not a literal) for testability.
     */
    constructor(address _usdc, address _settler, address _arbiter, address _permit2) {
        if (_usdc == address(0) || _settler == address(0) || _arbiter == address(0) || _permit2 == address(0)) {
            revert ZeroAddress();
        }
        usdc = IERC20(_usdc);
        settler = _settler;
        arbiter = _arbiter;
        PERMIT2 = ISignatureTransfer(_permit2);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        emit SettlerUpdated(address(0), _settler);
        emit ArbiterUpdated(address(0), _arbiter);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ========== Hirer: deposit (authorize max budget) ==========

    /**
     * @notice Hirer locks up to `maxAmount` as the metered budget (pays their own gas). Unchanged from V1.
     * @param ref Caller-chosen reference (e.g. keccak256(hireId)); on-chain key = keccak256(msg.sender, ref).
     * @param provider Provider wallet address.
     * @param maxAmount Maximum the provider may be paid (raw token units).
     */
    function deposit(bytes32 ref, address provider, uint256 maxAmount) external nonReentrant {
        bytes32 escrowId = _recordDeposit(msg.sender, ref, provider, maxAmount);
        usdc.safeTransferFrom(msg.sender, address(this), maxAmount);
        emit Deposited(escrowId, msg.sender, provider, maxAmount, escrows[escrowId].deadline);
    }

    /**
     * @notice GASLESS deposit: a relayer locks the buyer's MAX budget from the buyer's Permit2 signature.
     *         The buyer pays no gas; the relayer (msg.sender) pays it. Non-custodial — Permit2 pulls the
     *         buyer's tokens straight into this contract, and the witness binds the deal.
     * @param permit    The buyer-signed Permit2 PermitTransferFrom (permitted.token/amount=maxAmount, nonce, deadline).
     * @param hirer     The buyer — MUST equal the Permit2 signature signer (Permit2 enforces owner == signer).
     * @param ref       Caller-chosen reference; on-chain key = keccak256(hirer, ref).
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
        uint256 maxAmount = permit.permitted.amount;
        if (permit.permitted.token != address(usdc)) revert TokenMismatch();

        bytes32 escrowId = _recordDeposit(hirer, ref, provider, maxAmount);

        bytes32 witness = keccak256(abi.encode(ESCROW_DEPOSIT_WITNESS_TYPEHASH, ref, provider));
        PERMIT2.permitWitnessTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: maxAmount}),
            hirer,
            witness,
            WITNESS_TYPE_STRING,
            signature
        );

        emit Deposited(escrowId, hirer, provider, maxAmount, escrows[escrowId].deadline);
    }

    /**
     * @dev Shared record-keeping for both deposit paths: validates, reserves the namespaced key, stores the
     *      Deposited escrow. Does NOT move tokens (each caller pulls its own way). Returns the escrowId.
     */
    function _recordDeposit(address hirer, bytes32 ref, address provider, uint256 maxAmount)
        internal
        returns (bytes32 escrowId)
    {
        if (maxAmount == 0) revert ZeroAmount();
        if (provider == address(0)) revert ZeroAddress();

        escrowId = keccak256(abi.encode(hirer, ref));
        if (escrows[escrowId].status != EscrowStatus.Empty) revert EscrowAlreadyExists();

        escrows[escrowId] = Escrow({
            hirer: hirer,
            provider: provider,
            maxAmount: maxAmount,
            deadline: block.timestamp + TIMEOUT,
            disputedAt: 0,
            status: EscrowStatus.Deposited
        });
    }

    /// @notice The effective escrow key that a deposit for `hirer` + `ref` maps to.
    function computeEscrowId(address hirer, bytes32 ref) external pure returns (bytes32) {
        return keccak256(abi.encode(hirer, ref));
    }

    // ========== Settler: settle actual metered usage ==========

    /**
     * @notice Settle actual usage: pay `actualAmount` to the provider and refund `maxAmount - actualAmount`
     *         to the hirer, atomically.
     */
    function settle(bytes32 escrowId, uint256 actualAmount) external nonReentrant {
        if (msg.sender != settler) revert NotSettler();

        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Deposited) revert NotDeposited();
        if (actualAmount > e.maxAmount) revert AmountExceedsBudget();

        uint256 refundAmount = e.maxAmount - actualAmount;
        address provider = e.provider;
        address hirer = e.hirer;

        e.status = EscrowStatus.Settled;

        if (actualAmount > 0) usdc.safeTransfer(provider, actualAmount);
        if (refundAmount > 0) usdc.safeTransfer(hirer, refundAmount);

        emit Settled(escrowId, provider, actualAmount, refundAmount);
    }

    // ========== Timeout: refund hirer if never settled ==========

    /// @notice After TIMEOUT with no settlement, anyone may refund the hirer in full.
    function claimRefund(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Deposited) revert NotDeposited();
        if (block.timestamp < e.deadline) revert DeadlineNotReached();

        e.status = EscrowStatus.Refunded;
        uint256 amt = e.maxAmount;

        usdc.safeTransfer(e.hirer, amt);

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
     * @notice Arbiter resolves a dispute with an explicit split: pay `providerAmount` to the provider,
     *         refund the remainder to the hirer.
     */
    function resolveDispute(bytes32 escrowId, uint256 providerAmount) external nonReentrant {
        if (msg.sender != arbiter) revert NotArbiter();

        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Disputed) revert NotDisputed();
        if (providerAmount > e.maxAmount) revert AmountExceedsBudget();

        uint256 refundAmount = e.maxAmount - providerAmount;
        address provider = e.provider;
        address hirer = e.hirer;

        e.status = EscrowStatus.Settled;

        if (providerAmount > 0) usdc.safeTransfer(provider, providerAmount);
        if (refundAmount > 0) usdc.safeTransfer(hirer, refundAmount);

        emit Settled(escrowId, provider, providerAmount, refundAmount);
    }

    /// @notice If the arbiter never resolves a dispute, anyone may refund the hirer in full after DISPUTE_TIMEOUT.
    function claimDisputeTimeout(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Disputed) revert NotDisputed();
        if (block.timestamp < e.disputedAt + DISPUTE_TIMEOUT) revert DisputeWindowNotElapsed();

        e.status = EscrowStatus.Refunded;
        uint256 amt = e.maxAmount;

        usdc.safeTransfer(e.hirer, amt);

        emit Refunded(escrowId, e.hirer, amt);
    }

    // ========== Admin ==========

    function setSettler(address _settler) external onlyOwner {
        if (_settler == address(0)) revert ZeroAddress();
        emit SettlerUpdated(settler, _settler);
        settler = _settler;
    }

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

    // ========== View methods ==========

    /// @notice Query the escrow state (maxAmount in the `amount` slot, matching the V1 reader ABI).
    function getEscrow(bytes32 escrowId) external view returns (
        address hirer,
        address provider,
        uint256 maxAmount,
        uint256 deadline,
        uint256 disputedAt,
        EscrowStatus status
    ) {
        Escrow storage e = escrows[escrowId];
        return (e.hirer, e.provider, e.maxAmount, e.deadline, e.disputedAt, e.status);
    }
}
