// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BotHireEscrowV2
 * @notice Fixed-price escrow for BotHire, with an on-chain dispute → arbiter path.
 *
 * The hirer deposits the exact price. They release it to the provider on delivery,
 * or refund themselves (voluntary cancel), or — if the provider never delivers —
 * anyone may `claimRefund` after the 24h deadline. Either party may `dispute()`
 * while Deposited, which freezes the funds and routes to the platform `arbiter`,
 * who rules all-or-nothing (pay the provider, or refund the hirer). A dispute the
 * arbiter never resolves fully refunds the hirer after DISPUTE_TIMEOUT.
 *
 * This is the V2 successor to the fixed-price `BotHireEscrow` (V1): it adds the
 * dispute/arbiter path and the `disputedAt` field the server has always expected,
 * and namespaces the escrow id by the depositor to close V1's front-run-squat grief.
 * The token is decimal-agnostic (raw integer amounts move; no rounding, no fee), so
 * the same contract serves 6-decimal USDC on Base and 18-decimal USDT/USDC on BNB —
 * one deployment per (chain, token).
 *
 * @dev TRUST MODEL — read before audit:
 *  - Funds only ever move to the escrow's own `hirer` or `provider`; the arbiter
 *    chooses WHICH of the two, never an arbitrary address, and never an amount
 *    other than the full deposited `amount`.
 *  - `release` / `refund` are hirer-only; `claimRefund` / `claimDisputeTimeout` are
 *    permissionless but only ever refund the recorded hirer after a real deadline;
 *    `resolveDispute` is arbiter-only and only reachable from Disputed.
 *  - Escrow keys are namespaced: the on-chain key is keccak256(abi.encode(msg.sender,
 *    ref)), so no one can front-run a victim's `ref` in the mempool and brick it.
 *    Use `computeEscrowId(hirer, ref)` to derive the key the other methods take.
 *  - No owner-drain: `owner` may only rotate the `arbiter` and transfer ownership;
 *    it can never move escrowed funds. There is no pause and no protocol fee.
 */
contract BotHireEscrowV2 is ReentrancyGuard {
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

    /// @notice Auto-refund window: if never released, the hirer can be refunded after this.
    uint256 public constant TIMEOUT = 24 hours;

    /// @notice If a dispute is never resolved by the arbiter, the hirer can be refunded after this.
    uint256 public constant DISPUTE_TIMEOUT = 7 days;

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

    // ========== Constructor ==========

    /**
     * @param _token   The ERC-20 to escrow (Base USDC 0x8335…2913, or a BNB stablecoin).
     * @param _arbiter Platform arbiter key (resolves disputes).
     */
    constructor(address _token, address _arbiter) {
        if (_token == address(0) || _arbiter == address(0)) revert ZeroAddress();
        token = IERC20(_token);
        owner = msg.sender;
        arbiter = _arbiter;
        emit OwnershipTransferred(address(0), msg.sender);
        emit ArbiterUpdated(address(0), _arbiter);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ========== Hirer: deposit ==========

    /**
     * @notice Hirer deposits the fixed price into escrow.
     * @dev The effective escrow key is keccak256(abi.encode(msg.sender, ref)), NOT `ref`
     *      itself — this namespaces every escrow by its depositor so an attacker cannot
     *      front-run a victim's `ref` and permanently squat/brick it. All other functions
     *      and `getEscrow` take that computed key; derive it with `computeEscrowId`.
     * @param ref      Caller-chosen reference (e.g. keccak256(hireId)); the on-chain key is derived from it + msg.sender.
     * @param provider Provider wallet address.
     * @param amount   The price to escrow (raw token units).
     */
    function deposit(bytes32 ref, address provider, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (provider == address(0)) revert ZeroAddress();

        bytes32 escrowId = keccak256(abi.encode(msg.sender, ref));
        if (escrows[escrowId].status != EscrowStatus.Empty) revert EscrowAlreadyExists();

        uint256 dl = block.timestamp + TIMEOUT;
        escrows[escrowId] = Escrow({
            hirer: msg.sender,
            provider: provider,
            amount: amount,
            deadline: dl,
            disputedAt: 0,
            status: EscrowStatus.Deposited
        });

        token.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(escrowId, msg.sender, provider, amount, dl);
    }

    /// @notice The effective escrow key that `deposit(ref)` from `hirer` maps to.
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
