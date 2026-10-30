// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./Types.sol";

contract ARelease is V6Component, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public nextTier;
    uint256 public activeTier;
    bool public cancelled;
    event TierStarted(uint256 indexed tier, uint256 marketCapUsd, uint256 amount, uint256 circulating);
    event UndistributedReturned(uint256 amount);
    function initialize(V6Addresses calldata c, address p) external { _initialize(c, p); }
    function tiers(uint256 i) public pure returns (uint256) {
        require(i < 33, "TIER");
        if (i < 6) {
            uint256[6] memory first = [uint256(50_000), 100_000, 200_000, 400_000, 600_000, 1_000_000];
            return first[i] * 1e8;
        }
        if (i < 15) return (i - 4) * 1_000_000 * 1e8;
        return (15_000_000 + (i - 15) * 5_000_000) * 1e8;
    }
    function circulating() public view returns (uint256) {
        return SUPPLY - IERC20(components.token).balanceOf(address(this))
            - IERC20(components.token).balanceOf(DEAD)
            - IV6Staking(components.staking).reservedRewards();
    }
    function _return() private {
        uint256 returned = IV6Staking(components.staking).returnUndistributed();
        if (returned != 0) emit UndistributedReturned(returned);
    }
    function startNextTier() external nonReentrant { require(_start(), "TIER_NOT_READY"); }
    function _start() private returns (bool) {
        IV6Staking staking = IV6Staking(components.staking);
        if (cancelled || !IV6Token(components.token).tradingOpen() || !staking.trancheFinished()) return false;
        _return();
        uint256 index = nextTier < 33 ? nextTier : 32;
        (bool valid, uint256 cap) = IV6Oracle(components.oracle).marketCap();
        if (!valid || cap < tiers(index) || staking.totalStaked() == 0) return false;
        uint256 remaining = IERC20(components.token).balanceOf(address(this));
        uint256 circ = circulating();
        uint256 amount = index == 32 ? remaining : Math.min(remaining, circ * 15 / 100);
        if (amount == 0) return false;
        activeTier = index; if (nextTier < 33) ++nextTier;
        IERC20(components.token).safeTransfer(components.staking, amount);
        staking.startTranche(amount, index);
        emit TierStarted(index, cap, amount, circ);
        return true;
    }
    function poke() external nonReentrant {
        if (cancelled || !IV6Token(components.token).tradingOpen()) return;
        IV6Staking staking = IV6Staking(components.staking);
        if (staking.trancheFinished()) { _start(); return; }
        (bool valid, uint256 cap) = IV6Oracle(components.oracle).marketCap();
        if (valid) staking.setPaused(cap < tiers(activeTier) * 80 / 100);
    }
    function cancel() external {
        require(msg.sender == components.opening && !IV6Token(components.token).tradingOpen(), "OPENING_ONLY");
        cancelled = true;
        IERC20(components.token).safeTransfer(DEAD, IERC20(components.token).balanceOf(address(this)));
    }
}
