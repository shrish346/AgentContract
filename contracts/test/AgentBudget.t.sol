// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBudget} from "../src/AgentBudget.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract AgentBudgetTest is Test {
    AgentBudget vault;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address payee = makeAddr("payee");
    address stranger = makeAddr("stranger");

    uint128 constant PER_CALL = 1e6; // 1 USDC
    uint128 constant DAILY = 12e6; // 12 USDC
    uint256 constant VAULT_BAL = 1_000e6;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        vault = new AgentBudget(usdc);
        usdc.mint(address(vault), VAULT_BAL);
        vault.setPolicy(agent, PER_CALL, DAILY);
        vault.setPayee(payee, true);
        vm.stopPrank();

        // Pin to a known timestamp mid-day so warps are predictable.
        vm.warp(1_700_000_000);
    }

    function _pay(uint256 amount, bytes32 rid) internal {
        vm.prank(agent);
        vault.pay(payee, amount, rid);
    }

    // ------------------------------------------------------------ R1 criteria

    function test_paySucceedsAndEmits() public {
        bytes32 rid = keccak256("req-1");

        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentBudget.Paid(agent, payee, PER_CALL, rid);
        _pay(PER_CALL, rid);

        assertEq(usdc.balanceOf(payee), PER_CALL);
        assertEq(usdc.balanceOf(address(vault)), VAULT_BAL - PER_CALL);
        assertEq(vault.remainingToday(agent), DAILY - PER_CALL);
        assertTrue(vault.usedRequestId(rid));
    }

    function test_revertsOverPerCallLimit() public {
        vm.expectRevert(AgentBudget.OverPerCallLimit.selector);
        _pay(PER_CALL + 1, keccak256("req-1"));

        assertEq(usdc.balanceOf(payee), 0);
        assertEq(vault.remainingToday(agent), DAILY);
    }

    function test_revertsOverDailyLimit() public {
        // Spend 12 × 1 USDC = exactly the daily max.
        for (uint256 i = 0; i < 12; i++) {
            _pay(PER_CALL, keccak256(abi.encode("req", i)));
        }
        assertEq(vault.remainingToday(agent), 0);

        // 13th is refused by the contract.
        vm.expectRevert(AgentBudget.OverDailyLimit.selector);
        _pay(PER_CALL, keccak256("req-13"));
    }

    function test_dailyCounterResetsAtUtcDay() public {
        for (uint256 i = 0; i < 12; i++) {
            _pay(PER_CALL, keccak256(abi.encode("req", i)));
        }
        assertEq(vault.remainingToday(agent), 0);

        // Warp to the first second of the next UTC day.
        uint256 nextDay = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(nextDay);

        assertEq(vault.remainingToday(agent), DAILY);
        _pay(PER_CALL, keccak256("req-next-day"));
        assertEq(vault.remainingToday(agent), DAILY - PER_CALL);
    }

    function test_setPolicyRevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(AgentBudget.NotOwner.selector);
        vault.setPolicy(stranger, PER_CALL, DAILY);
    }

    function test_revertsDuplicateRequest() public {
        bytes32 rid = keccak256("req-1");
        _pay(PER_CALL, rid);

        vm.expectRevert(AgentBudget.DuplicateRequest.selector);
        _pay(PER_CALL, rid);
    }

    // ---------------------------------------------------------- extra guards

    function test_revertsUnlistedPayee() public {
        vm.prank(agent);
        vm.expectRevert(AgentBudget.PayeeNotAllowed.selector);
        vault.pay(stranger, PER_CALL, keccak256("req-1"));
    }

    function test_revertsAfterRevoke() public {
        vm.prank(owner);
        vault.revokeAgent(agent);

        vm.expectRevert(AgentBudget.AgentInactive.selector);
        _pay(PER_CALL, keccak256("req-1"));
        assertEq(vault.remainingToday(agent), 0);
    }

    function test_unregisteredAgentCannotPay() public {
        vm.prank(stranger);
        vm.expectRevert(AgentBudget.AgentInactive.selector);
        vault.pay(payee, PER_CALL, keccak256("req-1"));
    }

    function test_dailyLimitBoundaryIsInclusive() public {
        // perCall == daily: a single call for the full daily amount is allowed.
        vm.prank(owner);
        vault.setPolicy(agent, DAILY, DAILY);
        _pay(DAILY, keccak256("req-1"));
        assertEq(vault.remainingToday(agent), 0);
    }

    function test_ownerOnlyAdmin() public {
        vm.startPrank(stranger);
        vm.expectRevert(AgentBudget.NotOwner.selector);
        vault.setPayee(stranger, true);
        vm.expectRevert(AgentBudget.NotOwner.selector);
        vault.revokeAgent(agent);
        vm.expectRevert(AgentBudget.NotOwner.selector);
        vault.withdraw(stranger, 1);
        vm.stopPrank();
    }

    function test_ownerCanWithdraw() public {
        vm.prank(owner);
        vault.withdraw(owner, VAULT_BAL);
        assertEq(usdc.balanceOf(owner), VAULT_BAL);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------ R2 criteria

    function test_mockUsdcDecimals() public view {
        assertEq(usdc.decimals(), 6);
    }
}
