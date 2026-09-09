// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BotHireMeteredEscrow} from "../src/BotHireMeteredEscrow.sol";

/**
 * @notice Deploys BotHireMeteredEscrow for ONE (chain, token), with the token read from env — the
 *         token-parameterized companion to DeployMetered.s.sol (which hardcodes Base USDC). Use this
 *         for the BNB USDT / USDC metered deployments. The contract's `usdc` name is cosmetic; it is
 *         token-agnostic and decimal-agnostic.
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY  deployer (becomes owner)
 *   TOKEN_ADDRESS         the ERC-20 to escrow (e.g. BNB USDT 0x55d3…7955, BNB USDC 0x8AC7…580d)
 *   SETTLER_ADDRESS       platform settler key (settles actual usage)
 *   ARBITER_ADDRESS       platform arbiter key (resolves disputes)
 */
contract DeployMeteredToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        address settler = vm.envAddress("SETTLER_ADDRESS");
        address arbiter = vm.envAddress("ARBITER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        BotHireMeteredEscrow escrow = new BotHireMeteredEscrow(tokenAddr, settler, arbiter);

        console.log("BotHireMeteredEscrow deployed at:", address(escrow));
        console.log("token:", address(escrow.usdc()));
        console.log("owner:", escrow.owner());
        console.log("settler:", escrow.settler());
        console.log("arbiter:", escrow.arbiter());

        vm.stopBroadcast();
    }
}
