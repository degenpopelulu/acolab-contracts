// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IDevPassPlatform {
    function platformTreasury() external view returns(address);
    function devPassMetadata(uint256 id) external view returns(string memory,string memory,uint256,uint8,uint256,uint256);
}

/// @notice Transferable DEV rights after listing. Unclaimed income follows the current NFT owner.
contract DevPass is ERC721, ERC2981, Ownable {
    using Strings for uint256;
    mapping(address => bool) public isMinter;
    mapping(uint256 => address) public minterOf;
    uint256 public nextId;
    address public royaltyReceiver;
    address public pendingLaunchpad;
    uint64 public launchpadEta;
    uint256 public constant LAUNCHPAD_TIMELOCK = 48 hours;
    event LaunchpadProposed(address indexed launchpad, uint64 eta);
    event LaunchpadAdded(address indexed launchpad);
    event RoyaltyReceiverUpdated(address indexed receiver);
    error InvalidLaunchpad(); error TimelockNotElapsed(); error ZeroAddress();
    address public launchpad;
    uint96 public immutable ROYALTY_BPS;
    mapping(uint256=>address) public tokenOf;
    mapping(address=>uint256) public idOf;
    mapping(uint256=>bool) public locked;
    event DevPassMinted(uint256 indexed id,address indexed token,address indexed to);
    event DevPassUnlocked(uint256 indexed id);
    event DevPassBurned(uint256 indexed id);
    error OnlyLaunchpad(); error OnlyBinder(); error AlreadyBound(); error TransferLocked();
    constructor(uint96 royaltyBps) ERC721("Agent DevPass","DEVPASS") Ownable(msg.sender) {
        require(royaltyBps<=1000,"ROYALTY_TOO_HIGH");royaltyReceiver=msg.sender;ROYALTY_BPS=royaltyBps;
    }
    function setLaunchpad(address value) external onlyOwner {
        if (launchpad != address(0)) revert AlreadyBound();
        if (value.code.length == 0) revert InvalidLaunchpad();
        launchpad=value;isMinter[value]=true;emit LaunchpadAdded(value);
    }
    function proposeLaunchpad(address lp) external onlyOwner {
        if (launchpad==address(0) || lp.code.length==0) revert InvalidLaunchpad();
        pendingLaunchpad=lp;launchpadEta=uint64(block.timestamp+LAUNCHPAD_TIMELOCK);
        emit LaunchpadProposed(lp,launchpadEta);
    }
    function applyLaunchpad() external onlyOwner {
        address lp=pendingLaunchpad;
        if(lp==address(0) || lp.code.length==0)revert InvalidLaunchpad();
        if(block.timestamp<launchpadEta)revert TimelockNotElapsed();
        isMinter[lp]=true;pendingLaunchpad=address(0);launchpadEta=0;emit LaunchpadAdded(lp);
    }
    function setRoyaltyReceiver(address receiver) external onlyOwner {
        if(receiver==address(0))revert ZeroAddress();royaltyReceiver=receiver;emit RoyaltyReceiverUpdated(receiver);
    }
    function mint(address to,address token) external returns(uint256 id) {
        if(!isMinter[msg.sender])revert OnlyLaunchpad();
        require(token!=address(0) && idOf[token]==0,"TOKEN_USED");
        id=++nextId;minterOf[id]=msg.sender;tokenOf[id]=token;idOf[token]=id;locked[id]=true;
        _mint(to,id);emit DevPassMinted(id,token,to);
    }
    function unlock(uint256 id) external {
        if(minterOf[id]!=msg.sender)revert OnlyLaunchpad();_requireOwned(id);locked[id]=false;emit DevPassUnlocked(id);
    }
    function burn(uint256 id) external {
        if(minterOf[id]!=msg.sender)revert OnlyLaunchpad();_requireOwned(id);_burn(id);emit DevPassBurned(id);
    }
    function _update(address to,uint256 id,address auth) internal override returns(address) {
        if(locked[id]&&_ownerOf(id)!=address(0)&&to!=address(0))revert TransferLocked();
        return super._update(to,id,auth);
    }
    function royaltyInfo(uint256,uint256 salePrice) public view override returns(address,uint256) {
        return (royaltyReceiver,salePrice*ROYALTY_BPS/10000);
    }
    function supportsInterface(bytes4 id) public view override(ERC721,ERC2981) returns(bool){return super.supportsInterface(id);}
    function tokenURI(uint256 id) public view override returns(string memory) {
        _requireOwned(id);
        (string memory name_,string memory symbol,uint256 generation,uint8 status,uint256 earned,uint256 unclaimed)=IDevPassPlatform(minterOf[id]).devPassMetadata(id);
        string memory phase=status==2?"LISTED":status==4?"SOLD OUT":"RAISING";
        string memory svg=string.concat('<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400"><rect width="640" height="400" fill="#1A1522"/><rect x="32" y="32" width="20" height="20" fill="#2A1EFF"/><g fill="#FBF9FE" font-family="Azeret Mono,monospace"><text x="68" y="48" font-size="18">AGENT ID / DEVPASS #',id.toString(),'</text><text x="32" y="130" font-size="42">',symbol,'</text><text x="32" y="170" font-size="20">',name_,'</text><text x="32" y="220" font-size="16">GEN ',generation.toString(),' / ',phase,'</text><text x="32" y="270" font-size="14">EARNED ',earned.toString(),' wei</text><text x="32" y="305" font-size="14">UNCLAIMED ',unclaimed.toString(),' wei</text><text x="32" y="365" font-size="12">UNCLAIMED INCOME FOLLOWS THIS NFT</text></g></svg>');
        return string.concat('data:application/json;base64,',Base64.encode(bytes(string.concat('{"name":"',symbol,' DevPass #',id.toString(),'","description":"Current holder receives the listing reward and future DEV tax. Unclaimed income follows this NFT.","image":"data:image/svg+xml;base64,',Base64.encode(bytes(svg)),'","attributes":[{"trait_type":"Generation","value":',generation.toString(),'}, {"trait_type":"Status","value":"',phase,'"},{"trait_type":"Total DEV income wei","value":"',earned.toString(),'"},{"trait_type":"Unclaimed wei","value":"',unclaimed.toString(),'"}]}'))));
    }
}
