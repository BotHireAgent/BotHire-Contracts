// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BotHireMeteredEscrow} from "../src/BotHireMeteredEscrow.sol";

/**
 * @notice Deploys BotHireMeteredEscrow to Base mainnet.
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY  deployer (becomes owner)
 *   SETTLER_ADDRESS       platform settler key (settles actual usage)
 *   ARBITER_ADDRESS       platform arbiter key (resolves disputes)
 */
contract DeployMetered is Script {
    /// @dev Base Mainnet USDC address
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address settler = vm.envAddress("SETTLER_ADDRESS");
        address arbiter = vm.envAddress("ARBITER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        BotHireMeteredEscrow escrow = new BotHireMeteredEscrow(BASE_USDC, settler, arbiter);

        console.log("BotHireMeteredEscrow deployed at:", address(escrow));
        console.log("USDC:", address(escrow.usdc()));
        console.log("owner:", escrow.owner());
        console.log("settler:", escrow.settler());
        console.log("arbiter:", escrow.arbiter());

        vm.stopBroadcast();
    }
}
