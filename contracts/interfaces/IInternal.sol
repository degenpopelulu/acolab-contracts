// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILaunchToken {
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address launchpad_,
        address router_,
        address wbnb_
    ) external;

    function setContracts(address dividend_, address taxProcessor_) external;

    function mintInitial(address to, uint256 amount) external;

    function enableTrading(address pair_) external;

    function launchpadBurn(address from, uint256 amount) external;

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
}

interface IDividend {
    function initialize(address token_, address launchpad_) external;

    function setTaxProcessor(address taxProcessor_) external;

    function setShare(address user, uint256 balance) external;

    function setExcluded(address account, bool excluded) external;

    function deposit() external payable;

    function withdrawableOf(address user) external view returns (uint256);
}

interface ITaxProcessor {
    function initialize(address token_, address dividend_, address devPass_, uint256 devPassId_, address platformTreasury_)
        external;

}
