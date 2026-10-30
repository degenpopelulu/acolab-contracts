// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct V6Addresses {
    address token;
    address auction;
    address opening;
    address locker;
    address dividend;
    address staking;
    address release;
    address oracle;
}

interface IV6Token is IERC20 {
    function pair() external view returns (address);
    function tradingOpen() external view returns (bool);
    function openTimestamp() external view returns (uint256);
    function openTrading() external;
    function dirtyCount() external view returns (uint256);
    function clearDirty(address account) external;
}
interface IV6Dividend {
    function sync(address account) external;
    function onBalanceChange(address account, uint256 balance) external;
    function onStakeChange(address account, uint256 staked) external;
    function deposit() external payable;
}
interface IV6Staking {
    function totalStaked() external view returns (uint256);
    function ownedPrincipal(address user) external view returns (uint256);
    function reservedRewards() external view returns (uint256);
    function trancheFinished() external view returns (bool);
    function paused() external view returns (bool);
    function startTranche(uint256 amount, uint256 tier) external;
    function setPaused(bool value) external;
    function returnUndistributed() external returns (uint256);
}
interface IV6Oracle {
    function marketCap() external view returns (bool valid, uint256 usd8);
    function update() external;
}
interface IV6Auction {
    function finalize() external;
    function finalized() external view returns (bool);
    function refundMode() external view returns (bool);
    function totalSold() external view returns (uint256);
    function raised() external view returns (uint256);
    function finalPricePerLot() external view returns (uint256);
    function releaseProceeds() external returns (uint256);
    function burnUnsold() external returns (uint256);
}
interface IV6Platform {
    function devPass() external view returns (address);
    function owner() external view returns (address);
    function treasury() external view returns (address);
    function keeper() external view returns (address);
    function mintPaused() external view returns (bool);
    function releaseName() external;
    function markOpened() external;
}
interface IV6DevPass {
    function idOf(address token) external view returns (uint256);
    function tokenOf(uint256 id) external view returns (address);
    function minterOf(uint256 id) external view returns (address);
    function ownerOf(uint256 id) external view returns (address);
}
interface IV6Opening {
    function failed() external view returns (bool);
    function cancel() external;
    function devWallet() external view returns (address);
}
interface IV6Release {
    function cancel() external;
}
interface IV6Pair is IERC20 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address to) external returns (uint256);
    function skim(address to) external;
    function sync() external;
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}
interface IV6Router {
    function WETH() external view returns (address);
    function factory() external view returns (address);
    function getAmountsOut(uint256 amount, address[] calldata path) external view returns (uint256[] memory);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amount, uint256 minimum, address[] calldata path, address to, uint256 deadline
    ) external;
}
interface IV6Factory {
    function getPair(address a, address b) external view returns (address);
    function createPair(address a, address b) external returns (address);
}
interface IV6WBNB is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

abstract contract V6Component {
    bool public initialized;
    V6Addresses public components;
    address public platform;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant MINIMUM = 5_000e18;

    constructor() { initialized = true; }
    function _initialize(V6Addresses calldata c, address p) internal {
        require(!initialized && p == msg.sender && p.code.length != 0, "INITIALIZER");
        initialized = true;
        components = c;
        platform = p;
    }
}
