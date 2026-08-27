// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BotHireEscrow} from "../src/BotHireEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Testnet Mock USDC (6 decimals)
contract TestUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @notice Base Sepolia testnet deployment script
 * @dev Deploys MockUSDC + BotHireEscrow and mints test USDC to the deployer
 *
 * Usage:
 *   forge script script/DeployTestnet.s.sol:DeployTestnet \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --broadcast --verify
 */
contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock USDC
        TestUSDC usdc = new TestUSDC();
        console.log("TestUSDC deployed at:", address(usdc));

        // 2. Mint 10,000 USDC (6 decimals) to the deployer
        usdc.mint(deployer, 10_000_000_000);
        console.log("Minted 10,000 USDC to deployer:", deployer);

        // 3. Deploy the Escrow contract
        BotHireEscrow escrow = new BotHireEscrow(address(usdc));
        console.log("BotHireEscrow deployed at:", address(escrow));

        vm.stopBroadcast();

        // Print summary
        console.log("========== Deployment Summary ==========");
        console.log("Network:  Base Sepolia");
        console.log("USDC:    ", address(usdc));
        console.log("Escrow:  ", address(escrow));
        console.log("Deployer:", deployer);
    }
}
