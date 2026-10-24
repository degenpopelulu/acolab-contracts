// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDividend} from "./interfaces/IInternal.sol";
import {KeeperRewardAccount} from "./KeeperRewardAccount.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IPlatformTreasury {
    function platformTreasury() external view returns (address);
}

/**
 * @title TaxProcessor
 * @notice 接收税卖出来的 BNB，按 70 / 20 / 10 拆给持币人 / DEV / 平台。
 *
 * 设计要点：
 * - receive() 里只记账，不做任何外部调用，避免卖税时 gas 不够或重入。
 * - 真正的分发由 dispatch() 触发（任何人可调，机器人定时调用）。
 * - DEV 与平台都用 pull 模式领取，收款地址 revert 也不会卡住别人的流程。
 *
 * 每个币一个，EIP-1167 克隆。
 */
contract TaxProcessor is KeeperRewardAccount {
    uint256 public constant DIVIDEND_BPS = 7000;
    uint256 public constant DEV_BPS = 2000;
    uint256 public constant PLATFORM_BPS = 1000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_REWARDED_DISPATCH = 0.014 ether;
    uint256 public constant MAX_DISPATCH_REWARD = 0.0002 ether;
    uint256 public pendingKeeperBudget;

    address public token;
    address public dividend;
    address public launchpad;
    bool public initialized;

    address public devPass;
    uint256 public devPassId;
    uint256 public totalDevPaid;

    uint256 public pendingDividend;
    uint256 public devBalance;
    uint256 public platformBalance;

    uint256 public totalReceived;

    event TaxReceived(uint256 bnb);
    event Dispatched(uint256 toDividend);
    event DevWithdrawn(address indexed to, uint256 bnb);
    event PlatformWithdrawn(address indexed to, uint256 bnb);

    error AlreadyInitialized();
    error ZeroAddress();
    error NotDevPassOwner();
    error TransferFailed();


    // ---------------------------------------------------------------------
    // 初始化
    // ---------------------------------------------------------------------

    constructor() { initialized = true; }

    function initialize(address token_, address dividend_, address devPass_, uint256 devPassId_, address platformTreasury_)
        external
    {
        if (initialized) revert AlreadyInitialized();
        if (devPass_ == address(0) || platformTreasury_ == address(0)) revert ZeroAddress();

        initialized = true;
        token = token_;
        dividend = dividend_;
        launchpad = msg.sender;
        devPass = devPass_;
        devPassId = devPassId_;
    }

    function platformTreasury() public view returns (address) {
        return IPlatformTreasury(launchpad).platformTreasury();
    }

    // ---------------------------------------------------------------------
    // 收税
    // ---------------------------------------------------------------------

    /// @notice 税卖出来的 BNB 打到这里，只记账
    receive() external payable {
        uint256 v = msg.value;
        if (v == 0) return;

        uint256 dev = (v * DEV_BPS) / BPS_DENOMINATOR;
        uint256 plat = (v * PLATFORM_BPS) / BPS_DENOMINATOR;
        // 余数归分红
        uint256 div = v - dev - plat;

        devBalance += dev;
        platformBalance += plat;
        // Reserve 10% of the platform's gross share; holders and DEV keep all theirs.
        pendingKeeperBudget += plat / 10;
        pendingDividend += div;
        totalReceived += v;

        emit TaxReceived(v);
    }

    /// @notice 把待分红全部存进 Dividend（任何人可调）
    function dispatch() external nonReentrant {
        uint256 amount = pendingDividend;
        if (amount == 0) return;

        pendingDividend = 0;
        uint256 budget = pendingKeeperBudget;
        pendingKeeperBudget = 0;
        uint256 reward = amount < MIN_REWARDED_DISPATCH ? 0 : (budget < MAX_DISPATCH_REWARD ? budget : MAX_DISPATCH_REWARD);
        platformBalance -= reward;
        _rewardKeeper(msg.sender, reward);
        IDividend(dividend).deposit{value: amount}();

        emit Dispatched(amount);
    }

    // ---------------------------------------------------------------------
    // 领取
    // ---------------------------------------------------------------------

    /// @notice 把 DEV 待领发给 DevPass 当前持有人，仅持有人本人可领取
    function withdrawDev() external nonReentrant returns (uint256 amount) {
        address recipient = IERC721(devPass).ownerOf(devPassId);
        if (msg.sender != recipient) revert NotDevPassOwner();
        amount = devBalance;
        if (amount == 0) return 0;
        devBalance = 0;

        totalDevPaid += amount;
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit DevWithdrawn(recipient, amount);
    }

    /// @notice 把平台待领发给平台金库
    function withdrawPlatform() external nonReentrant returns (uint256 amount) {
        amount = platformBalance - pendingKeeperBudget;
        if (amount == 0) return 0;
        platformBalance = pendingKeeperBudget;

        address treasury = platformTreasury();
        (bool ok,) = payable(treasury).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit PlatformWithdrawn(treasury, amount);
    }

    // ---------------------------------------------------------------------
    // DevPass 收益权转让
    // ---------------------------------------------------------------------


    // ---------------------------------------------------------------------
    // 只读
    // ---------------------------------------------------------------------

    /// @notice 一次性返回前端需要的全部状态
    function snapshot()
        external
        view
        returns (
            uint256 _pendingDividend,
            uint256 _devBalance,
            uint256 _platformBalance,
            uint256 _totalReceived
        )
    {
        return (pendingDividend, devBalance, platformBalance, totalReceived);
    }
}
