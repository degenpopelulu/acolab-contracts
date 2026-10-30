// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./Types.sol";

contract ADividend is V6Component, ReentrancyGuard {
    uint256 private constant Q = 1 << 128;
    uint256 public accPerShare;
    uint256 public totalShares;
    uint256 public undistributed;
    uint256 public totalDeposited;
    uint256 public totalClaimed;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public debt;
    mapping(address => uint256) public pending;
    mapping(address => bool) public excluded;
    event Deposited(uint256 amount, uint256 totalShares);
    event SharesUpdated(address indexed account, uint256 shares);
    event DividendClaimed(address indexed account, address indexed to, uint256 amount);

    function initialize(V6Addresses calldata c, address p, address initialTreasury) external {
        _initialize(c, p);
        excluded[address(0)] = true; excluded[DEAD] = true; excluded[c.token] = true;
        excluded[c.auction] = true; excluded[c.opening] = true; excluded[c.locker] = true;
        excluded[c.release] = true; excluded[c.staking] = true; excluded[address(this)] = true;
        excluded[initialTreasury] = true;
        excluded[IV6Platform(p).devPass()] = true;
    }
    function onBalanceChange(address account, uint256) external {
        require(msg.sender == components.token, "TOKEN_ONLY"); _sync(account);
    }
    function onStakeChange(address account, uint256) external {
        require(msg.sender == components.staking, "STAKE_ONLY"); _sync(account);
    }
    function sync(address account) external { _sync(account); }
    function _sync(address account) private {
        uint256 old = shares[account];
        pending[account] += Math.mulDiv(old, accPerShare, Q) - debt[account];
        uint256 value;
        if (!excluded[account] && account != IV6Token(components.token).pair()) {
            value = IERC20(components.token).balanceOf(account)
                + IV6Staking(components.staking).ownedPrincipal(account);
            if (value < MINIMUM) value = 0;
        }
        totalShares = totalShares - old + value;
        shares[account] = value;
        debt[account] = Math.mulDiv(value, accPerShare, Q);
        IV6Token(components.token).clearDirty(account);
        emit SharesUpdated(account, value);
        if (totalShares != 0 && undistributed != 0 && IV6Token(components.token).dirtyCount() == 0) {
            uint256 amount = undistributed; undistributed = 0;
            accPerShare += Math.mulDiv(amount, Q, totalShares);
        }
    }
    function deposit() external payable {
        require(IV6Token(components.token).tradingOpen(), "NOT_OPEN");
        require(msg.sender == components.token || msg.sender == IV6Platform(platform).treasury(), "DEPOSIT_SOURCE");
        // Never distribute against stale balances after a failed transfer hook.
        require(IV6Token(components.token).dirtyCount() == 0, "SYNC_REQUIRED");
        totalDeposited += msg.value;
        uint256 amount = msg.value + undistributed;
        if (totalShares == 0) undistributed = amount;
        else { undistributed = 0; accPerShare += Math.mulDiv(amount, Q, totalShares); }
        emit Deposited(msg.value, totalShares);
    }
    function claimable(address account) public view returns (uint256) {
        return pending[account] + Math.mulDiv(shares[account], accPerShare, Q) - debt[account];
    }
    function claim(address payable to) external nonReentrant {
        require(to != address(0), "ZERO_TO");
        _sync(msg.sender);
        uint256 amount = claimable(msg.sender);
        pending[msg.sender] = 0;
        debt[msg.sender] = Math.mulDiv(shares[msg.sender], accPerShare, Q);
        totalClaimed += amount;
        (bool ok,) = to.call{value: amount}(""); require(ok, "PAYMENT_FAILED");
        emit DividendClaimed(msg.sender, to, amount);
    }
}
