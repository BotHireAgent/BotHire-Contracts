// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BotHireEscrowV3} from "../src/BotHireEscrowV3.sol";

/**
 * @notice Deploys BotHireEscrowV3 (fixed-price escrow with dispute/arbiter + gasless Permit2 deposit) for
 *         ONE (chain, token). Same source serves Base USDC (6-dec) and other chains' stablecoins; the
 *         contract is decimal-agnostic. Deploy per (chain, token), operator-approved, one tx at a time.
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY  deployer (becomes owner; can only rotate arbiter / transfer ownership)
 *   TOKEN_ADDRESS         the ERC-20 to escrow (Base USDC 0x8335…2913, Arbitrum USDC 0xaf88…5831, …)
 *   ARBITER_ADDRESS       platform arbiter key (resolves disputes)
 *   PERMIT2_ADDRESS       canonical Permit2 — 0x000000000022D473030F116dDEE9F6B43aC78BA3 on every chain
 *
 * Example:
 *   TOKEN_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 ARBITER_ADDRESS=0x… \
 *   PERMIT2_ADDRESS=0x000000000022D473030F116dDEE9F6B43aC78BA3 \
 *   forge script script/DeployEscrowV3.s.sol --rpc-url base --broadcast --verify
 */
contract DeployEscrowV3 is Script {
    /// @dev Canonical Permit2, identical on every EVM chain. Used as the default if PERMIT2_ADDRESS is unset.
    address constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        address arbiter = vm.envAddress("ARBITER_ADDRESS");
        address permit2 = vm.envOr("PERMIT2_ADDRESS", CANONICAL_PERMIT2);

        vm.startBroadcast(deployerPrivateKey);

        BotHireEscrowV3 escrow = new BotHireEscrowV3(tokenAddr, arbiter, permit2);

        console.log("BotHireEscrowV3 deployed at:", address(escrow));
        console.log("token:", address(escrow.token()));
        console.log("owner:", escrow.owner());
        console.log("arbiter:", escrow.arbiter());
        console.log("permit2:", address(escrow.PERMIT2()));

        vm.stopBroadcast();
    }
}
