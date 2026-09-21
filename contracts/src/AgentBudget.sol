// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AgentBudget
/// @notice Holds an operator's USDC and lets registered agents spend it under
///         per-call and per-day limits. Agents only have a key, but they can never make payment.
contract AgentBudget {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    struct Policy {
        uint128 perCallMax; // max amount for a single pay() call
        uint128 dailyMax; // max cumulative amount per UTC day
        bool active; // false = revoked or never registered
    }

    struct Spend {
        uint128 spent; // amount spent in `day`
        uint64 day; // block.timestamp / 1 days at last write
    }

    // --------------------------------------------------------------- errors

    error NotOwner();
    error AgentInactive();
    error PayeeNotAllowed();
    error DuplicateRequest();
    error OverPerCallLimit();
    error OverDailyLimit();
    error ZeroAddress();

    // --------------------------------------------------------------- events

    event PolicySet(
        address indexed agent,
        uint128 perCallMax,
        uint128 dailyMax
    );
    event AgentRevoked(address indexed agent);
    event PayeeSet(address indexed payee, bool allowed);
    event Withdrawn(address indexed to, uint256 amount);
    event Paid(
        address indexed agent,
        address indexed payee,
        uint256 amount,
        bytes32 indexed requestId
    );

    // -------------------------------------------------------------- storage

    address public immutable owner;
    IERC20 public immutable token;

    mapping(address agent => Policy) public policies;
    mapping(address agent => Spend) internal spends;
    mapping(address payee => bool) public allowedPayee;
    mapping(bytes32 requestId => bool) public usedRequestId;

    // ------------------------------------------------------------ modifiers

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------- constructor

    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        owner = msg.sender;
        token = token_;
    }

    // ---------------------------------------------------------- owner admin

    function setPolicy(
        address agent,
        uint128 perCallMax,
        uint128 dailyMax
    ) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        policies[agent] = Policy({
            perCallMax: perCallMax,
            dailyMax: dailyMax,
            active: true
        });
        emit PolicySet(agent, perCallMax, dailyMax);
    }

    function revokeAgent(address agent) external onlyOwner {
        policies[agent].active = false;
        emit AgentRevoked(agent);
    }

    function setPayee(address payee, bool allowed) external onlyOwner {
        if (payee == address(0)) revert ZeroAddress();
        allowedPayee[payee] = allowed;
        emit PayeeSet(payee, allowed);
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    // ----------------------------------------------------------- agent pay

    /// @notice Pay `amount` of `token` to `payee` on behalf of the calling agent.
    /// @param requestId Unique id issued by the service for this specific request.
    ///        Enforced single-use so one payment cannot be replayed.
    function pay(address payee, uint256 amount, bytes32 requestId) external {
        Policy memory p = policies[msg.sender];

        if (!p.active) revert AgentInactive();
        if (!allowedPayee[payee]) revert PayeeNotAllowed();
        if (usedRequestId[requestId]) revert DuplicateRequest();
        if (amount > p.perCallMax) revert OverPerCallLimit();

        Spend storage s = spends[msg.sender];
        uint64 today = _currentDay();
        uint256 spentToday = s.day == today ? s.spent : 0;
        if (spentToday + amount > p.dailyMax) revert OverDailyLimit();

        // Effects before interaction.
        usedRequestId[requestId] = true;
        s.day = today;
        s.spent = uint128(spentToday + amount); // safe: <= dailyMax which is uint128

        token.safeTransfer(payee, amount);

        emit Paid(msg.sender, payee, amount, requestId);
    }

    // ---------------------------------------------------------------- views

    /// @notice Amount the agent may still spend before the next UTC day boundary.
    function remainingToday(address agent) external view returns (uint256) {
        Policy memory p = policies[agent];
        if (!p.active) return 0;
        Spend memory s = spends[agent];
        uint256 spentToday = s.day == _currentDay() ? s.spent : 0;
        return spentToday >= p.dailyMax ? 0 : p.dailyMax - spentToday;
    }

    /// @notice Raw spend record; exposed for off-chain inspection.
    function spendOf(
        address agent
    ) external view returns (uint128 spent, uint64 day) {
        Spend memory s = spends[agent];
        return (s.spent, s.day);
    }

    // ------------------------------------------------------------ internal

    function _currentDay() internal view returns (uint64) {
        return uint64(block.timestamp / 1 days);
    }
}
