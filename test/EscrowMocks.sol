// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ISignatureTransfer} from "../src/IPermit2.sol";

/// @dev Mock 6-decimal token (USDC-like, Base).
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Mock 18-decimal token — proves the escrows are decimal-agnostic.
contract Mock18 is ERC20 {
    constructor() ERC20("BSC USD", "USDT") {}
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @dev Faithful stand-in for canonical Permit2's SignatureTransfer.permitWitnessTransferFrom.
 *      Mirrors the real algorithm byte-for-byte (Uniswap permit2 PermitHash.sol + EIP712.sol):
 *        - EIP-712 domain = keccak(EIP712Domain(string name,uint256 chainId,address verifyingContract)),
 *          name "Permit2", NO version field (matches real Permit2);
 *        - witness typeHash = keccak(STUB ++ witnessTypeString) with the real STUB;
 *        - structHash field order = (typeHash, tokenPermissionsHash, msg.sender=spender, nonce, deadline, witness);
 *        - EOA ecrecover, single-use nonce, then pulls the buyer's approved tokens.
 *      Real Permit2 can't be imported (it pins solc =0.8.17 vs this repo's 0.8.24); the unit tests sign
 *      with an INDEPENDENT full type string, so a wrong witness string in a contract still fails
 *      verification. A real-Permit2 fork check is part of the deploy/staging validation (see runbook).
 */
contract MockPermit2 {
    bytes32 public constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string constant STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    bytes32 public immutable DOMAIN_SEPARATOR;
    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    error InvalidSigner();
    error InvalidNonce();
    error SignatureExpired();

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("Permit2"),
                block.chainid,
                address(this)
            )
        );
    }

    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        if (block.timestamp > permit.deadline) revert SignatureExpired();
        if (nonceUsed[owner][permit.nonce]) revert InvalidNonce();
        nonceUsed[owner][permit.nonce] = true;

        bytes32 typeHash = keccak256(abi.encodePacked(STUB, witnessTypeString));
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount));
        bytes32 structHash = keccak256(
            abi.encode(typeHash, tokenPermissionsHash, msg.sender, permit.nonce, permit.deadline, witness)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (ECDSA.recover(digest, signature) != owner) revert InvalidSigner();

        IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}
