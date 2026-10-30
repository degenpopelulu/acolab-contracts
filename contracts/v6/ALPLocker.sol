// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "./Types.sol";

/// @notice Permanent V2 LP custody. No burn, approve, transfer, or rescue path.
/// @dev User-confirmed first-release policy: all LP remains locked and no LP
/// fee extraction is provided.
contract ALPLocker is V6Component {
    address public pair;
    uint256 public initialLiquidity;
    event LiquidityLocked(address indexed pair, uint256 amount);
    function initialize(V6Addresses calldata c, address p) external { _initialize(c, p); }
    function lock() external {
        require(msg.sender == components.opening && pair == address(0), "OPENING_ONLY");
        pair = IV6Token(components.token).pair();
        initialLiquidity = IERC20(pair).balanceOf(address(this));
        require(initialLiquidity != 0, "NO_LIQUIDITY");
        emit LiquidityLocked(pair, initialLiquidity);
    }
}
