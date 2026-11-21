// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BotHireReviews} from "../src/BotHireReviews.sol";

/**
 * @notice Deploys the ownerless BotHireReviews registry on BNB Chain (chainid 56), allowlisting the four
 *         live BotHire escrows and flagging Binance Agent ID holders. No key handling here — pass the
 *         signer on the CLI at deploy time, e.g.:
 *
 *   forge script script/DeployReviews.s.sol --rpc-url bsc --broadcast --verify \
 *     --private-key <key>   (or --ledger / --account <keystore>)
 *
 *  The deployer gets NO privileges: the contract has no owner and the allowlist is fixed forever.
 */
contract DeployReviews is Script {
    // BSC mainnet BotHire escrows
    address constant FIXED_USDT = 0xf6701227b4FdCB9Df9E9e616EFdbE15094120498;
    address constant FIXED_USDC = 0x2e5F252A82d8C4130b8872B7f4ebBB34d3089432;
    address constant METERED_USDT = 0x367c687Ca324048849E25726979DcE52aD4BA36d;
    address constant METERED_USDC = 0x2800Eb74962ef0C243a7452613a3D922E5AEE48F;
    // Binance Agent ID (ERC-721, non-transferable)
    address constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    function run() external returns (BotHireReviews reviews) {
        require(block.chainid == 56, "DeployReviews: BSC mainnet only");

        address[] memory escrows = new address[](4);
        escrows[0] = FIXED_USDT;
        escrows[1] = FIXED_USDC;
        escrows[2] = METERED_USDT;
        escrows[3] = METERED_USDC;

        vm.startBroadcast();
        reviews = new BotHireReviews(escrows, AGENT_ID);
        vm.stopBroadcast();

        console.log("BotHireReviews deployed at:", address(reviews));
        console.log("agentId:", reviews.agentId());
        for (uint256 i; i < escrows.length; ++i) {
            console.log("escrow:", escrows[i]);
        }
    }
}
