// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BotHireMeteredEscrow
 * @notice Usage-metered escrow for BotHire — USDC on Base.
 *
 * The hirer authorizes a MAX budget up front; after the provider delivers and
 * reports its metered usage, the platform `settler` settles the ACTUAL amount
 * (<= max) to the provider and refunds the unused remainder to the hirer in the
 * SAME transaction. This is the "authorize-max / settle-actual" model that
 * per-token LLM inference, per-second compute, and per-result search billing
 * require — where the real cost is only known AFTER the work runs.
 *
 * This is a STANDALONE contract, deployed alongside (never replacing) the fixed
 * price `BotHireEscrow`. Fixed-price hires keep using the old contract.
 *
 * @dev TRUST MODEL — read before audit:
 *  - The hirer's exposure is bounded ON-CHAIN by the `maxAmount` THEY chose at
 *    deposit time. The settler can never move more than that to the provider.
 *  - Within [0, maxAmount], the `settler` (a BotHire-operated key) sets the
 *    final settled amount from the provider's reported usage. This is a
 *    trusted-operator determination — the same trust class as the `arbiter`
 *    role on the standard escrow — and is inherent to usage-metered billing.
 *  - Either party may `dispute()` while the escrow is Deposited, which freezes
 *    settlement and routes to the `arbiter`, who splits funds fairly.
 *  - There is deliberately NO buyer-initiated instant refund: because settle()
 *    is settler-called and gated on the Deposited state, a buyer-callable
 *    refund would let a malicious buyer front-run the settler and stiff a
 *    provider that already delivered. The buyer's exits are (a) settle()'s
 *    automatic remainder refund, (b) `claimRefund` after TIMEOUT, or
 *    (c) `dispute` -> arbiter.
 *  - Liveness backstops: never-settled escrows fully refund the hirer after
 *    TIMEOUT; a dispute abandoned by the arbiter fully refunds the hirer after
 *    DISPUTE_TIMEOUT. NOTE: both timeout paths refund the HIRER in full — a
 *    dispute buys time for the arbiter to rule, it is NOT a guaranteed provider
 *    payout. A provider that delivered relies on a live, honest settler/arbiter;
 *    disputing before TIMEOUT only prevents the auto-refund from firing, it does
 *    not by itself pay the provider.
 *  - Escrow keys are namespaced by the depositor: the on-chain key is
 *    keccak256(abi.encode(msg.sender, ref)), so no one can front-run and squat a
 *    victim's reference id (see `deposit`). Use `computeEscrowId` to derive it.
 *  - USDC is 6-decimal integer math — no rounding. No protocol fee.
 */
contract BotHireMeteredEscrow is ReentrancyGuard {
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

    /// @notice USDC token contract (immutable)
    IERC20 public immutable usdc;

    /// @notice Auto-refund window: if never settled, the hirer can be refunded after this.
    uint256 public constant TIMEOUT = 24 hours;

    /// @notice If a dispute is never resolved by the arbiter, the hirer can be refunded after this.
    uint256 public constant DISPUTE_TIMEOUT = 7 days;

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

    // ========== Constructor ==========

    /**
     * @param _usdc    Base chain USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
     * @param _settler Platform settler key (settles actual usage)
     * @param _arbiter Platform arbiter key (resolves disputes)
     */
    constructor(address _usdc, address _settler, address _arbiter) {
        if (_usdc == address(0) || _settler == address(0) || _arbiter == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        owner = msg.sender;
        settler = _settler;
        arbiter = _arbiter;
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
     * @notice Hirer locks up to `maxAmount` USDC as the metered budget.
     * @dev The effective escrow key is `keccak256(abi.encode(msg.sender, ref))`, NOT `ref`
     *      itself — this namespaces every escrow by its depositor so an attacker cannot
     *      front-run a victim's `ref` in the mempool and permanently squat/brick it. All
     *      other functions and `getEscrow` take that computed key; use `computeEscrowId`.
     * @param ref Caller-chosen reference (e.g. keccak256(hireId)); the on-chain key is derived from it + msg.sender
     * @param provider Provider wallet address
     * @param maxAmount Maximum USDC the provider may be paid (6 decimals)
     */
    function deposit(bytes32 ref, address provider, uint256 maxAmount) external nonReentrant {
        if (maxAmount == 0) revert ZeroAmount();
        if (provider == address(0)) revert ZeroAddress();

        bytes32 escrowId = keccak256(abi.encode(msg.sender, ref));
        if (escrows[escrowId].status != EscrowStatus.Empty) revert EscrowAlreadyExists();

        uint256 dl = block.timestamp + TIMEOUT;
        escrows[escrowId] = Escrow({
            hirer: msg.sender,
            provider: provider,
            maxAmount: maxAmount,
            deadline: dl,
            disputedAt: 0,
            status: EscrowStatus.Deposited
        });

        usdc.safeTransferFrom(msg.sender, address(this), maxAmount);

        emit Deposited(escrowId, msg.sender, provider, maxAmount, dl);
    }

    /// @notice The effective escrow key that `deposit(ref)` from `hirer` maps to.
    function computeEscrowId(address hirer, bytes32 ref) external pure returns (bytes32) {
        return keccak256(abi.encode(hirer, ref));
    }

    // ========== Settler: settle actual metered usage ==========

    /**
     * @notice Settle the actual usage: pay `actualAmount` to the provider and
     *         refund `maxAmount - actualAmount` to the hirer, atomically.
     * @param escrowId Escrow identifier
     * @param actualAmount Actual metered cost (must be <= maxAmount)
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

    /**
     * @notice After TIMEOUT with no settlement, anyone may refund the hirer in full.
     * @param escrowId Escrow identifier
     */
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

    /**
     * @notice Either party freezes the escrow pending arbiter resolution.
     * @param escrowId Escrow identifier
     */
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
     * @notice Arbiter resolves a dispute with an explicit split: pay
     *         `providerAmount` to the provider, refund the remainder to the hirer.
     * @param escrowId Escrow identifier
     * @param providerAmount USDC to the provider (must be <= maxAmount)
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

    /**
     * @notice If the arbiter never resolves a dispute, anyone may refund the
     *         hirer in full after DISPUTE_TIMEOUT.
     * @param escrowId Escrow identifier
     */
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

    /**
     * @notice Query the escrow state. Field order mirrors BotHireEscrow (V2) with
     *         `maxAmount` in the `amount` slot so existing readers stay compatible.
     */
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
