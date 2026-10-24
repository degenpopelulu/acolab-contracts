// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SymbolLib} from "./libraries/SymbolLib.sol";

/**
 * @title NameRegistry
 * @notice 全平台唯一的代币符号登记处。
 *
 * 生命周期：
 *   Raising   → 占用
 *   Graduated → 永久占用
 *   Failed    → 在 markFailed 时释放，之后可被他人重新使用
 *
 * 只有 Launchpad 能 register / release。
 */
contract NameRegistry is Ownable {
    address public launchpad; // first registrar, retained for discovery compatibility
    mapping(address => bool) public canRegister;
    mapping(bytes32 => address) public registrarOf;
    address public pendingLaunchpad;
    uint64 public launchpadEta;
    uint256 public constant LAUNCHPAD_TIMELOCK = 48 hours;
    event LaunchpadProposed(address indexed launchpad, uint64 eta);
    event LaunchpadAdded(address indexed launchpad);
    event LaunchpadRegisterRevoked(address indexed launchpad);
    error NotRegistrar();
    error InvalidLaunchpad();
    error TimelockNotElapsed();

    /// @notice 归一化 key => 代币地址（address(0) 表示未占用）
    mapping(bytes32 => address) public ownerOf;
    mapping(bytes32 => uint256) public generations;

    event LaunchpadSet(address indexed launchpad);
    event SymbolRegistered(bytes32 indexed key, string symbol, address indexed token);
    event SymbolReleased(bytes32 indexed key);

    error NotLaunchpad();
    error SymbolTaken();
    error ZeroAddress();
    error AlreadyBound();

    modifier onlyLaunchpad() {
        if (!canRegister[msg.sender]) revert NotLaunchpad();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ---------------------------------------------------------------------
    // 管理
    // ---------------------------------------------------------------------

    function setLaunchpad(address newLaunchpad) external onlyOwner {
        if (launchpad != address(0)) revert AlreadyBound();
        if (newLaunchpad == address(0)) revert ZeroAddress();
        if (newLaunchpad.code.length == 0) revert InvalidLaunchpad();
        launchpad = newLaunchpad;
        canRegister[newLaunchpad] = true;
        emit LaunchpadSet(newLaunchpad);
    }

    function proposeLaunchpad(address lp) external onlyOwner {
        if (launchpad == address(0) || lp.code.length == 0) revert InvalidLaunchpad();
        pendingLaunchpad = lp; launchpadEta = uint64(block.timestamp + LAUNCHPAD_TIMELOCK);
        emit LaunchpadProposed(lp, launchpadEta);
    }
    function applyLaunchpad() external onlyOwner {
        address lp = pendingLaunchpad;
        if (lp == address(0) || lp.code.length == 0) revert InvalidLaunchpad();
        if (block.timestamp < launchpadEta) revert TimelockNotElapsed();
        canRegister[lp] = true; pendingLaunchpad = address(0); launchpadEta = 0;
        emit LaunchpadAdded(lp);
    }
    function revokeRegister(address lp) external onlyOwner {
        canRegister[lp] = false;
        // A revoked proposal cannot silently become active after its delay.
        if (pendingLaunchpad == lp) { pendingLaunchpad = address(0); launchpadEta = 0; }
        emit LaunchpadRegisterRevoked(lp);
    }

    // ---------------------------------------------------------------------
    // 登记
    // ---------------------------------------------------------------------

    /**
     * @notice 占用符号
     * @dev 合约只接收规范化大写半角；链下先规范化，再按 SymbolFold 形近字符 key 判重。
     * @return key 归一化后的查重 key
     */
    function register(string calldata symbol, address token) external onlyLaunchpad returns (bytes32 key) {
        if (token == address(0)) revert ZeroAddress();

        key = SymbolLib.validateSymbol(symbol);
        if (ownerOf[key] != address(0)) revert SymbolTaken();

        ownerOf[key] = token;
        registrarOf[key] = msg.sender;
        generations[key] += 1;
        emit SymbolRegistered(key, symbol, token);
    }

    /// @notice 募集失败时释放符号
    function release(bytes32 key) external {
        if (registrarOf[key] != msg.sender) revert NotRegistrar();
        delete ownerOf[key];
        delete registrarOf[key];
        emit SymbolReleased(key);
    }

    // ---------------------------------------------------------------------
    // 只读 / 预检
    // ---------------------------------------------------------------------

    /// @notice 符号 → 查重 key
    function keyOf(string calldata symbol) external pure returns (bytes32) {
        return SymbolLib.keyOf(symbol);
    }

    /// @notice 校验全称（不合法则 revert，错误信息可直接展示）
    function validateName(string calldata name_) external pure {
        SymbolLib.validateName(name_);
    }

    /**
     * @notice 前端 / API 预检：是否合法、是否可用、不可用原因
     * @return valid 字符是否合法
     * @return available 是否可注册
     * @return reason 不可用原因（合法且可用时为空串）
     */
    function isAvailable(string calldata symbol) external view returns (bool valid, bool available, string memory reason) {
        try this.checkSymbol(symbol) returns (bytes32 key) {
            if (ownerOf[key] != address(0)) {
                (bool ok, bytes memory result) = registrarOf[key].staticcall(
                    abi.encodeWithSignature("isExpiredLaunch(address)", ownerOf[key])
                );
                if (ok && result.length == 32 && abi.decode(result, (bool))) return (true, true, "");
                return (true, false, "TAKEN");
            }
            return (true, true, "");
        } catch Error(string memory err) {
            return (false, false, err);
        } catch {
            return (false, false, "INVALID");
        }
    }

    /// @dev 仅用于 isAvailable 的 try/catch 探针
    function checkSymbol(string calldata symbol) external pure returns (bytes32) {
        return SymbolLib.validateSymbol(symbol);
    }
}
