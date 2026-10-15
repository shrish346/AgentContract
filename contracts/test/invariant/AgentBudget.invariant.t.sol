// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AgentBudget} from "../../src/AgentBudget.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {AgentBudgetHandler} from "./AgentBudgetHandler.sol";

contract AgentBudgetInvariantTest is StdInvariant, Test {
    AgentBudget vault;
    MockUSDC usdc;
    AgentBudgetHandler handler;

    address owner = makeAddr("owner");

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(owner);
        vault = new AgentBudget(usdc);
        handler = new AgentBudgetHandler(vault, usdc, owner);

        targetContract(address(handler));

        // pay() is listed 4 times so it gets about a third of all calls.
        // Without the weighting the admin actions drown it out and the daily cap
        // is almost never reached.
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = AgentBudgetHandler.pay.selector;
        selectors[1] = AgentBudgetHandler.pay.selector;
        selectors[2] = AgentBudgetHandler.pay.selector;
        selectors[3] = AgentBudgetHandler.pay.selector;
        selectors[4] = AgentBudgetHandler.setPolicy.selector;
        selectors[5] = AgentBudgetHandler.toggleActive.selector;
        selectors[6] = AgentBudgetHandler.setPayee.selector;
        selectors[7] = AgentBudgetHandler.fund.selector;
        selectors[8] = AgentBudgetHandler.withdraw.selector;
        selectors[9] = AgentBudgetHandler.warpTime.selector;
        selectors[10] = AgentBudgetHandler.adminAsStranger.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// For every agent and every day it was paid, the day's total stays within
    /// the dailyMax in force at that day's last successful pay.
    function invariant_dailyCapNeverExceeded() public view {
        for (uint256 i; i < handler.agentCount(); i++) {
            address agent = handler.agents(i);
            uint256[] memory days_ = handler.paidDaysOf(agent);
            for (uint256 j; j < days_.length; j++) {
                assertLe(
                    handler.ghost_paidPerAgentPerDay(agent, days_[j]),
                    handler.ghost_dailyMaxAtLastPay(agent, days_[j]),
                    "daily cap exceeded"
                );
            }
        }
    }

    /// The contract's record of today's spend matches the ghost total for today.
    /// This catches day-rollover bugs in either direction.
    function invariant_spentTodayMatchesContract() public view {
        uint256 today = vm.getBlockTimestamp() / 1 days;
        for (uint256 i; i < handler.agentCount(); i++) {
            address agent = handler.agents(i);
            (uint128 spent, uint64 day) = vault.spendOf(agent);
            uint256 contractToday = day == today ? spent : 0;
            assertEq(contractToday, handler.ghost_paidPerAgentPerDay(agent, today), "spentToday drift");
        }
    }

    /// remainingToday() (the view the demo and operator rely on) agrees with the ghost model.
    function invariant_remainingTodayConsistent() public view {
        uint256 today = vm.getBlockTimestamp() / 1 days;
        for (uint256 i; i < handler.agentCount(); i++) {
            address agent = handler.agents(i);
            (, uint128 dailyMax, bool active) = vault.policies(agent);
            uint256 paid = handler.ghost_paidPerAgentPerDay(agent, today);
            uint256 expected = !active || paid >= dailyMax ? 0 : dailyMax - paid;
            assertEq(vault.remainingToday(agent), expected, "remainingToday drift");
        }
    }

    function invariant_noRequestIdPaidTwice() public view {
        uint256 n = handler.requestIdCount();
        for (uint256 i; i < n; i++) {
            assertLe(handler.ghost_timesPaid(handler.requestIds(i)), 1, "requestId paid twice");
        }
    }

    function invariant_noPayWhileInactive() public view {
        assertEq(handler.ghost_paidWhileInactive(), 0, "paid while inactive");
    }

    function invariant_onlyAllowedPayees() public view {
        assertEq(handler.ghost_paidToDisallowedPayee(), 0, "paid disallowed payee");
    }

    function invariant_perCallCapHolds() public view {
        assertEq(handler.ghost_maxSingleAmountOverPerCall(), 0, "per-call cap exceeded");
    }

    /// Every token that entered the vault is either still there, paid out, or withdrawn.
    function invariant_conservation() public view {
        assertEq(
            usdc.balanceOf(address(vault)) + handler.ghost_totalPaidOut() + handler.ghost_totalWithdrawn(),
            handler.ghost_totalFunded(),
            "conservation"
        );
    }

    function invariant_onlyOwnerAdmin() public view {
        assertEq(handler.ghost_unauthorizedAdminSuccess(), 0, "non-owner admin call succeeded");
    }

    /// Runs once at the end of each run. Logs coverage, and if INVARIANT_STATS
    /// is set it appends one line per run so the counts can be summed.
    function afterInvariant() public {
        string memory line = handler.callSummary();
        emit log(line);
        if (vm.envOr("INVARIANT_STATS", false)) {
            vm.createDir("cache/invariant-stats", true);
            vm.writeLine("cache/invariant-stats/runs.log", line);
        }
    }
}
