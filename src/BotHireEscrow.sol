// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BotHireEscrow
 * @notice 最小信任 Escrow 合约 - USDC on Base
 * @dev 无 owner / 无 pause / 无手续费，24h deadline 链上强制执行
 */
contract BotHireEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== 状态 ==========

    enum EscrowStatus {
        Empty,     // 0 - 不存在
        Deposited, // 1 - hirer 已存入
        Released,  // 2 - 已释放给 provider
        Refunded   // 3 - 已退回给 hirer
    }

    struct Escrow {
        address hirer;
        address provider;
        uint256 amount;
        uint256 deadline;     // deposit 时间 + 24h
        EscrowStatus status;
    }

    /// @notice USDC 代币合约 (immutable)
    IERC20 public immutable usdc;

    /// @notice 24 小时超时 (秒)
    uint256 public constant TIMEOUT = 24 hours;

    /// @notice escrowId => Escrow
    mapping(bytes32 => Escrow) public escrows;

    // ========== 事件 ==========

    event Deposited(bytes32 indexed escrowId, address indexed hirer, address indexed provider, uint256 amount, uint256 deadline);
    event Released(bytes32 indexed escrowId, address indexed provider, uint256 amount);
    event Refunded(bytes32 indexed escrowId, address indexed hirer, uint256 amount);

    // ========== 错误 ==========

    error EscrowAlreadyExists();
    error EscrowNotFound();
    error NotHirer();
    error NotDeposited();
    error DeadlineNotReached();
    error ZeroAmount();
    error ZeroAddress();

    // ========== 构造函数 ==========

    /**
     * @param _usdc Base 链 USDC 地址: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
     */
    constructor(address _usdc) {
        if (_usdc == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
    }

    // ========== 外部方法 ==========

    /**
     * @notice Hirer 存入 USDC 到 escrow
     * @param escrowId hireId 的 keccak256 哈希 (bytes32)
     * @param provider Provider 钱包地址
     * @param amount USDC 金额 (6 decimals)
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
     * @notice Hirer 释放资金给 provider (完成任务)
     * @param escrowId Escrow 标识
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
     * @notice Hirer 主动退款 (取消任务)
     * @param escrowId Escrow 标识
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
     * @notice 24h 超时后任何人可调用退款给 hirer
     * @param escrowId Escrow 标识
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

    // ========== 查询方法 ==========

    /**
     * @notice 查询 escrow 状态
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
