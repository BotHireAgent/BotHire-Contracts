// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BotHireEscrowV2} from "../src/BotHireEscrowV2.sol";

/**
 * @notice Deploys BotHireEscrowV2 (fixed-price escrow with dispute/arbiter) for ONE (chain, token).
 *         Run once per deployment with the matching env — same source serves Base USDC (6-dec) and
 *         BNB USDT/USDC (18-dec); the contract is decimal-agnostic.
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY  deployer (becomes owner; can only rotate arbiter / transfer ownership)
 *   TOKEN_ADDRESS         the ERC-20 to escrow (e.g. Base USDC 0x8335…2913, BNB USDT 0x55d3…7955, BNB USDC 0x8AC7…580d)
 *   ARBITER_ADDRESS       platform arbiter key (resolves disputes)
 *
 * Example (per-network via --rpc-url base|bsc):
 *   TOKEN_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 ARBITER_ADDRESS=0x… \
 *   forge script script/DeployEscrowV2.s.sol --rpc-url base --broadcast --verify
 */
contract DeployEscrowV2 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        address arbiter = vm.envAddress("ARBITER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        BotHireEscrowV2 escrow = new BotHireEscrowV2(tokenAddr, arbiter);

        console.log("BotHireEscrowV2 deployed at:", address(escrow));
        console.log("token:", address(escrow.token()));
        console.log("owner:", escrow.owner());
        console.log("arbiter:", escrow.arbiter());

        vm.stopBroadcast();
    }
}
