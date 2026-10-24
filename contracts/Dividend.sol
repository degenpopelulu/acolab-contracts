// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Dividend
 * @notice 单币分红池。用「每股累计收益」（accPerShare）记账，存入时不需要遍历持币人。
 *
 *   accPerShare += deposit * 2^128 / totalShares
 *   withdrawable(u) = share_u * accPerShare / 2^128 - rewardDebt_u + pending_u
 *
 * 每次份额变化或领取时，先把已产生的收益结算进 pending，
 * 再把 rewardDebt 设为 新份额 * accPerShare / 2^128。
 * 这样后买入的人拿不到买入前的分红，卖掉的人也不会丢掉已经产生的分红。
 *
 * 每个币一个，EIP-1167 克隆。
 */
contract Dividend is ReentrancyGuard {
    uint256 private constant Q128 = 1 << 128;

    /// @notice 参与分红的最低持仓：1 份 = 100,000 枚
    uint256 public constant MIN_SHARE_BALANCE = 100_000e18;

    address public token;
    address public taxProcessor;
    address public launchpad;
    bool public initialized;

    /// @notice 每股累计收益（Q128 定点）
    uint256 public accPerShare;
    /// @notice 当前有效份额总和
    uint256 public totalShares;
    /// @notice totalShares 为 0 时暂存的待分配 BNB
    uint256 public undistributed;

    mapping(address => uint256) public share;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pending;
    mapping(address => bool) public isExcluded;

    uint256 public totalDeposited;
    uint256 public totalClaimed;

    event Deposited(uint256 bnb, uint256 accPerShare);
    event ShareSet(address indexed user, uint256 shares);
    event Claimed(address indexed user, uint256 bnb, address indexed caller);
    event ExcludedSet(address indexed account, bool excluded);

    error OnlyToken();
    error OnlyTaxProcessor();
    error AlreadyInitialized();
    error TransferFailed();

    modifier onlyToken() {
        if (msg.sender != token) revert OnlyToken();
        _;
    }

    modifier onlyTaxProcessor() {
        if (msg.sender != taxProcessor) revert OnlyTaxProcessor();
        _;
    }

    // ---------------------------------------------------------------------
    // 初始化
    // ---------------------------------------------------------------------

    constructor() { initialized = true; }

    function initialize(address token_, address launchpad_) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        token = token_;
        launchpad = launchpad_;

        // 永久排除名单
        isExcluded[token_] = true;
        isExcluded[launchpad_] = true;
        isExcluded[address(this)] = true;
        isExcluded[address(0)] = true;
        isExcluded[0x000000000000000000000000000000000000dEaD] = true;
    }

    function setTaxProcessor(address taxProcessor_) external {
        require(msg.sender == launchpad, "ONLY_LAUNCHPAD");
        require(taxProcessor == address(0), "ALREADY_SET");
        taxProcessor = taxProcessor_;
        isExcluded[taxProcessor_] = true;
    }

    // ---------------------------------------------------------------------
    // 份额维护（只有 Token 能调，每次余额变化都会调用）
    // ---------------------------------------------------------------------

    /**
     * @notice 更新某地址的分红份额
     * @dev 余额 >= MIN_SHARE_BALANCE 且不在排除名单时份额 = 余额，否则为 0
     */
    function setShare(address user, uint256 balance) external onlyToken {
        _setShare(user, balance);
    }

    function _setShare(address user, uint256 balance) internal {
        uint256 oldShare = share[user];

        if (oldShare > 0) {
            pending[user] += (oldShare * accPerShare) / Q128 - rewardDebt[user];
        }

        uint256 newShare = (balance >= MIN_SHARE_BALANCE && !isExcluded[user]) ? balance : 0;

        if (newShare != oldShare) {
            totalShares = totalShares - oldShare + newShare;
            share[user] = newShare;
            emit ShareSet(user, newShare);
        }

        rewardDebt[user] = (newShare * accPerShare) / Q128;
    }

    /// @notice 把地址加入/移出分红排除名单（毕业时把 pair 加进来）
    function setExcluded(address account, bool excluded) external onlyToken {
        isExcluded[account] = excluded;
        if (excluded) {
            _setShare(account, 0);
        }
        emit ExcludedSet(account, excluded);
    }

    // ---------------------------------------------------------------------
    // 存入
    // ---------------------------------------------------------------------

    /**
     * @notice 只有 TaxProcessor 能调，把待分红 BNB 存进来
     * @dev totalShares == 0 时先记入 undistributed，下次存入时一起分
     */
    function deposit() external payable onlyTaxProcessor {
        require(msg.value > 0, "ZERO");
        totalDeposited += msg.value;

        if (totalShares == 0) {
            undistributed += msg.value;
            emit Deposited(msg.value, accPerShare);
            return;
        }

        uint256 amount = msg.value + undistributed;
        undistributed = 0;
        accPerShare += (amount * Q128) / totalShares;

        emit Deposited(msg.value, accPerShare);
    }

    // ---------------------------------------------------------------------
    // 查询与领取
    // ---------------------------------------------------------------------

    function withdrawableOf(address user) public view returns (uint256) {
        uint256 s = share[user];
        if (s == 0 && pending[user] == 0) return 0;
        return (s * accPerShare) / Q128 - rewardDebt[user] + pending[user];
    }

    /// @notice 自己领
    function withdraw() external nonReentrant returns (uint256 amount) {
        return _claim(msg.sender);
    }

    /// @notice 任何人替别人领，钱只会发到 user，调用者只出 gas
    function withdrawFor(address user) external nonReentrant returns (uint256 amount) {
        return _claim(user);
    }

    /**
     * @notice 批量替领，给机器人用
     * @dev 单个地址发送失败（合约拒收）时保留其余额，不影响其他人
     */
    function distribute(address[] calldata users) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < users.length; ++i) {
            address u = users[i];
            uint256 amount = withdrawableOf(u);
            if (amount == 0) continue;

            uint256 oldPending = pending[u];
            uint256 oldDebt = rewardDebt[u];
            pending[u] = 0;
            rewardDebt[u] = (share[u] * accPerShare) / Q128;
            (bool ok,) = payable(u).call{value: amount}("");
            if (!ok) {
                pending[u] = oldPending;
                rewardDebt[u] = oldDebt;
                continue;
            }
            totalClaimed += amount;
            total += amount;
            emit Claimed(u, amount, msg.sender);
        }
    }

    function _claim(address user) internal returns (uint256 amount) {
        amount = withdrawableOf(user);
        if (amount == 0) return 0;

        // 先记账再转账；转账失败则整体 revert，状态自动回滚
        pending[user] = 0;
        rewardDebt[user] = (share[user] * accPerShare) / Q128;
        totalClaimed += amount;

        (bool ok,) = payable(user).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Claimed(user, amount, msg.sender);
    }

    receive() external payable {
        revert("NO_DIRECT_BNB");
    }
}
