// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISignatureTransfer (Permit2 subset)
 * @notice The minimal Uniswap Permit2 surface BotHire's gasless-deposit escrows need to pull a buyer's
 *         tokens against an off-chain signature. Canonical Permit2 is deployed at the SAME address
 *         (0x000000000022D473030F116dDEE9F6B43aC78BA3) on every EVM chain. Shared by BotHireEscrowV3 and
 *         BotHireMeteredEscrowV2 so the interface can't drift between them.
 */
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice Transfers `owner`'s tokens to `transferDetails.to`, verifying `owner`'s signature over the
    ///         permit AND the arbitrary `witness` (typed by `witnessTypeString`). Reverts unless the
    ///         recovered signer == owner and every signed field matches. The nonce is single-use.
    function permitWitnessTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}
