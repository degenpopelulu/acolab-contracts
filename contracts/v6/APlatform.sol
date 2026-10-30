// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {NameRegistry} from "../NameRegistry.sol";
import {DevPass} from "../DevPass.sol";
import {SymbolLib} from "../libraries/SymbolLib.sol";
import "./AToken.sol";
import "./AAuction.sol";
import "./AOpening.sol";
import "./ALPLocker.sol";
import "./ADividend.sol";
import "./AStaking.sol";
import "./ARelease.sol";
import "./AOracle.sol";

contract APlatform is Ownable, ReentrancyGuard {
    uint256 public constant CREATE_FEE = 0.005 ether;
    mapping(address => uint256) public creationFeeCredit;
    address[8] public implementations;
    address public immutable router;
    address public immutable wbnb;
    address public immutable agentId;
    address public immutable feed;
    NameRegistry public immutable registry;
    DevPass public immutable devPass;
    address public immutable keeper;
    address public treasury;
    address public pendingTreasury;
    uint256 public treasuryEta;
    bool public mintPaused;
    bool public hasOpenedProject;
    uint256 public projectCount;
    address[] public allTokens;
    mapping(address => V6Addresses) private projects;
    mapping(address => bytes32) private openingKeys;
    mapping(address => bool) private knownOpening;
    mapping(address => address) private openingToken;
    mapping(address => uint256) public generationOf;
    event ProjectCreated(address indexed creator, address indexed token, string name, string symbol,
        string metaURI, uint256 startTime, V6Addresses contracts_);
    event Paused(bool value);
    event TreasuryChangeQueued(address indexed recipient, uint256 eta);
    event TreasuryChanged(address indexed recipient);
    event ProjectDevPass(address indexed token, uint256 indexed id, address indexed creator);
    event CreationFeeAccrued(address indexed payer, address indexed treasury, uint256 amount);
    event CreationFeeWithdrawn(address indexed owner, address indexed recipient, uint256 amount);

    constructor(address admin, address treasury_, address keeper_, address router_, address wbnb_,
        address agent_, address feed_, address registry_, address devPass_, address[8] memory templates) Ownable(admin)
    {
        // Ownable rejects a zero admin. Deployment preflight requires a
        // multisig unless the operator explicitly authorizes temporary EOA use.
        require(treasury_ != address(0) && keeper_ != address(0), "ZERO_ADDRESS");
        require(router_.code.length != 0 && wbnb_.code.length != 0 && agent_.code.length != 0
            && feed_.code.length != 0 && registry_.code.length != 0 && devPass_.code.length != 0, "DEPENDENCY");
        require(DevPass(devPass_).supportsInterface(0x80ac58cd), "DEVPASS");
        require(IV6Router(router_).WETH() == wbnb_ && IV6Router(router_).factory().code.length != 0, "ROUTER");
        for (uint256 i; i < 8; ++i) require(templates[i].code.length != 0, "TEMPLATE");
        implementations = templates; treasury = treasury_; keeper = keeper_; router = router_;
        wbnb = wbnb_; agentId = agent_; feed = feed_; registry = NameRegistry(registry_); devPass = DevPass(devPass_);
    }
    function setMintPaused(bool value) external onlyOwner { mintPaused = value; emit Paused(value); }
    function queueTreasury(address recipient) external onlyOwner {
        require(recipient != address(0), "ZERO_TO");
        pendingTreasury = recipient; treasuryEta = block.timestamp + 48 hours;
        emit TreasuryChangeQueued(recipient, treasuryEta);
    }
    function applyTreasury() external {
        require(treasuryEta != 0 && block.timestamp >= treasuryEta, "TIMELOCK");
        treasury = pendingTreasury; pendingTreasury = address(0); treasuryEta = 0;
        emit TreasuryChanged(treasury);
    }
    function renounceOwnership() public override onlyOwner {
        require(hasOpenedProject && !mintPaused, "NOT_OPEN"); super.renounceOwnership();
    }
    function transferOwnership(address recipient) public override onlyOwner {
        require(recipient.code.length != 0, "MULTISIG_REQUIRED");
        super.transferOwnership(recipient);
    }
    function predict(bytes32 salt) public view returns (V6Addresses memory c) {
        address[8] memory a;
        for (uint256 i; i < 8; ++i)
            a[i] = Clones.predictDeterministicAddress(implementations[i], keccak256(abi.encode(salt, i)), address(this));
        c = V6Addresses(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
    }
    function project(address token) external view returns (V6Addresses memory) { return projects[token]; }
    function createToken(string calldata n, string calldata s, string calldata metaURI,
        uint256 start, bytes32 userSalt) external payable nonReentrant returns (address)
    {
        require(msg.value == CREATE_FEE, "CREATE_FEE");
        // The administrator can register the initial asset before opening
        // public issuance. Auction bidding remains paused for EVERY wallet.
        require((!mintPaused || msg.sender == owner()) && start >= block.timestamp && start <= block.timestamp + 7 days, "START");
        SymbolLib.validateName(n); SymbolLib.validateSymbol(s);
        require(bytes(metaURI).length <= 2048, "META_LENGTH");
        bytes32 salt = keccak256(abi.encode(msg.sender, userSalt));
        V6Addresses memory c = predict(salt);
        require(uint160(c.token) & 0xfff == 0xac0, "CA_SUFFIX");
        for (uint256 i; i < 8; ++i)
            Clones.cloneDeterministic(implementations[i], keccak256(abi.encode(salt, i)));
        uint256 id = devPass.mint(msg.sender, c.token);
        AAuction(c.auction).initialize(c, address(this), agentId, start);
        AOpening(payable(c.opening)).initialize(c, address(this), wbnb);
        ALPLocker(c.locker).initialize(c, address(this));
        ADividend(c.dividend).initialize(c, address(this), treasury);
        AStaking(c.staking).initialize(c, address(this));
        ARelease(c.release).initialize(c, address(this));
        AOracle(c.oracle).initialize(c, address(this), feed, wbnb);
        AToken(payable(c.token)).initialize(c, address(this), n, s, router, wbnb);
        bytes32 key = registry.register(s, c.token);
        generationOf[c.token] = registry.generations(key);
        openingKeys[c.opening] = key; knownOpening[c.opening] = true;
        openingToken[c.opening] = c.token;
        projects[c.token] = c; ++projectCount;
        allTokens.push(c.token);
        creationFeeCredit[treasury] += msg.value;
        emit CreationFeeAccrued(msg.sender, treasury, msg.value);
        emit ProjectCreated(msg.sender, c.token, n, s, metaURI, start, c);
        emit ProjectDevPass(c.token, id, msg.sender);
        return c.token;
    }
    function withdrawCreationFees(address payable recipient) external nonReentrant {
        uint256 amount = creationFeeCredit[msg.sender];
        require(amount != 0 && recipient != address(0), "NO_CREDIT");
        creationFeeCredit[msg.sender] = 0;
        (bool ok,) = recipient.call{value: amount}(""); require(ok, "PAYMENT_FAILED");
        emit CreationFeeWithdrawn(msg.sender, recipient, amount);
    }
    function releaseName() external {
        require(knownOpening[msg.sender] && IV6Opening(msg.sender).failed(), "OPENING_ONLY");
        registry.release(openingKeys[msg.sender]); knownOpening[msg.sender] = false;
        devPass.burn(devPass.idOf(openingToken[msg.sender]));
    }
    function markOpened() external {
        require(knownOpening[msg.sender], "OPENING_ONLY");
        devPass.unlock(devPass.idOf(openingToken[msg.sender]));
        hasOpenedProject = true;
    }
    function platformTreasury() external view returns(address) { return treasury; }
    function devPassMetadata(uint256 id) external view returns(
        string memory name_, string memory symbol_, uint256 generation,
        uint8 status, uint256 earned, uint256 unclaimed
    ) {
        require(devPass.minterOf(id) == address(this), "UNKNOWN_DEVPASS");
        address token = devPass.tokenOf(id);
        V6Addresses memory c = projects[token];
        require(c.token != address(0), "UNKNOWN_DEVPASS");
        name_ = AToken(payable(token)).name(); symbol_ = AToken(payable(token)).symbol();
        generation = generationOf[token];
        AOpening opening = AOpening(payable(c.opening));
        AAuction auction = AAuction(c.auction);
        status = opening.failed() ? 3 : AToken(payable(token)).tradingOpen() ? 2 : auction.finalized() ? 4 : 1;
        earned = opening.devEarnedTotal() + AToken(payable(token)).devEarnedTotal();
        unclaimed = opening.devCredit() + AToken(payable(token)).devCredit();
    }
}
