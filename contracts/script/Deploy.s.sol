// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentBudget} from "../src/AgentBudget.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Deploys MockUSDC + AgentBudget, funds the vault, registers one
///         agent policy and one allowlisted payee. Writes the two new
///         addresses to deployments/latest.env for deploy.sh to merge into .env.
contract Deploy is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("OWNER_PRIVATE_KEY");
        address agent = vm.envAddress("AGENT_ADDRESS");
        address payee = vm.envAddress("PAYEE_ADDRESS");
        uint128 perCallMax = uint128(vm.envUint("PER_CALL_MAX"));
        uint128 dailyMax = uint128(vm.envUint("DAILY_MAX"));
        uint256 funding = vm.envUint("VAULT_FUNDING");

        vm.startBroadcast(ownerKey);

        MockUSDC usdc = new MockUSDC();
        AgentBudget vault = new AgentBudget(usdc);
        usdc.mint(address(vault), funding);
        vault.setPolicy(agent, perCallMax, dailyMax);
        vault.setPayee(payee, true);

        vm.stopBroadcast();

        console.log("MockUSDC:    ", address(usdc));
        console.log("AgentBudget: ", address(vault));
        console.log("vault USDC balance:", usdc.balanceOf(address(vault)));
        console.log("remainingToday(agent):", vault.remainingToday(agent));

        string memory out = string.concat(
            "USDC_ADDRESS=", vm.toString(address(usdc)), "\n",
            "VAULT_ADDRESS=", vm.toString(address(vault)), "\n"
        );
        vm.writeFile("deployments/latest.env", out);
    }
}
