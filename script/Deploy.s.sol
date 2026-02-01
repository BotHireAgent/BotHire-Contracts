// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BotHireEscrow} from "../src/BotHireEscrow.sol";

contract Deploy is Script {
    /// @dev Base Mainnet USDC 地址
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        BotHireEscrow escrow = new BotHireEscrow(BASE_USDC);

        console.log("BotHireEscrow deployed at:", address(escrow));
        console.log("USDC address:", address(escrow.usdc()));

        vm.stopBroadcast();
    }
}
