// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Earned BNB is claimed separately so a rejecting executor never blocks a task.
abstract contract KeeperRewardAccount is ReentrancyGuard {
    mapping(address => uint256) public keeperRewards;
    event KeeperRewardAccrued(address indexed keeper, uint256 amount);
    event KeeperRewardClaimed(address indexed keeper, address indexed recipient, uint256 amount);
    error BadKeeperClaim();

    function _rewardKeeper(address keeper, uint256 amount) internal {
        if (amount == 0) return;
        keeperRewards[keeper] += amount;
        emit KeeperRewardAccrued(keeper, amount);
    }

    function claimKeeperReward(address payable recipient) external nonReentrant returns (uint256 amount) {
        amount = keeperRewards[msg.sender];
        if (amount == 0 || recipient == address(0)) revert BadKeeperClaim();
        keeperRewards[msg.sender] = 0;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert BadKeeperClaim();
        emit KeeperRewardClaimed(msg.sender, recipient, amount);
    }
}
