// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Types.sol";

contract AToken is ERC20, V6Component, ReentrancyGuard {
    uint256 public constant TAX_BPS = 150;
    uint256 public constant HOLDER_BPS = 7000;
    uint256 public constant DEV_BPS = 2000;
    uint256 public constant PLATFORM_BPS = 1000;
    uint256 public constant DIVIDEND_HOOK_GAS = 200_000;
    uint256 public constant SWAP_THRESHOLD = 10_000e18;
    uint256 public constant EARLY_MAX_WALLET = 100_000e18;
    address public pair;
    address public router;
    address public wbnb;
    string private displayName;
    string private displaySymbol;
    bool public tradingOpen;
    uint256 public openBlock;
    uint256 public openTimestamp;
    bool private inSwap;
    mapping(address => bool) public taxExempt;
    mapping(address => bool) public dirty;
    uint256 public dirtyCount;
    mapping(address => uint256) public platformCredit;
    uint256 public pendingDividend;
    address public devPass;
    uint256 public devPassId;
    uint256 public devCredit;
    uint256 public devEarnedTotal;
    uint256 public devClaimedTotal;

    event TradingOpened(uint256 blockNumber);
    event SwapBack(uint256 tokensIn, uint256 bnbOut);
    event SwapBackFailed(uint256 tokensIn);
    event DividendHookFailed(address indexed account);
    event DividendDeferred(uint256 amount);
    event PlatformWithdrawn(address indexed owner, address indexed to, uint256 amount);
    event RevenueSplit(uint256 holders, uint256 dev, uint256 platformFee);
    event DevWithdrawn(address indexed owner, address indexed to, uint256 amount);

    constructor() ERC20("", "") {}
    function name() public view override returns (string memory) { return displayName; }
    function symbol() public view override returns (string memory) { return displaySymbol; }
    function initialize(V6Addresses calldata c, address p, string calldata n, string calldata s,
        address r, address w) external
    {
        _initialize(c, p);
        displayName = n; displaySymbol = s; router = r; wbnb = w;
        devPass = IV6Platform(p).devPass();
        devPassId = IV6DevPass(devPass).idOf(address(this));
        require(devPassId != 0 && IV6DevPass(devPass).minterOf(devPassId) == p, "DEVPASS");
        address f = IV6Router(r).factory();
        pair = IV6Factory(f).getPair(address(this), w);
        if (pair == address(0)) pair = IV6Factory(f).createPair(address(this), w);
        taxExempt[address(this)] = true;
        taxExempt[c.auction] = true; taxExempt[c.opening] = true; taxExempt[c.locker] = true;
        taxExempt[c.release] = true; taxExempt[c.staking] = true; taxExempt[c.dividend] = true;
        _mint(c.auction, 8_000_000e18);
        _mint(c.opening, 2_000_000e18);
        _mint(c.release, 990_000_000e18);
    }
    function openTrading() external {
        require(msg.sender == components.opening && !tradingOpen, "OPENING_ONLY");
        tradingOpen = true; openBlock = block.number; openTimestamp = block.timestamp;
        emit TradingOpened(block.number);
    }
    function clearDirty(address account) external {
        require(msg.sender == components.dividend, "DIVIDEND_ONLY");
        if (dirty[account]) { dirty[account] = false; --dirtyCount; }
    }
    function _notify(address account) private {
        if (account == address(0)) return;
        try IV6Dividend(components.dividend).onBalanceChange{gas: DIVIDEND_HOOK_GAS}(account, balanceOf(account)) {
            if (dirty[account]) { dirty[account] = false; --dirtyCount; }
        } catch {
            if (!dirty[account]) { dirty[account] = true; ++dirtyCount; }
            emit DividendHookFailed(account);
        }
    }
    function _update(address from, address to, uint256 value) internal override {
        // V2 skim always calls transfer, even for the zero A-side surplus.
        if (value != 0 && pair != address(0) && (from == pair || to == pair)) {
            if (!tradingOpen) require(from == components.opening && to == pair, "PAIR_LOCKED");
            if (tradingOpen && from == pair && !taxExempt[to]) {
                require(block.number >= openBlock + 7, "OPEN_LOCK");
                uint256 net = value - value * TAX_BPS / 10_000;
                if (block.number < openBlock + 67)
                    require(balanceOf(to) + net <= EARLY_MAX_WALLET, "EARLY_LIMIT");
            }
        }
        bool taxable = tradingOpen && !inSwap && (from == pair || to == pair)
            && !taxExempt[from] && !taxExempt[to];
        if (taxable && to == pair && balanceOf(address(this)) >= SWAP_THRESHOLD) _swapBack();
        uint256 tax = taxable ? value * TAX_BPS / 10_000 : 0;
        if (tax != 0) super._update(from, address(this), tax);
        super._update(from, to, value - tax);
        _notify(from);
        if (to != from) _notify(to);
    }
    function swapBack() external { require(!inSwap && tradingOpen, "SWAP_STATE"); _swapBack(); }
    function _swapBack() private {
        uint256 amount = Math.min(balanceOf(address(this)), balanceOf(pair) * 5 / 1000);
        if (balanceOf(address(this)) < SWAP_THRESHOLD || amount == 0) return;
        inSwap = true;
        try this.executeSwap(amount) {} catch { emit SwapBackFailed(amount); }
        inSwap = false;
    }
    function executeSwap(uint256 amount) external {
        require(msg.sender == address(this) && inSwap, "SELF_ONLY");
        address[] memory route = new address[](2);
        route[0] = address(this); route[1] = wbnb;
        uint256 beforeBnb = address(this).balance;
        _approve(address(this), router, amount);
        uint256[] memory quote = IV6Router(router).getAmountsOut(amount, route);
        IV6Router(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, quote[1] * 95 / 100, route, address(this), block.timestamp
        );
        _approve(address(this), router, 0);
        uint256 received = address(this).balance - beforeBnb;
        uint256 holders = received * HOLDER_BPS / 10_000;
        uint256 dev = received * DEV_BPS / 10_000;
        uint256 fee = received - holders - dev; // Integer-rounding dust goes to the platform.
        platformCredit[IV6Platform(platform).treasury()] += fee;
        devCredit += dev; devEarnedTotal += dev;
        pendingDividend += holders;
        emit SwapBack(amount, received);
        emit RevenueSplit(holders, dev, fee);
        _dispatch();
    }
    function dispatchDividend() external { require(!inSwap, "IN_SWAP"); _dispatch(); }
    function _dispatch() private {
        uint256 amount = pendingDividend;
        if (amount == 0) return;
        pendingDividend = 0;
        try IV6Dividend(components.dividend).deposit{value: amount}() {} catch {
            pendingDividend = amount;
            emit DividendDeferred(amount);
        }
    }
    function withdrawDev(address payable to) external nonReentrant {
        require(msg.sender == IV6DevPass(devPass).ownerOf(devPassId), "DEVPASS_OWNER_ONLY");
        uint256 amount = devCredit; require(amount != 0 && to != address(0), "NO_CREDIT");
        devCredit = 0; devClaimedTotal += amount;
        (bool ok,) = to.call{value: amount}(""); require(ok, "PAYMENT_FAILED");
        emit DevWithdrawn(msg.sender, to, amount);
    }
    function withdrawPlatform(address payable to) external nonReentrant {
        uint256 amount = platformCredit[msg.sender];
        require(amount != 0 && to != address(0), "NO_CREDIT");
        platformCredit[msg.sender] = 0;
        (bool ok,) = to.call{value: amount}(""); require(ok, "PAYMENT_FAILED");
        emit PlatformWithdrawn(msg.sender, to, amount);
    }
    receive() external payable { require(msg.sender == router || msg.sender == wbnb, "BNB_SOURCE"); }
}
