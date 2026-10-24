// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {SymbolRules} from "./SymbolRules.sol";
library SymbolLib {
    function validateSymbol(string memory symbol) internal pure returns(bytes32 key) {
        require(bytes(symbol).length>0,"SYMBOL_EMPTY");
        (uint8 code,bytes32 k)=SymbolRules.tryKey(bytes(symbol));
        if(code==SymbolRules.BAD_ENCODING)revert("BAD_UTF8");
        if(code==SymbolRules.BAD_CHARACTER)revert("SYMBOL_BAD_CHARSET");
        require(code==SymbolRules.OK,"SYMBOL_BAD_WIDTH");return k;
    }
    function validateName(string memory name_) internal pure {
        require(bytes(name_).length>0,"NAME_EMPTY");
        require(bytes(name_).length<=64,"NAME_TOO_LONG");
        require(SymbolRules.validName(bytes(name_)),"NAME_BAD_CHARSET");
    }
    function keyOf(string memory symbol) internal pure returns(bytes32) {return validateSymbol(symbol);}
}
