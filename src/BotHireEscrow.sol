// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BotHireEscrow
 * @notice Minimal-trust escrow contract - USDC on Base
 * @dev No owner / no pause / no fees; the 24h deadline is enforced on-chain
 */
contract BotHireEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== State ==========

    enum EscrowStatus {
        Empty,     // 0 - does not exist
        Deposited, // 1 - hirer has deposited
        Released,  // 2 - released to provider
        Refunded   // 3 - refunded to hirer
    }

    struct Escrow {
        address hirer;
        address provider;
        uint256 amount;
        uint256 deadline;     // deposit time + 24h
        EscrowStatus status;
    }

    /// @notice USDC token contract (immutable)
    IERC20 public immutable usdc;

    /// @notice 24-hour timeout (in seconds)
    uint256 public constant TIMEOUT = 24 hours;

    /// @notice escrowId => Escrow
    mapping(bytes32 => Escrow) public escrows;

    // ========== Events ==========

    event Deposited(bytes32 indexed escrowId, address indexed hirer, address indexed provider, uint256 amount, uint256 deadline);
    event Released(bytes32 indexed escrowId, address indexed provider, uint256 amount);
    event Refunded(bytes32 indexed escrowId, address indexed hirer, uint256 amount);

    // ========== Errors ==========

    error EscrowAlreadyExists();
    error EscrowNotFound();
    error NotHirer();
    error NotDeposited();
    error DeadlineNotReached();
    error ZeroAmount();
    error ZeroAddress();

    // ========== Constructor ==========

    /**
     * @param _usdc Base chain USDC address: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
     */
    constructor(address _usdc) {
        if (_usdc == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
    }

    // ========== External methods ==========

    /**
     * @notice Hirer deposits USDC into the escrow
     * @param escrowId keccak256 hash of hireId (bytes32)
     * @param provider Provider wallet address
     * @param amount USDC amount (6 decimals)
     */
    function deposit(bytes32 escrowId, address provider, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (provider == address(0)) revert ZeroAddress();
        if (escrows[escrowId].status != EscrowStatus.Empty) revert EscrowAlreadyExists();

        escrows[escrowId] = Escrow({
            hirer: msg.sender,
            provider: provider,
            amount: amount,
            deadline: block.timestamp + TIMEOUT,
            status: EscrowStatus.Deposited
        });

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(escrowId, msg.sender, provider, amount, block.timestamp + TIMEOUT);
    }

    /**
     * @notice Hirer releases the funds to the provider (task completed)
     * @param escrowId Escrow identifier
     */
    function release(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Deposited) revert NotDeposited();
        if (msg.sender != e.hirer) revert NotHirer();

        e.status = EscrowStatus.Released;

        usdc.safeTransfer(e.provider, e.amount);

        emit Released(escrowId, e.provider, e.amount);
    }

    /**
     * @notice Hirer voluntarily refunds (cancels the task)
     * @param escrowId Escrow identifier
     */
    function refund(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Deposited) revert NotDeposited();
        if (msg.sender != e.hirer) revert NotHirer();

        e.status = EscrowStatus.Refunded;

        usdc.safeTransfer(e.hirer, e.amount);

        emit Refunded(escrowId, e.hirer, e.amount);
    }

    /**
     * @notice After the 24h timeout, anyone can call this to refund the hirer
     * @param escrowId Escrow identifier
     */
    function claimRefund(bytes32 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.status == EscrowStatus.Empty) revert EscrowNotFound();
        if (e.status != EscrowStatus.Deposited) revert NotDeposited();
        if (block.timestamp < e.deadline) revert DeadlineNotReached();

        e.status = EscrowStatus.Refunded;

        usdc.safeTransfer(e.hirer, e.amount);

        emit Refunded(escrowId, e.hirer, e.amount);
    }

    // ========== View methods ==========

    /**
     * @notice Query the escrow status
     */
    function getEscrow(bytes32 escrowId) external view returns (
        address hirer,
        address provider,
        uint256 amount,
        uint256 deadline,
        EscrowStatus status
    ) {
        Escrow storage e = escrows[escrowId];
        return (e.hirer, e.provider, e.amount, e.deadline, e.status);
    }
}
