// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal read surface shared by BotHireEscrowV2/V3 (fixed) and BotHireMeteredEscrow/V2 (metered).
///      The `EscrowStatus` enum is ABI-encoded as uint8.
interface IBotHireEscrowView {
    function getEscrow(bytes32 escrowId)
        external
        view
        returns (address hirer, address provider, uint256 amount, uint256 deadline, uint256 disputedAt, uint8 status);
}

/**
 * @title BotHireReviews
 * @notice Ownerless, on-chain review / reputation registry for BotHire, gated by real completed escrows.
 *
 * Trust model
 * -----------
 *  - OWNERLESS: no owner, no admin, no upgrade, no pause. Holds no funds (nothing is payable, no receive()).
 *  - The escrow allowlist is fixed at construction and can never change. Only those BotHire escrow contracts
 *    are consulted; a review is accepted only when the allowlisted escrow itself reports the escrow as
 *    COMPLETED (status 2 = Released for fixed-price, Settled for metered). On fixed-price escrows that means
 *    the provider was paid in full. On metered escrows Settled also covers a settlement of 0 (including an
 *    arbiter ruling fully for the hirer), and getEscrow reports the budget, not the payout: indexers that
 *    want the amount actually paid must read the escrow's Settled event.
 *  - Only the two real counterparties of that escrow (its hirer and its provider) can review, and each one
 *    reviews the OTHER party. Escrows where hirer == provider are rejected as self-dealing.
 *  - One review per side per escrow, ever (hirer→provider once, provider→hirer once). Reviews are immutable.
 *  - Every review is a transaction from the reviewer's own wallet (msg.sender) — no relayed / signed reviews.
 *  - Optional Agent ID flag: if `agentId` is set, the reviewer is flagged when it holds that (non-transferable)
 *    ERC-721 at review time. The probe is best-effort and can never make `review` revert; it can only ever
 *    produce false NEGATIVES (e.g. a reviewer who under-funds gas), never false positives.
 *
 * Limits (stated plainly)
 * -----------------------
 *  - Minimum escrow amount: only escrows of at least `minEscrowAmount` (token base units) can be reviewed.
 *    A provider never consents to a fixed-price deposit, so without a floor anyone could "hire" a stranger
 *    for 1 wei, release, and leave a permanent 1-star review; the floor makes every such review cost the
 *    attacker that amount, paid to the victim. (Metered escrows report the budget here, not the payout, but
 *    their completion is gated by BotHire's settler, which only settles hires a provider delivered on; a
 *    metered escrow settled at 0 or ruled fully for the hirer can still be reviewed, and readers should
 *    discount reviews whose escrow's Settled event paid the provider less than the floor.)
 *  - Trust in the escrows: this contract has no owner, but it trusts the allowlisted escrows' status. Their
 *    owner can rotate the arbiter / settler keys that complete escrows, so a compromised BotHire escrow
 *    owner key could manufacture completed escrows (and therefore review slots); it still cannot move funds
 *    to anyone but the recorded hirer and provider.
 *  - Sybil cost: someone controlling two wallets can still pay themselves (at least the floor, and gas) and
 *    review. Treat the raw count as weak evidence; weight by the Agent ID sub-stats (the reviewer holds a
 *    soulbound Binance Agent ID, tied to a Binance account) and by `escrowAmount` in the event.
 *  - Stats are kept per role: reviews a subject received as provider (from its hirers) and as hirer (from
 *    its providers), so a seller's reputation isn't mixed with how it behaved as a buyer.
 *  - Comments are emitted in the event only (not stored) to keep storage to one slot per subject.
 *
 * Storage: one packed slot per subject per role (4 × uint64) + one slot per escrow (2-bit reviewed mask).
 */
contract BotHireReviews {
    // ========== Constants ==========

    /// @notice Escrow status meaning "completed" (Released / Settled) in every BotHire escrow; a metered Settled may pay 0.
    uint8 public constant STATUS_COMPLETED = 2;
    uint8 public constant MIN_RATING = 1;
    uint8 public constant MAX_RATING = 5;
    uint256 public constant MAX_COMMENT_BYTES = 280;
    uint256 public constant MAX_ESCROWS = 16;
    /// @dev Gas cap for the Agent ID balanceOf probe (bounds a misbehaving token; proxies fit comfortably).
    uint256 internal constant AGENT_ID_PROBE_GAS = 100_000;

    uint8 internal constant REVIEWED_BY_HIRER = 1;
    uint8 internal constant REVIEWED_BY_PROVIDER = 2;

    uint256 internal constant ROLE_AS_PROVIDER = 0; // reviewed by its hirer
    uint256 internal constant ROLE_AS_HIRER = 1; // reviewed by its provider

    // ========== Types ==========

    struct Stats {
        uint64 count; // reviews received
        uint64 ratingSum; // sum of ratings received
        uint64 agentIdCount; // reviews received from Agent ID holders
        uint64 agentIdRatingSum; // sum of ratings from Agent ID holders
    }

    // ========== Immutable config ==========

    /// @notice Binance Agent ID ERC-721 (zero = Agent ID flagging disabled).
    address public immutable agentId;

    /// @notice Smallest escrow amount (token base units) that can be reviewed; see "Minimum escrow amount".
    uint256 public immutable minEscrowAmount;

    address[] internal _escrows;
    mapping(address => bool) public isEscrow;

    // ========== State ==========

    /// @dev subject => role (ROLE_AS_PROVIDER / ROLE_AS_HIRER) => stats received in that role.
    mapping(address => Stats[2]) internal _stats;
    /// @dev escrow => escrowId => bitmask (bit0 = hirer reviewed, bit1 = provider reviewed).
    mapping(address => mapping(bytes32 => uint8)) internal _reviewed;

    // ========== Events ==========

    event Reviewed(
        address indexed subject,
        address indexed reviewer,
        address indexed escrow,
        bytes32 escrowId,
        uint256 escrowAmount,
        uint8 rating,
        bool reviewerIsHirer,
        bool reviewerHasAgentId,
        string comment
    );

    // ========== Errors ==========

    error NoEscrows();
    error TooManyEscrows();
    error ZeroAddress();
    error DuplicateEscrow();
    error NotContract();
    error EscrowNotAllowed();
    error InvalidRating();
    error CommentTooLong();
    error EscrowNotCompleted();
    error SelfDealing();
    error NotParty();
    error AlreadyReviewed();
    error AmountBelowMinimum();

    // ========== Constructor ==========

    /**
     * @param escrows  Fixed allowlist of BotHire escrow contracts (1..MAX_ESCROWS, non-zero, deployed, unique).
     * @param agentId_ Binance Agent ID ERC-721, or address(0) to disable Agent ID flagging.
     * @param minEscrowAmount_ Smallest reviewable escrow amount in token base units (all allowlisted escrows
     *        must use tokens with the same decimals for this to mean the same value).
     */
    constructor(address[] memory escrows, address agentId_, uint256 minEscrowAmount_) {
        uint256 n = escrows.length;
        if (n == 0) revert NoEscrows();
        if (n > MAX_ESCROWS) revert TooManyEscrows();
        for (uint256 i; i < n; ++i) {
            address e = escrows[i];
            if (e == address(0)) revert ZeroAddress();
            if (e.code.length == 0) revert NotContract();
            if (isEscrow[e]) revert DuplicateEscrow();
            isEscrow[e] = true;
            _escrows.push(e);
        }
        if (agentId_ != address(0) && agentId_.code.length == 0) revert NotContract();
        agentId = agentId_;
        minEscrowAmount = minEscrowAmount_;
    }

    // ========== Review ==========

    /**
     * @notice Review the counterparty of a completed BotHire escrow. Caller must be its hirer or provider.
     * @param escrow   Allowlisted escrow contract.
     * @param escrowId The escrow key (as returned by the escrow's computeEscrowId).
     * @param rating   1..5.
     * @param comment  Free text, at most 280 bytes (emitted only, not stored).
     */
    function review(address escrow, bytes32 escrowId, uint8 rating, string calldata comment) external {
        if (!isEscrow[escrow]) revert EscrowNotAllowed();
        if (rating < MIN_RATING || rating > MAX_RATING) revert InvalidRating();
        if (bytes(comment).length > MAX_COMMENT_BYTES) revert CommentTooLong();

        (address subject, bool byHirer, uint256 amount) = _claimSide(escrow, escrowId);
        bool hasAgentId = _holdsAgentId(msg.sender);

        Stats storage s = _stats[subject][byHirer ? ROLE_AS_PROVIDER : ROLE_AS_HIRER];
        // Overflow impossible in practice (would need 2^64 reviews / 2^64 / 5 ratings).
        unchecked {
            s.count += 1;
            s.ratingSum += rating;
            if (hasAgentId) {
                s.agentIdCount += 1;
                s.agentIdRatingSum += rating;
            }
        }

        emit Reviewed(subject, msg.sender, escrow, escrowId, amount, rating, byHirer, hasAgentId, comment);
    }

    // ========== Views ==========

    /// @notice Reputation of `subject` across both roles. Average = ratingSum / count.
    function stats(address subject)
        external
        view
        returns (uint64 count, uint64 ratingSum, uint64 agentIdCount, uint64 agentIdRatingSum)
    {
        Stats memory p = _stats[subject][ROLE_AS_PROVIDER];
        Stats memory h = _stats[subject][ROLE_AS_HIRER];
        unchecked {
            return (p.count + h.count, p.ratingSum + h.ratingSum, p.agentIdCount + h.agentIdCount, p.agentIdRatingSum + h.agentIdRatingSum);
        }
    }

    /// @notice Reputation of `subject` in one role: as provider (reviews from its hirers) or as hirer.
    function statsByRole(address subject, bool asProvider)
        external
        view
        returns (uint64 count, uint64 ratingSum, uint64 agentIdCount, uint64 agentIdRatingSum)
    {
        Stats memory s = _stats[subject][asProvider ? ROLE_AS_PROVIDER : ROLE_AS_HIRER];
        return (s.count, s.ratingSum, s.agentIdCount, s.agentIdRatingSum);
    }

    /// @notice Whether the hirer (`byHirer`) or provider (`!byHirer`) side of an escrow has already reviewed.
    function hasReviewed(address escrow, bytes32 escrowId, bool byHirer) external view returns (bool) {
        return _reviewed[escrow][escrowId] & (byHirer ? REVIEWED_BY_HIRER : REVIEWED_BY_PROVIDER) != 0;
    }

    /// @notice The fixed escrow allowlist.
    function escrowList() external view returns (address[] memory) {
        return _escrows;
    }

    // ========== Internal ==========

    /**
     * @dev Verifies the escrow is completed and msg.sender is one of its two distinct parties, then marks
     *      that side as reviewed (reverting if it already was). Returns the counterparty being reviewed.
     */
    function _claimSide(address escrow, bytes32 escrowId)
        internal
        returns (address subject, bool byHirer, uint256 amount)
    {
        address hirer;
        address provider;
        uint8 status;
        (hirer, provider, amount,,, status) = IBotHireEscrowView(escrow).getEscrow(escrowId);
        if (status != STATUS_COMPLETED) revert EscrowNotCompleted();
        if (hirer == provider) revert SelfDealing();
        if (amount < minEscrowAmount) revert AmountBelowMinimum();

        uint8 bit;
        if (msg.sender == hirer) {
            (subject, byHirer, bit) = (provider, true, REVIEWED_BY_HIRER);
        } else if (msg.sender == provider) {
            (subject, bit) = (hirer, REVIEWED_BY_PROVIDER);
        } else {
            revert NotParty();
        }

        uint8 mask = _reviewed[escrow][escrowId];
        if (mask & bit != 0) revert AlreadyReviewed();
        _reviewed[escrow][escrowId] = mask | bit;
    }

    /**
     * @dev Best-effort `IERC721(agentId).balanceOf(who) > 0`. Implemented as a raw, gas-capped staticcall that
     *      copies at most 32 bytes of return data, so it can never revert `review` — not on a reverting token,
     *      an empty / short return (which a Solidity try/catch would NOT catch: decode errors bubble), nor a
     *      return-data bomb. Any failure yields `false`.
     */
    function _holdsAgentId(address who) internal view returns (bool held) {
        address token = agentId;
        if (token == address(0)) return false;
        bytes4 sel = 0x70a08231; // balanceOf(address)
        uint256 gasCap = AGENT_ID_PROBE_GAS;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            mstore(add(ptr, 4), who)
            let ok := staticcall(gasCap, token, ptr, 0x24, ptr, 0x20)
            held := and(and(ok, iszero(lt(returndatasize(), 0x20))), iszero(iszero(mload(ptr))))
        }
    }
}
