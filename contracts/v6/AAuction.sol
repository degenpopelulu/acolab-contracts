// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./Types.sol";

contract AAuction is V6Component, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant LOT = 500e18;
    uint256 public constant LOTS = 16_000;
    uint256 public constant SLOT_SECONDS = 1800;
    uint256 public constant MAX_SLOTS = 336;
    uint256 public constant STEP = 0.0001 ether;
    struct Order {
        address wallet; uint8 level; uint8 qty;
        uint256 end; uint256 claimed; bool refunded; bool paidRefunded;
    }
    struct Slot {
        uint256 seedBlock; uint256 cutoffTime; uint256 settledBlock; bool usedFallback; uint256 filled;
        uint256 paidQty; uint256 paidValue;
        uint256[11] fromUnit; uint256[11] toUnit;
        uint256 cursorLevel; uint256 cursorIndex; bool cursorReady;
    }
    uint256 public startTime;
    uint256 public nextSlot;
    uint256 public totalSold;
    uint256 public raised;
    uint256 public finalPricePerLot;
    bool public finalized;
    bool public refundMode;
    bool public proceedsReleased;
    address public agentId;
    uint256[11] public consumed;
    uint256[11] public queued;
    Order[] public orders;
    mapping(uint256 => uint256[]) private levelOrders;
    mapping(address => uint256[]) private walletOrders;
    mapping(address => uint256) public committed;
    mapping(address => uint256) public credit;
    mapping(uint256 => Slot) private slots;
    struct Checkpoint { uint256 timestamp; uint256 units; }
    mapping(uint256 => Checkpoint[]) private checkpoints;
    event Bid(address indexed wallet, uint256 indexed orderId, uint8 level, uint8 qty);
    event SlotSeeded(uint256 indexed slot, uint256 seedBlock);
    event SlotCutoff(uint256 indexed slot, uint256 cutoffTime, bool usedFallback);
    event SlotSettled(uint256 indexed slot, uint256 settledBlock, uint256 filled, uint256 paidQty, uint256 paidValue);
    event SlotDistributed(uint256 indexed slot, uint256 recipients, uint256 amount);
    event MintFinalized(uint256 totalSold, uint256 raised);
    event Claimed(address indexed wallet, uint256 amount);
    event Withdrawn(address indexed wallet, address indexed to, uint256 amount);
    event RefundModeEntered(uint8 reason);

    function initialize(V6Addresses calldata c, address p, address id, uint256 start) external {
        _initialize(c, p); agentId = id; startTime = start;
    }
    function deadline() public view returns (uint256) { return startTime + 7 days; }
    function currentSlot() public view returns (uint256) {
        return block.timestamp < startTime ? 0 : Math.min((block.timestamp - startTime) / SLOT_SECONDS, MAX_SLOTS);
    }
    function quota(uint256 slot) public pure returns (uint256) { return slot == 71 ? 238 : 222; }
    function _seedEnded(uint256 maxSlots) private {
        for (uint256 n; n < maxSlots && nextSlot + n < MAX_SLOTS; ++n) {
            uint256 index = nextSlot + n;
            if (block.timestamp < startTime + (index + 1) * SLOT_SECONDS) break;
            Slot storage s = slots[index];
            if (s.seedBlock == 0) {
                // Choose an unknown future block only after the bidding window closes.
                s.seedBlock = block.number + 1; emit SlotSeeded(index, s.seedBlock);
            }
        }
    }
    function _cutoff(uint256 index) private returns (bool) {
        uint256 end = startTime + (index + 1) * SLOT_SECONDS;
        if (block.timestamp < end) return false;
        Slot storage s = slots[index];
        if (s.cutoffTime != 0) return true;
        if (s.seedBlock == 0 || block.number <= s.seedBlock) return false;
        bytes32 hash = blockhash(s.seedBlock);
        if (hash == bytes32(0)) {
            // Retain the documented hard-end fallback if every caller misses
            // the 256-block hash retention window. This is explicit on-chain.
            s.cutoffTime = end - 1; s.usedFallback = true;
        } else {
            s.cutoffTime = end - 3 minutes
                + uint256(keccak256(abi.encode(hash, address(this), index))) % 180;
        }
        emit SlotCutoff(index, s.cutoffTime, s.usedFallback);
        return true;
    }
    function queuedAt(uint256 level, uint256 timestamp) public view returns (uint256) {
        require(level <= 10, "LEVEL");
        Checkpoint[] storage points = checkpoints[level];
        uint256 lo; uint256 hi = points.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (points[mid].timestamp <= timestamp) lo = mid + 1; else hi = mid;
        }
        return lo == 0 ? 0 : points[lo - 1].units;
    }
    function checkpointCount(uint256 level) external view returns(uint256) { return checkpoints[level].length; }
    function checkpointAt(uint256 level, uint256 index) external view returns(Checkpoint memory) { return checkpoints[level][index]; }
    function _checkpoint(uint256 level) private {
        Checkpoint[] storage points = checkpoints[level];
        if (points.length != 0 && points[points.length - 1].timestamp == block.timestamp)
            points[points.length - 1].units = queued[level];
        else points.push(Checkpoint(block.timestamp, queued[level]));
    }
    function _settle(uint256 maxSlots) private {
        if (finalized || refundMode || block.timestamp < startTime) return;
        _seedEnded(maxSlots);
        uint256 steps;
        while (nextSlot < MAX_SLOTS && steps < maxSlots && totalSold < LOTS) {
            if (!_cutoff(nextSlot)) break;
            Slot storage s = slots[nextSlot];
            uint256 room = Math.min(quota(nextSlot), LOTS - totalSold);
            for (uint256 n = 11; n != 0; --n) {
                uint256 level = n - 1;
                s.fromUnit[level] = consumed[level];
                uint256 fill = Math.min(queuedAt(level, s.cutoffTime) - consumed[level], room);
                consumed[level] += fill;
                s.toUnit[level] = consumed[level];
                s.filled += fill; room -= fill;
                if (level != 0) { s.paidQty += fill; s.paidValue += fill * level * STEP; }
            }
            totalSold += s.filled; raised += s.paidValue;
            if (s.paidQty != 0) finalPricePerLot = s.paidValue / s.paidQty;
            s.settledBlock = block.number;
            emit SlotSettled(nextSlot, block.number, s.filled, s.paidQty, s.paidValue);
            ++nextSlot; ++steps;
        }
        if (totalSold == LOTS || nextSlot == MAX_SLOTS) {
            finalized = true; emit MintFinalized(totalSold, raised);
        }
    }
    function settle() external { _settle(20); }
    function poke() external { _settle(20); }
    function finalize() external { _settle(20); require(finalized, "SETTLE_REQUIRED"); }
    function bid(uint8 qty, uint8 level) external payable nonReentrant {
        // Bound the caller's maintenance work. Timestamp checkpoints ensure a
        // fresh bid never participates in any overdue interval.
        _settle(1);
        require(!finalized && !refundMode && !IV6Platform(platform).mintPaused(), "MINT_CLOSED");
        require(block.timestamp >= startTime && block.timestamp < deadline(), "MINT_TIME");
        require(qty != 0 && level <= 10 && committed[msg.sender] + qty <= 4, "QUOTA");
        require(IERC20(agentId).balanceOf(msg.sender) != 0, "AGENT_ID");
        require(msg.value == uint256(qty) * level * STEP, "PAYMENT");
        uint256 id = orders.length;
        queued[level] += qty;
        _checkpoint(level);
        orders.push(Order(msg.sender, level, qty, queued[level], 0, false, false));
        levelOrders[level].push(id); walletOrders[msg.sender].push(id); committed[msg.sender] += qty;
        emit Bid(msg.sender, id, level, qty);
    }
    function filled(uint256 id) public view returns (uint256) {
        Order storage o = orders[id]; uint256 beforeUnits = o.end - o.qty;
        return consumed[o.level] <= beforeUnits ? 0 : Math.min(o.qty, consumed[o.level] - beforeUnits);
    }
    function queueAhead(uint256 id) external view returns (uint256 ahead) {
        Order storage o = orders[id];
        for (uint256 i = o.level + 1; i < 11; ++i) ahead += queued[i] - consumed[i];
        uint256 beforeUnits = o.end - o.qty;
        if (beforeUnits > consumed[o.level]) ahead += beforeUnits - consumed[o.level];
    }
    function ordersOf(address wallet) external view returns (uint256[] memory) { return walletOrders[wallet]; }
    function slotInfo(uint256 slot) external view returns (Slot memory) { return slots[slot]; }
    function _payOrder(uint256 id) private returns (uint256 amount) {
        Order storage o = orders[id];
        uint256 earnedLots = filled(id);
        amount = (earnedLots - o.claimed) * LOT;
        if (amount != 0) {
            o.claimed = earnedLots;
            IERC20(components.token).safeTransfer(o.wallet, amount);
            emit Claimed(o.wallet, amount);
        }
    }
    function claim() external nonReentrant {
        _settle(20);
        uint256[] storage ids = walletOrders[msg.sender];
        for (uint256 i; i < ids.length; ++i) _payOrder(ids[i]);
    }
    function _first(uint256 level, uint256 units) private view returns (uint256) {
        uint256 lo; uint256 hi = levelOrders[level].length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (orders[levelOrders[level][mid]].end <= units) lo = mid + 1; else hi = mid;
        }
        return lo;
    }
    function distributeSlot(uint256 slot, uint256 maxOrders) external nonReentrant {
        require(slot < nextSlot && maxOrders != 0 && maxOrders <= 100, "BATCH");
        Slot storage s = slots[slot];
        uint256 processed; uint256 amount;
        while (s.cursorLevel < 11 && processed < maxOrders) {
            uint256 level = s.cursorLevel;
            if (s.toUnit[level] == s.fromUnit[level]) { ++s.cursorLevel; s.cursorReady = false; continue; }
            if (!s.cursorReady) { s.cursorIndex = _first(level, s.fromUnit[level]); s.cursorReady = true; }
            uint256[] storage ids = levelOrders[level];
            if (s.cursorIndex >= ids.length || orders[ids[s.cursorIndex]].end - orders[ids[s.cursorIndex]].qty >= s.toUnit[level]) {
                ++s.cursorLevel; s.cursorReady = false; continue;
            }
            amount += _payOrder(ids[s.cursorIndex++]); ++processed;
        }
        emit SlotDistributed(slot, processed, amount);
    }
    function _refundUnfilled(address user) private {
        uint256[] storage ids = walletOrders[user];
        for (uint256 i; i < ids.length; ++i) {
            Order storage o = orders[ids[i]];
            if (!o.refunded) {
                o.refunded = true; credit[user] += (o.qty - filled(ids[i])) * o.level * STEP;
            }
        }
    }
    function withdrawTo(address payable to) public nonReentrant {
        _settle(20); require(finalized || refundMode, "NOT_FINISHED");
        _refundUnfilled(msg.sender);
        uint256 amount = credit[msg.sender]; require(to != address(0), "ZERO_TO");
        credit[msg.sender] = 0;
        (bool ok,) = to.call{value: amount}(""); require(ok, "PAYMENT_FAILED");
        emit Withdrawn(msg.sender, to, amount);
    }
    function withdraw() external { withdrawTo(payable(msg.sender)); }
    function enterRefundMode() external nonReentrant {
        require(!IV6Token(components.token).tradingOpen() && !proceedsReleased && !refundMode, "REFUND_STATE");
        require(msg.sender == IV6Platform(platform).owner() || block.timestamp >= deadline() + 7 days, "NOT_AUTHORIZED");
        refundMode = true; finalized = true;
        IV6Opening(components.opening).cancel();
        emit RefundModeEntered(msg.sender == IV6Platform(platform).owner() ? 1 : 2);
    }
    function refundPaid() external nonReentrant {
        require(refundMode, "NOT_REFUND_MODE");
        uint256[] storage ids = walletOrders[msg.sender];
        uint256 tokens; uint256 amount;
        for (uint256 i; i < ids.length; ++i) {
            Order storage o = orders[ids[i]];
            if (o.level == 0 || o.paidRefunded) continue;
            _payOrder(ids[i]);
            uint256 lots = filled(ids[i]); tokens += lots * LOT; amount += lots * o.level * STEP;
            o.paidRefunded = true;
        }
        if (tokens != 0) {
            IERC20(components.token).safeTransferFrom(msg.sender, DEAD, tokens);
            credit[msg.sender] += amount;
        }
    }
    function releaseProceeds() external returns (uint256 amount) {
        require(msg.sender == components.opening && finalized && !refundMode && !proceedsReleased, "OPENING_ONLY");
        proceedsReleased = true; amount = raised;
        (bool ok,) = msg.sender.call{value: amount}(""); require(ok, "PROCEEDS_FAILED");
    }
    function burnUnsold() external returns (uint256 amount) {
        require(msg.sender == components.opening && finalized, "OPENING_ONLY");
        amount = (LOTS - totalSold) * LOT;
        if (amount != 0) IERC20(components.token).safeTransfer(DEAD, amount);
    }
}
