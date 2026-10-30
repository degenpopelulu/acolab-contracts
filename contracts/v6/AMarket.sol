// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Types.sol";

interface IAMarketPlatform {
    function project(address token) external view returns (V6Addresses memory);
    function treasury() external view returns (address);
}

/// @notice Pre-opening buy orders for one immutable APlatform. No owner, token
/// custody, upgrade hook or administrative withdrawal. All BNB payouts are pull based.
contract AMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant LOT_TOKENS = 500 ether;
    uint256 public constant PRICE_STEP = 0.00001 ether;
    uint256 public constant MAX_MATCHES = 20;
    IAMarketPlatform public immutable platform;
    struct Order { address token; address buyer; uint256 price; uint256 remaining; }
    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) private books;
    mapping(uint256 => uint256) private positions; // heap index + 1
    mapping(address => uint256[]) private walletOrders;
    mapping(address => uint256) public credit;
    uint256 public nextId = 1;
    uint256 public totalEscrow;
    uint256 public totalCredit;
    event BuyPosted(uint256 indexed id, address indexed token, address indexed buyer, uint256 lots, uint256 price);
    event Filled(uint256 indexed id, address indexed token, address indexed seller, address buyer, uint256 lots, uint256 gross, uint256 fee);
    event Cancelled(uint256 indexed id, address indexed buyer, uint256 refund);
    event Withdrawn(address indexed owner, address indexed recipient, uint256 amount);

    constructor(address platform_) {
        require(platform_.code.length != 0, "PLATFORM");
        platform = IAMarketPlatform(platform_);
        require(platform.treasury() != address(0), "TREASURY");
    }
    function isActive(address token) public view returns (bool) {
        V6Addresses memory c = platform.project(token);
        if (c.token != token || token == address(0)) return false;
        return !IV6Token(token).tradingOpen() && !IV6Opening(c.opening).failed()
            && !IV6Auction(c.auction).refundMode()
            && !(IV6Auction(c.auction).finalized() && IV6Auction(c.auction).raised() == 0);
    }
    function postBuy(address token, uint256 lots, uint256 price) external payable nonReentrant returns (uint256 id) {
        require(isActive(token), "MARKET_CLOSED");
        require(lots != 0 && price >= PRICE_STEP && price % PRICE_STEP == 0, "ORDER");
        require(msg.value == lots * price, "VALUE");
        id = nextId++;
        orders[id] = Order(token, msg.sender, price, lots);
        walletOrders[msg.sender].push(id);
        uint256[] storage heap = books[token];
        heap.push(id); positions[id] = heap.length; _up(heap, heap.length - 1);
        totalEscrow += msg.value;
        emit BuyPosted(id, token, msg.sender, lots, price);
    }
    /// @dev IDs must be the exact best-price/FIFO prefix at execution. Stale
    /// quotes revert atomically instead of skipping higher-priority buyers.
    function sell(address token, uint256 lots, uint256[] calldata ids, uint256 minNet) external nonReentrant {
        require(isActive(token), "MARKET_CLOSED");
        require(lots != 0 && ids.length != 0 && ids.length <= MAX_MATCHES, "MATCH_LIMIT");
        uint256 left = lots;
        uint256 gross;
        uint256 fee;
        address treasury = platform.treasury();
        for (uint256 i; i < ids.length; ++i) {
            require(left != 0, "EXTRA_IDS");
            uint256[] storage heap = books[token];
            require(heap.length != 0 && heap[0] == ids[i], "BEST_ORDER_REQUIRED");
            Order storage o = orders[ids[i]];
            uint256 filled = left < o.remaining ? left : o.remaining;
            uint256 value = filled * o.price;
            uint256 cut = value / 100;
            left -= filled; o.remaining -= filled; gross += value; fee += cut;
            if (o.remaining == 0) _remove(token, ids[i]);
            // Token never enters AMarket. AToken has zero tax on pre-open
            // wallet transfers; callback failure/reentrancy reverts everything.
            IERC20(token).safeTransferFrom(msg.sender, o.buyer, filled * LOT_TOKENS);
            emit Filled(ids[i], token, msg.sender, o.buyer, filled, value, cut);
        }
        require(left == 0, "INSUFFICIENT_ORDERS");
        require(gross - fee >= minNet, "MIN_NET");
        totalEscrow -= gross;
        _credit(msg.sender, gross - fee); _credit(treasury, fee);
    }
    function cancel(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        require(o.buyer == msg.sender && o.remaining != 0, "ORDER_OWNER");
        uint256 value = o.remaining * o.price;
        o.remaining = 0; _remove(o.token, id); totalEscrow -= value;
        _credit(msg.sender, value);
        emit Cancelled(id, msg.sender, value);
    }
    function withdrawTo(address payable recipient) external nonReentrant {
        require(recipient != address(0) && recipient != address(this), "RECIPIENT");
        uint256 value = credit[msg.sender];
        require(value != 0, "NO_CREDIT");
        credit[msg.sender] = 0; totalCredit -= value;
        (bool ok,) = recipient.call{value: value}("");
        require(ok, "BNB_TRANSFER");
        emit Withdrawn(msg.sender, recipient, value);
    }
    function _credit(address owner, uint256 value) private {
        credit[owner] += value; totalCredit += value;
    }
    function orderCount(address token) external view returns (uint256) { return books[token].length; }
    function walletOrderCount(address wallet) external view returns (uint256) { return walletOrders[wallet].length; }
    function ordersOf(address wallet, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        require(limit <= 50, "READ_LIMIT");
        uint256[] storage source = walletOrders[wallet];
        uint256 n = offset >= source.length ? 0 : source.length - offset;
        if (n > limit) n = limit;
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = source[offset + i];
    }
    /// @notice Bounded best-first traversal. Does not copy the entire heap.
    function topOrders(address token, uint256 limit) external view returns (uint256[] memory ids) {
        require(limit <= 50, "READ_LIMIT");
        uint256[] storage heap = books[token];
        uint256 n = heap.length < limit ? heap.length : limit;
        ids = new uint256[](n);
        if (n == 0) return ids;
        uint256[] memory frontier = new uint256[](n + 1);
        uint256 count = 1;
        for (uint256 i; i < n; ++i) {
            uint256 best;
            for (uint256 j = 1; j < count; ++j)
                if (_better(heap[frontier[j]], heap[frontier[best]])) best = j;
            uint256 index = frontier[best];
            ids[i] = heap[index];
            frontier[best] = frontier[--count];
            if (i + 1 == n) break;
            uint256 child = index * 2 + 1;
            if (child < heap.length) frontier[count++] = child;
            if (child + 1 < heap.length) frontier[count++] = child + 1;
        }
    }
    function _better(uint256 a, uint256 b) private view returns (bool) {
        return orders[a].price > orders[b].price || (orders[a].price == orders[b].price && a < b);
    }
    function _swap(uint256[] storage h, uint256 a, uint256 b) private {
        (h[a], h[b]) = (h[b], h[a]); positions[h[a]] = a + 1; positions[h[b]] = b + 1;
    }
    function _up(uint256[] storage h, uint256 i) private {
        while (i != 0) {
            uint256 parent = (i - 1) / 2;
            if (!_better(h[i], h[parent])) break;
            _swap(h, i, parent); i = parent;
        }
    }
    function _remove(address token, uint256 id) private {
        uint256[] storage h = books[token];
        uint256 i = positions[id] - 1;
        uint256 last = h[h.length - 1];
        h.pop(); delete positions[id];
        if (i == h.length) return;
        h[i] = last; positions[last] = i + 1;
        if (i != 0 && _better(h[i], h[(i - 1) / 2])) { _up(h, i); return; }
        while (i * 2 + 1 < h.length) {
            uint256 child = i * 2 + 1;
            if (child + 1 < h.length && _better(h[child + 1], h[child])) ++child;
            if (!_better(h[child], h[i])) break;
            _swap(h, i, child); i = child;
        }
    }
}
