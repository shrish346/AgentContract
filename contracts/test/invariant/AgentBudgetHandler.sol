// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {AgentBudget} from "../../src/AgentBudget.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// @notice Drives the vault with bounded random actions for invariant testing.
///         Ghost variables are written only after a call succeeds, and they are
///         computed from state read *before* the call. A missing check in the
///         contract therefore shows up as a nonzero ghost, not as a revert.
contract AgentBudgetHandler is Test {
    AgentBudget public immutable vault;
    MockUSDC public immutable usdc;
    address public immutable owner;

    address[3] public agents;
    address[3] public payees;

    // Every requestId ever passed to pay(), so invariants can iterate them.
    bytes32[] public requestIds;
    mapping(bytes32 => bool) internal seenId;
    uint256 internal idNonce;

    // ---------------------------------------------------------------- ghosts

    mapping(address agent => mapping(uint256 day => uint256)) public ghost_paidPerAgentPerDay;
    // dailyMax in force at the last successful pay of that (agent, day). The
    // contract checks against the *current* dailyMax, and setPolicy can lower
    // it mid-day, so this is the cap the day's running total was last held to.
    mapping(address agent => mapping(uint256 day => uint256)) public ghost_dailyMaxAtLastPay;
    mapping(address agent => uint256[]) internal paidDays;
    mapping(address agent => mapping(uint256 day => bool)) internal paidDaySeen;

    mapping(bytes32 requestId => uint256) public ghost_timesPaid;
    uint256 public ghost_paidWhileInactive;
    uint256 public ghost_paidToDisallowedPayee;
    uint256 public ghost_maxSingleAmountOverPerCall;
    uint256 public ghost_totalPaidOut;
    uint256 public ghost_totalFunded;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_unauthorizedAdminSuccess;

    // ------------------------------------------------------- coverage counters

    mapping(bytes32 action => uint256) public successes;
    mapping(bytes32 action => uint256) public reverts;
    mapping(bytes4 selector => uint256) public payReverts;

    uint256 constant INITIAL_FUNDING = 1_000e6;

    constructor(AgentBudget vault_, MockUSDC usdc_, address owner_) {
        vault = vault_;
        usdc = usdc_;
        owner = owner_;

        agents = [makeAddr("agent0"), makeAddr("agent1"), makeAddr("agent2")];
        payees = [makeAddr("payee0"), makeAddr("payee1"), makeAddr("payee2")];

        vm.startPrank(owner);
        vault.setPolicy(agents[0], 1e6, 4e6);
        vault.setPolicy(agents[1], 2e6, 6e6);
        vault.setPolicy(agents[2], 5e5, 2e6);
        vault.setPayee(payees[0], true);
        vault.setPayee(payees[1], true);
        // payees[2] starts disallowed.
        vm.stopPrank();

        usdc.mint(address(vault), INITIAL_FUNDING);
        ghost_totalFunded = INITIAL_FUNDING;
    }

    // ---------------------------------------------------------------- agent

    function pay(uint256 agentSeed, uint256 payeeSeed, uint256 amount, uint256 idSeed) external {
        address agent = agents[agentSeed % 3];
        address payee = payees[payeeSeed % 3];

        // Pre-state, read before the call.
        (uint128 perCallMax, uint128 dailyMax, bool active) = vault.policies(agent);
        bool payeeAllowed = vault.allowedPayee(payee);
        uint256 day = block.timestamp / 1 days;

        // Mostly within perCallMax, roughly 1 in 5 over it. The fuzzer favors
        // edge values (0, 1, max), so a plain bound() clusters at the range ends:
        // near-zero amounts never fill the daily cap, and max always trips
        // the per-call cap. Hashing first spreads amounts evenly across the range.
        amount = bound(
            uint256(keccak256(abi.encode(amount))),
            uint256(perCallMax) / 4 + 1,
            uint256(perCallMax) * 5 / 4 + 1
        );

        // 1 in 5 reuses an earlier id so DuplicateRequest is hit. The rest are
        // fresh, so the pool never runs out and successful pays stay possible.
        bytes32 requestId;
        if (idSeed % 5 == 0 && requestIds.length > 0) {
            requestId = requestIds[idSeed % requestIds.length];
        } else {
            requestId = keccak256(abi.encode("rid", idNonce++));
        }
        if (!seenId[requestId]) {
            seenId[requestId] = true;
            requestIds.push(requestId);
        }

        vm.prank(agent);
        try vault.pay(payee, amount, requestId) {
            successes["pay"]++;

            ghost_paidPerAgentPerDay[agent][day] += amount;
            ghost_dailyMaxAtLastPay[agent][day] = dailyMax;
            if (!paidDaySeen[agent][day]) {
                paidDaySeen[agent][day] = true;
                paidDays[agent].push(day);
            }
            ghost_timesPaid[requestId]++;
            ghost_totalPaidOut += amount;

            if (!active) ghost_paidWhileInactive++;
            if (!payeeAllowed) ghost_paidToDisallowedPayee++;
            if (amount > perCallMax && amount - perCallMax > ghost_maxSingleAmountOverPerCall) {
                ghost_maxSingleAmountOverPerCall = amount - perCallMax;
            }
        } catch (bytes memory err) {
            reverts["pay"]++;
            payReverts[err.length >= 4 ? bytes4(err) : bytes4(0)]++;
        }
    }

    // ---------------------------------------------------------------- owner

    function setPolicy(uint256 agentSeed, uint256 perCallMax, uint256 dailyMax) external {
        address agent = agents[agentSeed % 3];
        perCallMax = bound(perCallMax, 5e5, 3e6);
        dailyMax = bound(dailyMax, perCallMax, perCallMax * 6); // cap reachable in a few pays

        vm.prank(owner);
        vault.setPolicy(agent, uint128(perCallMax), uint128(dailyMax));
        successes["setPolicy"]++;
    }

    /// Revoke if active, otherwise reactivate with the agent's existing limits.
    /// Revocation fires 1 in 4 times so agents are active most of the run.
    function toggleActive(uint256 agentSeed) external {
        address agent = agents[agentSeed % 3];
        (uint128 perCallMax, uint128 dailyMax, bool active) = vault.policies(agent);
        if (active && agentSeed % 4 != 0) return;

        vm.prank(owner);
        if (active) vault.revokeAgent(agent);
        else vault.setPolicy(agent, perCallMax, dailyMax);
        successes["toggleActive"]++;
    }

    /// Allows 3 in 4 times, so most payees stay payable and pays can succeed.
    function setPayee(uint256 payeeSeed) external {
        bool allowed = (payeeSeed / 3) % 4 != 0;
        vm.prank(owner);
        vault.setPayee(payees[payeeSeed % 3], allowed);
        successes["setPayee"]++;
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 1e6, 100e6);
        usdc.mint(address(vault), amount);
        ghost_totalFunded += amount;
        successes["fund"]++;
    }

    function withdraw(uint256 amount) external {
        amount = bound(amount, 0, usdc.balanceOf(address(vault)) / 10);
        vm.prank(owner);
        vault.withdraw(owner, amount);
        ghost_totalWithdrawn += amount;
        successes["withdraw"]++;
    }

    /// Advances 0-3 days. 15 in 16 warps stay under an hour so agents can make
    /// enough pays in one day to reach dailyMax. The rest cross day boundaries.
    function warpTime(uint256 secs) external {
        secs = secs % 16 == 0 ? bound(secs, 0, 3 days) : bound(secs, 0, 1 hours);
        vm.warp(block.timestamp + secs);
        successes["warpTime"]++;
    }

    // ------------------------------------------------------------- attacker

    /// A random non-owner tries one of the owner-only functions. Every attempt
    /// must revert. Any success is recorded and fails invariant_onlyOwnerAdmin.
    function adminAsStranger(uint256 callerSeed, uint256 actionSeed, uint256 arg) external {
        address caller = address(uint160(bound(callerSeed, 1, type(uint160).max)));
        if (caller == owner) caller = makeAddr("stranger");
        address target = agents[arg % 3];
        // Computed before the prank, so balanceOf doesn't use up the prank.
        uint256 withdrawAmount = bound(arg, 0, usdc.balanceOf(address(vault)));

        uint256 action = actionSeed % 4;
        vm.prank(caller);
        bool ok;
        if (action == 0) {
            try vault.setPolicy(target, type(uint128).max, type(uint128).max) { ok = true; } catch {}
        } else if (action == 1) {
            try vault.revokeAgent(target) { ok = true; } catch {}
        } else if (action == 2) {
            try vault.setPayee(caller, true) { ok = true; } catch {}
        } else {
            try vault.withdraw(caller, withdrawAmount) { ok = true; } catch {}
        }

        if (ok) {
            ghost_unauthorizedAdminSuccess++;
            successes["adminAsStranger"]++;
        } else {
            reverts["adminAsStranger"]++;
        }
    }

    // ------------------------------------------------------------- views

    function agentCount() external pure returns (uint256) {
        return 3;
    }

    function requestIdCount() external view returns (uint256) {
        return requestIds.length;
    }

    function paidDaysOf(address agent) external view returns (uint256[] memory) {
        return paidDays[agent];
    }

    function callSummary() external view returns (string memory) {
        return string.concat(_paySummary(), _adminSummary());
    }

    // Split in two to stay under the stack limit for string.concat.
    function _paySummary() internal view returns (string memory) {
        return string.concat(
            "pay_ok=", vm.toString(successes["pay"]),
            " pay_revert=", vm.toString(reverts["pay"]),
            " AgentInactive=", vm.toString(payReverts[AgentBudget.AgentInactive.selector]),
            " PayeeNotAllowed=", vm.toString(payReverts[AgentBudget.PayeeNotAllowed.selector]),
            " DuplicateRequest=", vm.toString(payReverts[AgentBudget.DuplicateRequest.selector]),
            " OverPerCallLimit=", vm.toString(payReverts[AgentBudget.OverPerCallLimit.selector]),
            " OverDailyLimit=", vm.toString(payReverts[AgentBudget.OverDailyLimit.selector])
        );
    }

    function _adminSummary() internal view returns (string memory) {
        return string.concat(
            " setPolicy=", vm.toString(successes["setPolicy"]),
            " toggleActive=", vm.toString(successes["toggleActive"]),
            " setPayee=", vm.toString(successes["setPayee"]),
            " fund=", vm.toString(successes["fund"]),
            " withdraw=", vm.toString(successes["withdraw"]),
            " warpTime=", vm.toString(successes["warpTime"]),
            " strangerAdmin_revert=", vm.toString(reverts["adminAsStranger"]),
            " strangerAdmin_ok=", vm.toString(successes["adminAsStranger"])
        );
    }
}
