// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./Types.sol";
import "./ALPLocker.sol";

contract AOpening is V6Component, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant MIN_WBNB_DEPOSIT = 1 gwei;
    address public wbnb;
    address public devPass;
    uint256 public devPassId;
    uint256 public devCredit;
    uint256 public devEarnedTotal;
    uint256 public devClaimedTotal;
    bool public failed;
    bool private finished;
    mapping(address => uint256) public credit;
    event Graduated(uint256 openPricePerShare, uint256 amountA, uint256 amountBNB,
        uint256 lp, uint256 burnedA, uint256 devBNB, address indexed caller);
    event DevWithdrawn(address indexed owner, address indexed to, uint256 amount);
    event CreditWithdrawn(address indexed owner, address indexed to, uint256 amount);
    function initialize(V6Addresses calldata c, address p, address w) external {
        _initialize(c, p); wbnb = w;
        devPass = IV6Platform(p).devPass();
        devPassId = IV6DevPass(devPass).idOf(c.token);
        require(devPassId != 0 && IV6DevPass(devPass).minterOf(devPassId) == p, "DEVPASS");
    }
    function devWallet() public view returns (address) {
        try IV6DevPass(devPass).ownerOf(devPassId) returns(address holder) { return holder; }
        catch { return address(0); }
    }
    function graduate() external nonReentrant {
        require(!finished, "FINISHED");
        IV6Auction auction = IV6Auction(components.auction);
        auction.finalize();
        require(!auction.refundMode(), "REFUND_MODE");
        if (auction.raised() == 0) { _cancel(); return; }
        finished = true;
        uint256 raised = auction.releaseProceeds();
        uint256 callerReward = Math.min(0.005 ether, raised / 10);
        uint256 keeperRefund = Math.min(0.05 ether, raised / 10);
        credit[msg.sender] += callerReward; credit[IV6Platform(platform).keeper()] += keeperRefund;
        uint256 available = raised - callerReward - keeperRefund;
        uint256 price = auction.finalPricePerLot(); require(price >= 0.0001 ether && price <= 0.001 ether, "PRICE");
        uint256 amountA = Math.min(2_000_000e18, Math.mulDiv(available, 500e18, price));
        uint256 amountBNB = Math.mulDiv(amountA, price, 500e18);
        require(amountA != 0 && amountBNB != 0 && amountBNB <= available, "LIQUIDITY");
        address pair = IV6Token(components.token).pair();
        IV6Pair pool = IV6Pair(pair);
        pool.skim(devWallet());
        (uint112 r0, uint112 r1,) = pool.getReserves();
        bool aFirst = pool.token0() == components.token;
        uint256 reserveA = aFirst ? r0 : r1;
        uint256 reserveW = aFirst ? r1 : r0;
        require(reserveA == 0 && pool.totalSupply() == 0, "PREEXISTING_LP");
        uint256 toDeposit = amountBNB > reserveW ? amountBNB - reserveW : 0;
        // V2 mint accounts for newly added balances, not existing reserves.
        // A synced WBNB donation must never leave the W-side mint delta at zero.
        if (toDeposit < MIN_WBNB_DEPOSIT) toDeposit = Math.min(MIN_WBNB_DEPOSIT, available);
        devCredit += available - toDeposit;
        devEarnedTotal += available - toDeposit;
        if (toDeposit != 0) {
            IV6WBNB(wbnb).deposit{value: toDeposit}();
            IERC20(wbnb).safeTransfer(pair, toDeposit);
        }
        IERC20(components.token).safeTransfer(pair, amountA);
        uint256 lp = pool.mint(components.locker); require(lp != 0, "NO_LP");
        (r0, r1,) = pool.getReserves();
        uint256 actualW = aFirst ? r1 : r0;
        uint256 actualA = aFirst ? r0 : r1;
        if (reserveW <= amountBNB) {
            uint256 expected = Math.mulDiv(actualA, price, 500e18);
            require(actualW >= expected * 99 / 100 && actualW <= expected * 101 / 100 + 1, "PRICE_DEVIATION");
        }
        ALPLocker(components.locker).lock();
        uint256 burned = 2_000_000e18 - amountA;
        if (burned != 0) IERC20(components.token).safeTransfer(DEAD, burned);
        burned += auction.burnUnsold();
        IV6Token(components.token).openTrading();
        IV6Platform(platform).markOpened();
        IV6Oracle(components.oracle).update();
        emit Graduated(price, amountA, toDeposit, lp, burned, available - toDeposit, msg.sender);
    }
    function _cancel() private {
        require(!finished && !IV6Token(components.token).tradingOpen(), "FINISHED");
        finished = true; failed = true;
        IERC20(components.token).safeTransfer(DEAD, IERC20(components.token).balanceOf(address(this)));
        IV6Release(components.release).cancel();
        IV6Auction(components.auction).burnUnsold();
        IV6Platform(platform).releaseName();
    }
    function cancel() external {
        require(msg.sender == components.auction, "AUCTION_ONLY"); _cancel();
    }
    function withdrawTo(address payable to) external nonReentrant {
        uint256 amount = credit[msg.sender]; require(to != address(0), "ZERO_TO");
        credit[msg.sender] = 0;
        (bool ok,) = to.call{value: amount}(""); require(ok, "PAYMENT_FAILED");
        emit CreditWithdrawn(msg.sender, to, amount);
    }
    function withdrawDev(address payable to) external nonReentrant {
        require(msg.sender == IV6DevPass(devPass).ownerOf(devPassId), "DEVPASS_OWNER_ONLY");
        uint256 amount = devCredit; require(amount != 0 && to != address(0), "NO_CREDIT");
        devCredit = 0; devClaimedTotal += amount;
        (bool ok,) = to.call{value: amount}(""); require(ok, "PAYMENT_FAILED");
        emit DevWithdrawn(msg.sender, to, amount);
    }
    receive() external payable { require(msg.sender == components.auction, "AUCTION_ONLY"); }
}
