// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KeeperRewardAccount} from "./KeeperRewardAccount.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {NameRegistry} from "./NameRegistry.sol";
import {DevPass} from "./DevPass.sol";
import {SymbolLib} from "./libraries/SymbolLib.sol";
import {ILaunchToken, IDividend, ITaxProcessor} from "./interfaces/IInternal.sol";
import {IPancakeV2Factory, IPancakeV2Pair, IWBNB} from "./interfaces/IPancake.sol";

/**
 * @title Launchpad
 * @notice BSC 上的 Agent ID 公平发射台；版本间共享名字注册表与 DevPass。
 *
 * 负责发币、打新、毕业、退款。
 * 募集到的 BNB 只能按规则流向池子、DEV、平台或退款，
 * 管理员没有任何提取募集款的函数。
 */
interface IMarkFailed {
    function markFailed(address token) external;
    function markFailedTo(address token, address rewardRecipient) external;
}

contract Launchpad is Ownable, KeeperRewardAccount {
    // ------------------------------------------------------------------
    // 全平台不变量；认购和加池参数由创建时的档位快照决定。
    // ------------------------------------------------------------------

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CREATE_FEE = 0.005 ether;
    uint256 public constant GRADUATE_KEEPER_REWARD = 0.005 ether;
    uint256 public constant FAILED_KEEPER_REWARD = 0.0002 ether;
    uint256 public failedKeeperReserve;

    uint256 public constant AGENT_ID_TIMELOCK = 48 hours;
    /// @notice 新发行代币地址末尾的 12 bit 固定为 AC0（大小写由地址校验格式决定）。
    uint160 public constant TOKEN_ADDRESS_SUFFIX = 0xAC0;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice SPACE ID Agent ID（BSC）
    address public constant DEFAULT_AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    // ------------------------------------------------------------------
    // 类型
    // ------------------------------------------------------------------

    enum Status {
        None,
        Raising,
        Graduated,
        Failed,
        SoldOut
    }

    struct Tier {
        uint32 totalShares;
        uint32 maxPerWallet;
        uint32 raiseDuration;
        uint128 sharePrice;
        uint128 shareTokens;
        uint128 lpTokens;
        uint128 lpBnb;
        uint128 devBnb;
        uint128 platformBnb;
        bool active;
    }
    Tier[] public tiers;
    event TierAdded(uint256 indexed tierId, Tier tier);
    event TierDisabled(uint256 indexed tierId);
    error BadTier();
    error TierInactive();

    struct Launch {
        address creator;
        uint256 devPassId;
        address token;
        address taxProcessor;
        address dividend;
        bytes32 symbolKey;
        address agentId;
        uint64 deadline;
        uint32 sharesSold;
        Status status;
        address pair;
        uint256 tierId;
        Tier tier;
    }

    // ------------------------------------------------------------------
    // 状态
    // ------------------------------------------------------------------

    address public platformTreasury;
    address public agentId;
    address public pendingAgentId;
    uint64 public agentIdEta;

    address public immutable factory;
    address public immutable router;
    address public immutable wbnb;
    NameRegistry public nameRegistry;
    DevPass public immutable devPass;
    mapping(uint256=>uint256) public listingReward;
    mapping(uint256=>uint256) public listingPaid;
    mapping(address=>uint256) public generationOf;

    address public immutable tokenImplementation;
    address public immutable dividendImplementation;
    address public immutable taxProcessorImplementation;

    bool public createPaused;

    mapping(address => Launch) internal _launches;
    /// @notice token => wallet => 已买份数
    mapping(address => mapping(address => uint32)) public sharesOf;
    /// @notice DEV / 平台的待领 BNB（pull 模式）
    uint256 public platformPending;

    address[] public allTokens;
    uint256 public totalLaunches;
    uint256 public totalGraduated;

    // ------------------------------------------------------------------
    // 事件
    // ------------------------------------------------------------------

    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string metaURI,
        uint64 deadline
    );
    event Bought(address indexed token, address indexed buyer, uint32 shares, uint32 sharesSold);
    event SoldOut(address indexed token);
    event Graduated(address indexed token, address indexed pair, uint256 lpMinted);
    event LaunchFailed(address indexed token);
    event Refunded(address indexed token, address indexed buyer, uint32 shares, uint256 bnb);
    event Withdrawn(address indexed to, uint256 bnb);
    event PlatformTreasuryUpdated(address indexed treasury);
    event CreatePausedSet(bool paused);
    event AgentIdProposed(address indexed agentId, uint64 eta);
    event AgentIdApplied(address indexed agentId);
    event ListingRewardClaimed(uint256 indexed id,address indexed to,uint256 bnb);

    // ------------------------------------------------------------------
    // 错误
    // ------------------------------------------------------------------

    error ZeroAddress();
    error CreatePaused();
    error BadFee();
    error NotRaising();
    error RaiseEnded();
    error AgentIdRequired();
    error BadShares();
    error WalletLimit();
    error NoSharesLeft();
    error NotSoldOut();
    error NotDevPassOwner();
    error BadValue();
    error NotFailed();
    error NothingToRefund();
    error NothingToWithdraw();
    error TransferFailed();
    error PairFailed();
    error NoPendingAgentId();
    error TimelockNotElapsed();
    error BadTokenAddress();

    constructor(
        address initialOwner,
        address platformTreasury_,
        address factory_,
        address router_,
        address wbnb_,
        address nameRegistry_,
        address tokenImplementation_,
        address dividendImplementation_,
        address taxProcessorImplementation_,
        address initialAgentId,
        address devPass_
    ) Ownable(initialOwner) {
        if (
            platformTreasury_ == address(0) || factory_ == address(0) || router_ == address(0)
                || wbnb_ == address(0) || nameRegistry_ == address(0) || tokenImplementation_ == address(0)
                || dividendImplementation_ == address(0) || taxProcessorImplementation_ == address(0)
                || initialAgentId == address(0) || devPass_ == address(0)
        ) revert ZeroAddress();

        platformTreasury = platformTreasury_;
        factory = factory_;
        router = router_;
        wbnb = wbnb_;
        nameRegistry = NameRegistry(nameRegistry_);
        tokenImplementation = tokenImplementation_;
        dividendImplementation = dividendImplementation_;
        taxProcessorImplementation = taxProcessorImplementation_;
        agentId = initialAgentId;
        devPass = DevPass(devPass_);
        _addTier(Tier({totalShares:6000, maxPerWallet:4, raiseDuration:48 hours,
            sharePrice:0.001 ether, shareTokens:100_000e18, lpTokens:400_000_000e18,
            lpBnb:4 ether, devBnb:1 ether, platformBnb:1 ether, active:true}));
    }

    // ==================================================================
    // 发币
    // ==================================================================

    /**
     * @notice 任何人付 0.005 BNB 就能发币
     * @param metaURI IPFS 元数据（图片、简介、社交链接）
     */
    // Keep the original selector: existing clients always create tier 0.
    function createToken(string calldata name_, string calldata symbol, string calldata metaURI, bytes32 salt)
        external payable nonReentrant returns (address)
    { return _createToken(name_, symbol, metaURI, salt, 0); }

    function createToken(string calldata name_, string calldata symbol, string calldata metaURI, bytes32 salt, uint256 tierId)
        external payable nonReentrant returns (address)
    { return _createToken(name_, symbol, metaURI, salt, tierId); }

    function _createToken(string calldata name_, string calldata symbol, string calldata metaURI, bytes32 salt, uint256 tierId)
        internal returns (address token)
    {
        if (tierId >= tiers.length) revert BadTier();
        Tier memory t = tiers[tierId];
        if (!t.active) revert TierInactive();
        if (createPaused) revert CreatePaused();
        if (msg.value != CREATE_FEE) revert BadFee();

        // 字符校验（全称与符号）
        SymbolLib.validateName(name_);
        bytes32 requestedKey = SymbolLib.validateSymbol(symbol);
        address previous = nameRegistry.ownerOf(requestedKey);
        if (previous != address(0)) {
            address registrar = nameRegistry.registrarOf(requestedKey);
            // The registrar alone may release its own name. Failure leaves it occupied.
            // Forward the real caller so cross-version cleanup never traps a bounty.
            try IMarkFailed(registrar).markFailedTo(previous, msg.sender) {} catch {
                try IMarkFailed(registrar).markFailed(previous) {} catch {}
            }
        }

        if ((uint160(predictTokenAddress(msg.sender, salt)) & 0xFFF) != TOKEN_ADDRESS_SUFFIX) {
            revert BadTokenAddress();
        }

        // 克隆三件套
        address div = Clones.clone(dividendImplementation);
        address tp = Clones.clone(taxProcessorImplementation);
        token = Clones.cloneDeterministic(tokenImplementation, _tokenSalt(msg.sender, salt));

        ILaunchToken(token).initialize(name_, symbol, address(this), router, wbnb);
        IDividend(div).initialize(token, address(this));
        uint256 id = devPass.mint(msg.sender, token);
        ITaxProcessor(tp).initialize(token, div, address(devPass), id, platformTreasury);

        IDividend(div).setTaxProcessor(tp);
        ILaunchToken(token).setContracts(div, tp);

        // 10 亿枚全部铸给 Launchpad，没有预挖
        ILaunchToken(token).mintInitial(address(this), TOTAL_SUPPLY);

        // 占符号（重名会 revert，整笔交易回滚）
        bytes32 key = nameRegistry.register(symbol, token);

        uint64 deadline = uint64(block.timestamp + t.raiseDuration);

        _launches[token] = Launch({
            creator: msg.sender,
            devPassId: id,
            token: token,
            taxProcessor: tp,
            dividend: div,
            symbolKey: key,
            agentId: agentId,
            deadline: deadline,
            sharesSold: 0,
            status: Status.Raising,
            pair: address(0),
            tierId: tierId,
            tier: t
        });

        allTokens.push(token);
        totalLaunches += 1;
        generationOf[token] = nameRegistry.generations(key);

        // 防刷费记入平台待领，不退
        platformPending += CREATE_FEE;
        failedKeeperReserve += FAILED_KEEPER_REWARD;

        emit TokenCreated(token, msg.sender, name_, symbol, metaURI, deadline);
    }

    /// @notice salt 绑定实际创建者，其他钱包无法抢先占用同一个预计地址。
    function predictTokenAddress(address creator, bytes32 salt) public view returns (address) {
        return Clones.predictDeterministicAddress(tokenImplementation, _tokenSalt(creator, salt), address(this));
    }

    function _tokenSalt(address creator, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    // ==================================================================
    // 打新
    // ==================================================================

    /**
     * @notice 一口价 0.001 BNB/份，必须持有 Agent ID，每个钱包最多 4 份
     * @dev 按请求份数付款；若全局余量不足，成交余量并原路退回差额。
     */
    function buy(address token, uint32 shares) external payable nonReentrant {
        Launch storage l = _launches[token];

        if (l.status != Status.Raising) revert NotRaising();
        if (block.timestamp >= l.deadline) revert RaiseEnded();
        if (IERC721(l.agentId).balanceOf(msg.sender) == 0) revert AgentIdRequired();

        if (shares == 0) revert BadShares();
        if (shares > l.tier.maxPerWallet) revert WalletLimit();
        uint32 requested = shares;
        if (msg.value != uint256(requested) * l.tier.sharePrice) revert BadValue();
        uint32 left = l.tier.totalShares - l.sharesSold;
        if (left == 0) revert NoSharesLeft();
        if (shares > left) shares = left;

        uint32 owned = sharesOf[token][msg.sender];
        if (owned + shares > l.tier.maxPerWallet) revert WalletLimit();

        sharesOf[token][msg.sender] = owned + shares;
        l.sharesSold += shares;

        if (!IERC20(token).transfer(msg.sender, uint256(shares) * l.tier.shareTokens)) revert TransferFailed();

        emit Bought(token, msg.sender, shares, l.sharesSold);

        // 卖满只标记；Keeper 或任意调用者另发 graduate 交易建池。
        if (l.sharesSold == l.tier.totalShares) {
            l.status = Status.SoldOut;
            emit SoldOut(token);
        }
        uint256 change = uint256(requested - shares) * l.tier.sharePrice;
        if (change != 0) {
            (bool ok,) = payable(msg.sender).call{value: change}("");
            if (!ok) revert TransferFailed();
        }
    }

    // ==================================================================
    // 失败与退款
    // ==================================================================

    function isExpiredLaunch(address token) public view returns (bool) {
        Launch storage l = _launches[token];
        return l.status == Status.Raising && block.timestamp >= l.deadline && l.sharesSold < l.tier.totalShares;
    }

    /// @notice 任何人可调：过了截止时间且没卖完 → 标记失败并释放符号
    function markFailed(address token) external {
        _checkAndMarkFailed(token, msg.sender);
    }

    function markFailedTo(address token, address rewardRecipient) external {
        if (rewardRecipient == address(0)) revert ZeroAddress();
        _checkAndMarkFailed(token, rewardRecipient);
    }

    function _checkAndMarkFailed(address token, address keeper) internal {
        Launch storage l = _launches[token];
        if (l.status != Status.Raising) revert NotRaising();
        if (block.timestamp < l.deadline) revert RaiseEnded();
        if (l.sharesSold >= l.tier.totalShares) revert NotFailed();

        _markFailed(token, keeper);
    }

    function _markFailed(address token, address keeper) internal {
        Launch storage l = _launches[token];
        l.status = Status.Failed;
        failedKeeperReserve -= FAILED_KEEPER_REWARD;
        if (keeper != address(0)) {
            platformPending -= FAILED_KEEPER_REWARD;
            _rewardKeeper(keeper, FAILED_KEEPER_REWARD);
        }
        devPass.burn(l.devPassId);
        nameRegistry.release(l.symbolKey);
        emit LaunchFailed(token);
    }

    /// @notice 买过的钱包领全额退款，不扣手续费
    function refund(address token) external nonReentrant {
        Launch storage l = _launches[token];

        if (l.status == Status.Raising) {
            if (block.timestamp < l.deadline) revert RaiseEnded();
            if (l.sharesSold >= l.tier.totalShares) revert NotFailed();
            // A user's own refund remains unconditional; release the unused bounty.
            _markFailed(token, address(0));
        }
        if (l.status != Status.Failed) revert NotFailed();

        uint32 shares = sharesOf[token][msg.sender];
        if (shares == 0) revert NothingToRefund();

        // 先清零份额，再销毁代币，最后退款
        sharesOf[token][msg.sender] = 0;
        ILaunchToken(token).launchpadBurn(msg.sender, uint256(shares) * l.tier.shareTokens);

        uint256 amount = uint256(shares) * l.tier.sharePrice;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Refunded(token, msg.sender, shares, amount);
    }

    // ==================================================================
    // 毕业
    // ==================================================================

    /**
     * @dev 不走 Router 的 addLiquidity，而是直接转资产给 pair 再 mint。
     *      这样可以防「抢先建池」：攻击者提前打进 pair 的 WBNB 只会变成池子的一部分，
     *      等于他白送钱；而代币在毕业前不能转账，没人能往 pair 里放代币。
     */
    function graduate(address token) external nonReentrant {
        if (_launches[token].status != Status.SoldOut) revert NotSoldOut();
        _graduate(token);
    }

    function _graduate(address token) internal {
        Launch storage l = _launches[token];
        l.status = Status.Graduated;
        totalGraduated += 1;

        // 1. 取 pair，没有就建
        address pair = l.pair;
        if (pair == address(0)) pair = IPancakeV2Factory(factory).getPair(token, wbnb);
        if (pair == address(0)) {
            pair = IPancakeV2Factory(factory).createPair(token, wbnb);
        }
        if (pair == address(0)) revert PairFailed();
        l.pair = pair;

        // 2. 解锁转账、开始收税、把 pair 加入分红排除名单
        //    必须在加池转账之前，否则 pair 收到 4 亿枚时会被登记成分红份额
        ILaunchToken(token).enableTrading(pair);

        // 3. 按档位快照注入 BNB 和代币，LP 直接铸到黑洞。
        IWBNB(wbnb).deposit{value: l.tier.lpBnb}();
        require(IWBNB(wbnb).transfer(pair, l.tier.lpBnb), "WBNB_TRANSFER_FAILED");
        require(ILaunchToken(token).transfer(pair, l.tier.lpTokens), "TOKEN_TRANSFER_FAILED");
        uint256 lpMinted = IPancakeV2Pair(pair).mint(BURN_ADDRESS);

        // 4. 按快照记入 DEV / 平台待领，收款地址无法通过拒收卡住毕业。
        devPass.unlock(l.devPassId);
        listingReward[l.devPassId] += l.tier.devBnb;
        failedKeeperReserve -= FAILED_KEEPER_REWARD;
        uint256 reward = l.tier.platformBnb < GRADUATE_KEEPER_REWARD ? l.tier.platformBnb : GRADUATE_KEEPER_REWARD;
        platformPending += l.tier.platformBnb - reward;
        _rewardKeeper(msg.sender, reward);

        emit Graduated(token, pair, lpMinted);
    }

    // ==================================================================
    // 待领（pull 模式）
    // ==================================================================

    /// @notice DEV / 平台金库拉取自己的待领 BNB
    function withdraw() external nonReentrant returns (uint256 amount) {
        amount = pendingWithdrawals(msg.sender);
        if (amount == 0) revert NothingToWithdraw();
        if (msg.sender == platformTreasury) platformPending = failedKeeperReserve;

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdrawn(msg.sender, amount);
    }

    // ==================================================================
    // 管理（owner 为多签）
    // ==================================================================

    /// @notice 只改平台收款地址，已累积的待领一并转过去
    function setPlatformTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert ZeroAddress();

        platformTreasury = treasury;
        emit PlatformTreasuryUpdated(treasury);
    }

    /// @notice 换 Agent ID 合约地址，48 小时时间锁，只影响之后新发的币
    function proposeAgentId(address newAgentId) external onlyOwner {
        if (newAgentId == address(0)) revert ZeroAddress();
        pendingAgentId = newAgentId;
        agentIdEta = uint64(block.timestamp + AGENT_ID_TIMELOCK);
        emit AgentIdProposed(newAgentId, agentIdEta);
    }

    function applyAgentId() external onlyOwner {
        if (pendingAgentId == address(0)) revert NoPendingAgentId();
        if (block.timestamp < agentIdEta) revert TimelockNotElapsed();

        agentId = pendingAgentId;
        pendingAgentId = address(0);
        agentIdEta = 0;
        emit AgentIdApplied(agentId);
    }

    /// @notice 只能暂停发新币；不能暂停 buy、refund、毕业
    function pauseCreate(bool paused) external onlyOwner {
        createPaused = paused;
        emit CreatePausedSet(paused);
    }

    // ==================================================================
    // 只读
    // ==================================================================

    function pendingWithdrawals(address account) public view returns (uint256) {
        return account == platformTreasury ? platformPending - failedKeeperReserve : 0;
    }

    function claimListingReward(uint256 id) external nonReentrant returns(uint256 amount) {
        address recipient = devPass.ownerOf(id);
        if (msg.sender != recipient) revert NotDevPassOwner();
        amount = listingReward[id]; if(amount==0) revert NothingToWithdraw();
        listingReward[id]=0;listingPaid[id]+=amount;
        (bool ok,) = payable(recipient).call{value:amount}("");if(!ok)revert TransferFailed();
        emit ListingRewardClaimed(id,recipient,amount);
    }
    function devPassMetadata(uint256 id) external view returns(string memory,string memory,uint256,uint8,uint256,uint256) {
        address token = devPass.tokenOf(id); Launch storage l=_launches[token];
        require(l.token != address(0) && l.devPassId == id, "UNKNOWN_DEVPASS");
        (bool ok,bytes memory n)=token.staticcall(abi.encodeWithSignature("name()"));require(ok);
        (,bytes memory s)=token.staticcall(abi.encodeWithSignature("symbol()"));
        (,bytes memory p)=l.taxProcessor.staticcall(abi.encodeWithSignature("totalDevPaid()"));
        (,bytes memory b)=l.taxProcessor.staticcall(abi.encodeWithSignature("devBalance()"));
        uint256 unpaid=abi.decode(b,(uint256))+listingReward[id];
        return(abi.decode(n,(string)),abi.decode(s,(string)),generationOf[token],uint8(l.status),unpaid+listingPaid[id]+abi.decode(p,(uint256)),unpaid);
    }

    function getLaunch(address token) external view returns (Launch memory) {
        return _launches[token];
    }

    /// @notice 打新进度：已卖份数 / 总份数 / 剩余时间
    function progress(address token) external view returns (uint32 sold, uint32 total, uint256 secondsLeft) {
        Launch storage l = _launches[token];
        sold = l.sharesSold;
        total = l.tier.totalShares;
        secondsLeft = block.timestamp >= l.deadline ? 0 : l.deadline - block.timestamp;
    }

    /// @notice 某钱包在某币上还能买几份
    function remainingShares(address token, address wallet) external view returns (uint32) {
        Launch storage l = _launches[token];
        if (l.status != Status.Raising || block.timestamp >= l.deadline) return 0;
        uint32 owned = sharesOf[token][wallet];
        if (owned >= l.tier.maxPerWallet) return 0;
        uint32 quota = l.tier.maxPerWallet - owned;
        uint32 left = l.tier.totalShares - l.sharesSold;
        return quota < left ? quota : left;
    }

    function tokensCount() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Only platform-wide constants; asset economics come from getLaunch().tier.
    function constants() external pure returns (uint256 supply, uint256 createFee) {
        return (TOTAL_SUPPLY, CREATE_FEE);
    }
    function tierCount() external view returns (uint256) { return tiers.length; }
    function getTier(uint256 id) external view returns (Tier memory) {
        if (id >= tiers.length) revert BadTier();
        return tiers[id];
    }
    function addTier(Tier calldata t) external onlyOwner returns (uint256) { return _addTier(t); }
    function _addTier(Tier memory t) internal returns (uint256 id) {
        _checkTier(t); t.active = true; id = tiers.length; tiers.push(t);
        emit TierAdded(id, t);
    }
    function disableTier(uint256 id) external onlyOwner {
        if (id >= tiers.length) revert BadTier();
        tiers[id].active = false; emit TierDisabled(id);
    }
    function _checkTier(Tier memory t) internal pure {
        uint256 raised = uint256(t.totalShares) * t.sharePrice;
        if (uint256(t.totalShares) * t.shareTokens + t.lpTokens != TOTAL_SUPPLY) revert BadTier();
        if (uint256(t.lpBnb) + t.devBnb + t.platformBnb != raised) revert BadTier();
        if (uint256(t.lpBnb) * t.shareTokens != uint256(t.lpTokens) * t.sharePrice) revert BadTier();
        if (uint256(t.lpBnb) * 100 < raised * 60) revert BadTier();
        if (uint256(t.devBnb) * 100 > raised * 20 || uint256(t.platformBnb) * 100 > raised * 20) revert BadTier();
        if (uint256(t.lpTokens) * 100 < TOTAL_SUPPLY * 20 || uint256(t.lpTokens) * 100 > TOTAL_SUPPLY * 60) revert BadTier();
        if (t.totalShares < 100 || t.totalShares > 1_000_000) revert BadTier();
        if (t.maxPerWallet == 0 || t.maxPerWallet > t.totalShares) revert BadTier();
        if (t.raiseDuration < 12 hours || t.raiseDuration > 7 days) revert BadTier();
        if (t.sharePrice == 0 || t.shareTokens == 0) revert BadTier();
    }
    // Tier-zero compatibility getters for existing tooling; accounting never reads these.
    function SHARE_TOKENS() external view returns(uint256) { return tiers[0].shareTokens; }
    function SHARE_PRICE() external view returns(uint256) { return tiers[0].sharePrice; }
    function TOTAL_SHARES() external view returns(uint32) { return tiers[0].totalShares; }
    function MAX_SHARES_PER_WALLET() external view returns(uint32) { return tiers[0].maxPerWallet; }
    function RAISE_DURATION() external view returns(uint256) { return tiers[0].raiseDuration; }
    function LP_TOKENS() external view returns(uint256) { return tiers[0].lpTokens; }
    function LP_BNB() external view returns(uint256) { return tiers[0].lpBnb; }
    function DEV_BNB() external view returns(uint256) { return tiers[0].devBnb; }
    function PLATFORM_BNB() external view returns(uint256) { return tiers[0].platformBnb; }
    function TARGET_RAISE() external view returns(uint256) { return uint256(tiers[0].totalShares)*tiers[0].sharePrice; }
}
