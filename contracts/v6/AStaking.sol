// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./Types.sol";

contract AStaking is V6Component, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant DURATION = 48 hours;
    uint256 public constant EXIT_DELAY = 7 days;
    uint256 private constant Q = 1e27;
    uint256 public totalStaked;
    uint256 public totalPrincipal;
    uint256 public reservedRewards;
    uint256 public rewardPerToken;
    uint256 public budget;
    uint256 public elapsedActive;
    uint256 public lastUpdate;
    uint256 public trancheEnd;
    uint256 public undistributed;
    bool public paused;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public waiting;
    mapping(address => uint256) public unlockAt;
    mapping(address => uint256) public userIndex;
    mapping(address => uint256) public rewards;
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 unlockAt);
    event UnstakeCancelled(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event TrancheStarted(uint256 indexed tier, uint256 amount, uint256 end);
    event TranchePaused(bool value);

    function initialize(V6Addresses calldata c, address p) external { _initialize(c, p); }
    function ownedPrincipal(address user) external view returns (uint256) { return staked[user] + waiting[user]; }
    function _elapsed() private view returns (uint256) {
        if (budget == 0 || paused) return elapsedActive;
        return Math.min(DURATION, elapsedActive + block.timestamp - lastUpdate);
    }
    function trancheFinished() public view returns (bool) { return budget == 0 || _elapsed() == DURATION; }
    function _checkpoint(address user) private {
        uint256 next = _elapsed();
        uint256 emission = Math.mulDiv(budget, next, DURATION) - Math.mulDiv(budget, elapsedActive, DURATION);
        elapsedActive = next; lastUpdate = block.timestamp;
        if (emission != 0) {
            if (totalStaked == 0) undistributed += emission;
            else rewardPerToken += Math.mulDiv(emission, Q, totalStaked);
        }
        if (user != address(0)) {
            rewards[user] += Math.mulDiv(staked[user], rewardPerToken - userIndex[user], Q);
            userIndex[user] = rewardPerToken;
        }
    }
    function earned(address user) external view returns (uint256) {
        uint256 emission = Math.mulDiv(budget, _elapsed(), DURATION) - Math.mulDiv(budget, elapsedActive, DURATION);
        uint256 index = rewardPerToken + (totalStaked == 0 ? 0 : Math.mulDiv(emission, Q, totalStaked));
        return rewards[user] + Math.mulDiv(staked[user], index - userIndex[user], Q);
    }
    function _notify(address user) private {
        IV6Dividend(components.dividend).onStakeChange(user, staked[user] + waiting[user]);
    }
    function pendingUndistributed() external view returns (uint256) {
        if (totalStaked != 0) return undistributed;
        return undistributed + Math.mulDiv(budget, _elapsed(), DURATION)
            - Math.mulDiv(budget, elapsedActive, DURATION);
    }
    function stake(uint256 amount) external nonReentrant {
        require(IV6Token(components.token).tradingOpen() && amount != 0, "STAKE_CLOSED");
        _checkpoint(msg.sender);
        staked[msg.sender] += amount; totalStaked += amount; totalPrincipal += amount;
        require(staked[msg.sender] >= MINIMUM, "MINIMUM");
        IERC20(components.token).safeTransferFrom(msg.sender, address(this), amount);
        _notify(msg.sender);
        emit Staked(msg.sender, amount);
    }
    function requestUnstake(uint256 amount) external nonReentrant {
        require(amount != 0 && staked[msg.sender] >= amount, "AMOUNT");
        _checkpoint(msg.sender);
        staked[msg.sender] -= amount; totalStaked -= amount; waiting[msg.sender] += amount;
        require(staked[msg.sender] == 0 || staked[msg.sender] >= MINIMUM, "MINIMUM");
        unlockAt[msg.sender] = block.timestamp + EXIT_DELAY;
        _notify(msg.sender);
        emit UnstakeRequested(msg.sender, amount, unlockAt[msg.sender]);
    }
    function cancelUnstake() external nonReentrant {
        _checkpoint(msg.sender);
        uint256 amount = waiting[msg.sender]; require(amount != 0, "NO_WAIT");
        waiting[msg.sender] = 0; unlockAt[msg.sender] = 0;
        staked[msg.sender] += amount; totalStaked += amount;
        require(staked[msg.sender] >= MINIMUM, "MINIMUM");
        _notify(msg.sender);
        emit UnstakeCancelled(msg.sender, amount);
    }
    function withdraw() external nonReentrant {
        uint256 amount = waiting[msg.sender];
        require(amount != 0 && block.timestamp >= unlockAt[msg.sender], "EXIT_DELAY");
        _checkpoint(msg.sender);
        waiting[msg.sender] = 0; unlockAt[msg.sender] = 0; totalPrincipal -= amount;
        IERC20(components.token).safeTransfer(msg.sender, amount); _notify(msg.sender);
        emit Withdrawn(msg.sender, amount);
    }
    function claimRewards() external nonReentrant {
        _checkpoint(msg.sender);
        uint256 amount = rewards[msg.sender]; rewards[msg.sender] = 0;
        reservedRewards -= amount;
        IERC20(components.token).safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }
    function startTranche(uint256 amount, uint256 tier) external {
        require(msg.sender == components.release && amount != 0 && trancheFinished(), "RELEASE_ONLY");
        _checkpoint(address(0));
        require(IERC20(components.token).balanceOf(address(this)) >= totalPrincipal + reservedRewards + amount, "UNFUNDED");
        budget = amount; reservedRewards += amount; elapsedActive = 0;
        lastUpdate = block.timestamp; trancheEnd = block.timestamp + DURATION; paused = false;
        emit TrancheStarted(tier, amount, trancheEnd);
    }
    function setPaused(bool value) external {
        require(msg.sender == components.release, "RELEASE_ONLY");
        if (paused == value || trancheFinished()) return;
        _checkpoint(address(0));
        paused = value;
        if (!value) trancheEnd = block.timestamp + DURATION - elapsedActive;
        emit TranchePaused(value);
    }
    function returnUndistributed() external nonReentrant returns (uint256 amount) {
        require(msg.sender == components.release && trancheFinished(), "NOT_FINISHED");
        _checkpoint(address(0));
        amount = undistributed; undistributed = 0; reservedRewards -= amount;
        if (amount != 0) IERC20(components.token).safeTransfer(components.release, amount);
    }
}
