// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BotHireMeteredEscrowV2} from "../src/BotHireMeteredEscrowV2.sol";

/**
 * @notice Deploys BotHireMeteredEscrowV2 (usage-metered escrow + gasless Permit2 deposit) for ONE
 *         (chain, token). Decimal-agnostic. Deploy per (chain, token), operator-approved, one tx at a time.
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY  deployer (becomes owner; can only rotate settler/arbiter / transfer ownership)
 *   TOKEN_ADDRESS         the ERC-20 to escrow (Base USDC 0x8335…2913, Arbitrum USDC 0xaf88…5831, …)
 *   SETTLER_ADDRESS       platform settler key (settles actual metered usage)
 *   ARBITER_ADDRESS       platform arbiter key (resolves disputes)
 *   PERMIT2_ADDRESS       canonical Permit2 — 0x000000000022D473030F116dDEE9F6B43aC78BA3 on every chain
 */
contract DeployMeteredEscrowV2 is Script {
    address constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        address settler = vm.envAddress("SETTLER_ADDRESS");
        address arbiter = vm.envAddress("ARBITER_ADDRESS");
        address permit2 = vm.envOr("PERMIT2_ADDRESS", CANONICAL_PERMIT2);

        vm.startBroadcast(deployerPrivateKey);

        BotHireMeteredEscrowV2 escrow = new BotHireMeteredEscrowV2(tokenAddr, settler, arbiter, permit2);

        console.log("BotHireMeteredEscrowV2 deployed at:", address(escrow));
        console.log("token:", address(escrow.usdc()));
        console.log("owner:", escrow.owner());
        console.log("settler:", escrow.settler());
        console.log("arbiter:", escrow.arbiter());
        console.log("permit2:", address(escrow.PERMIT2()));

        vm.stopBroadcast();
    }
}
