// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BotHireEscrow} from "../src/BotHireEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 测试网 Mock USDC (6 decimals)
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
 * @notice Base Sepolia 测试网部署脚本
 * @dev 部署 MockUSDC + BotHireEscrow，并给部署者铸造测试 USDC
 *
 * 用法:
 *   forge script script/DeployTestnet.s.sol:DeployTestnet \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --broadcast --verify
 */
contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. 部署 Mock USDC
        TestUSDC usdc = new TestUSDC();
        console.log("TestUSDC deployed at:", address(usdc));

        // 2. 给部署者铸造 10,000 USDC (6 decimals)
        usdc.mint(deployer, 10_000_000_000);
        console.log("Minted 10,000 USDC to deployer:", deployer);

        // 3. 部署 Escrow 合约
        BotHireEscrow escrow = new BotHireEscrow(address(usdc));
        console.log("BotHireEscrow deployed at:", address(escrow));

        vm.stopBroadcast();

        // 输出汇总
        console.log("========== Deployment Summary ==========");
        console.log("Network:  Base Sepolia");
        console.log("USDC:    ", address(usdc));
        console.log("Escrow:  ", address(escrow));
        console.log("Deployer:", deployer);
    }
}
