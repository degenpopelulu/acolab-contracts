// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDividend, ITaxProcessor} from "./interfaces/IInternal.sol";
import {IPancakeV2Router, IWBNB} from "./interfaces/IPancake.sol";

/**
 * @title LaunchToken
 * @notice 公平发射代币。标准 ERC-20（18 位小数，总量固定 10 亿），
 *         覆写 _update 实现「毕业前锁转账 + 毕业后收税 + 分红记账」。
 *
 * 没有 owner、没有增发、没有黑名单，税率和分配比例写死为常量。
 * 每个币一个，EIP-1167 克隆。
 */
contract LaunchToken is ERC20 {
    // ------------------------------------------------------------------
    // 常量
    // ------------------------------------------------------------------

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @notice 买卖都是 1%，永久有效
    uint256 public constant TAX_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice 单次变现上限 300,000 枚（0.03%），防止一次砸盘太重
    uint256 public constant SWAP_THRESHOLD = 300_000e18;

    /// @notice 按块计时：毕业块至 +6 禁止主池买卖；+7 至 +66 限制买入后的持仓。
    uint256 public constant OPEN_LOCK_BLOCKS = 7;
    uint256 public constant LIMIT_END_BLOCKS = 67;
    uint256 public constant EARLY_MAX_WALLET = 10_000_000e18;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------------
    // 状态
    // ------------------------------------------------------------------

    address public launchpad;
    address public dividend;
    address public taxProcessor;
    address public router;
    address public wbnb;
    address public pair;
    uint256 public openBlock;

    bool public graduated;
    bool public initialized;
    bool public contractsSet;

    mapping(address => bool) public isExcludedFromTax;

    bool private _inSwap;

    string private _tokenName;
    string private _tokenSymbol;

    // ------------------------------------------------------------------
    // 事件
    // ------------------------------------------------------------------

    event TradingEnabled(address indexed pair);
    event TaxSwapped(uint256 tokensSold, uint256 bnbReceived, bool success);

    error AlreadyInitialized();
    error OnlyLaunchpad();
    error AlreadySet();
    error TransferLocked();
    error AlreadyGraduated();
    error NotOpenYet();
    error EarlyLimit();

    // ------------------------------------------------------------------
    // 初始化（克隆用）
    // ------------------------------------------------------------------

    constructor() ERC20("", "") { initialized = true; }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        address launchpad_,
        address router_,
        address wbnb_
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        _tokenName = name_;
        _tokenSymbol = symbol_;
        launchpad = launchpad_;
        router = router_;
        wbnb = wbnb_;

        // 免税名单初始化时写入
        isExcludedFromTax[launchpad_] = true;
        isExcludedFromTax[address(this)] = true;
        isExcludedFromTax[BURN_ADDRESS] = true;
    }

    /// @notice 绑定 Dividend / TaxProcessor，只能调一次
    function setContracts(address dividend_, address taxProcessor_) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (contractsSet) revert AlreadySet();
        contractsSet = true;

        dividend = dividend_;
        taxProcessor = taxProcessor_;

        isExcludedFromTax[dividend_] = true;
        isExcludedFromTax[taxProcessor_] = true;
    }

    /// @notice 初始铸造 10 亿枚给 Launchpad
    function mintInitial(address to, uint256 amount) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _mint(to, amount);
    }

    /**
     * @notice 毕业：解锁转账、开始收税，并把 pair 加入分红排除名单
     * @dev 必须在加池转账之前执行，否则 pair 收到 4 亿枚时会被登记成分红份额。
     *      注意：pair 只进「分红排除名单」，不进「免税名单」——
     *      否则 to == pair（卖出）这一侧永远收不到税。
     */
    function enableTrading(address pair_) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (graduated) revert AlreadyGraduated();

        graduated = true;
        pair = pair_;
        openBlock = block.number;
        IDividend(dividend).setExcluded(pair_, true);

        emit TradingEnabled(pair_);
    }

    /// @notice 募集失败退款时的销毁入口
    function launchpadBurn(address from, uint256 amount) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (graduated) revert AlreadyGraduated();
        _burn(from, amount);
    }

    // ------------------------------------------------------------------
    // ERC-20 元数据
    // ------------------------------------------------------------------

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    // ------------------------------------------------------------------
    // 核心：转账 / 收税 / 分红记账
    // ------------------------------------------------------------------

    function _update(address from, address to, uint256 value) internal override {
        // 铸造与销毁（销毁只能由 launchpadBurn 触发）
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            _sync(from);
            _sync(to);
            return;
        }

        // 毕业前锁转账：只允许 launchpad 发币给买家 / 加池
        if (!graduated) {
            if (from != launchpad) revert TransferLocked();
            super._update(from, to, value);
            _sync(from);
            _sync(to);
            return;
        }

        bool isBuy = from == pair;
        bool isSell = to == pair;

        uint256 tax;
        if ((isBuy || isSell) && !isExcludedFromTax[from] && !isExcludedFromTax[to]) {
            tax = (value * TAX_BPS) / BPS_DENOMINATOR;
        }

        // 仅约束登记主池的买卖。毕业注资与合约自身的税币变现必须放行；
        // 钱包互转不受影响，限购以收币地址的扣税后持仓计算。
        if ((isBuy || isSell) && from != launchpad && from != address(this)) {
            uint256 elapsed = block.number - openBlock;
            if (elapsed < OPEN_LOCK_BLOCKS) revert NotOpenYet();
            if (isBuy && elapsed < LIMIT_END_BLOCKS
                && balanceOf(to) + (value - tax) > EARLY_MAX_WALLET) revert EarlyLimit();
        }

        if (tax > 0) {
            super._update(from, address(this), tax);
        }
        // 必须在用户的净卖出到达 pair 之前变现，否则 Router 的余额差
        // 会把用户输入吞进内部 swap，导致外层卖出失败。
        if (!isBuy && !_inSwap) {
            uint256 bal = balanceOf(address(this));
            uint256 threshold = _swapThreshold();
            if (bal >= threshold) {
                _swapTax(bal, threshold);
            }
        }
        super._update(from, to, value - tax);
        _sync(from);
        _sync(to);
    }

    /// @dev 单次变现阈值。生产实现固定为 SWAP_THRESHOLD，测试可覆盖以便验证变现链路。
    function _swapThreshold() internal view virtual returns (uint256) {
        return SWAP_THRESHOLD;
    }

    /// @dev 把 from / to 的最新余额同步给 Dividend
    function _sync(address account) internal {
        if (account == address(0) || dividend == address(0)) return;
        // 免税名单与分红排除名单基本重合，跳过可省 gas；pair 另在 Dividend 侧排除
        if (isExcludedFromTax[account] || account == pair) return;
        IDividend(dividend).setShare(account, balanceOf(account));
    }

    /**
     * @dev 卖掉 min(余额, 阈值) 换成 BNB，直接发到 TaxProcessor
     *      amountOutMin = 0：单次卖出量很小，被夹的损失有限
     */
    function _swapTax(uint256 bal, uint256 threshold) internal {
        uint256 amount = bal > threshold ? threshold : bal;

        _inSwap = true;
        _approve(address(this), router, amount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnb;

        bool success;
        uint256 bnbBefore = taxProcessor.balance;
        try IPancakeV2Router(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, path, taxProcessor, block.timestamp
        ) {
            success = true;
        } catch {
            // 变现失败不影响转账本身，税继续留在合约里等下次
            success = false;
        }

        _inSwap = false;
        // 清掉残留授权
        _approve(address(this), router, 0);

        emit TaxSwapped(amount, success ? taxProcessor.balance - bnbBefore : 0, success);
    }

    // ------------------------------------------------------------------
    // 只读
    // ------------------------------------------------------------------

    function isInSwap() external view returns (bool) {
        return _inSwap;
    }

    /// @return phase 0=未毕业，1=锁定，2=限购，3=放开。
    /// @return blocksLeft 当前阶段剩余块数；约秒数仅供链下估算。
    function tradingPhase() external view returns (uint8 phase, uint256 blocksLeft) {
        if (!graduated) return (0, 0);
        uint256 elapsed = block.number - openBlock;
        if (elapsed < OPEN_LOCK_BLOCKS) return (1, OPEN_LOCK_BLOCKS - elapsed);
        if (elapsed < LIMIT_END_BLOCKS) return (2, LIMIT_END_BLOCKS - elapsed);
        return (3, 0);
    }

    function tokenState()
        external
        view
        returns (
            bool _graduated,
            address _pair,
            address _dividend,
            address _taxProcessor,
            uint256 _taxBalance
        )
    {
        return (graduated, pair, dividend, taxProcessor, balanceOf(address(this)));
    }

    receive() external payable {
        revert("NO_DIRECT_BNB");
    }
}
