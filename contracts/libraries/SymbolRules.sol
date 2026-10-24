// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SymbolFold} from "./SymbolFold.sol";

/// @title SymbolRules
/// @notice Token symbol rules from design doc §5.1 (防止用户认错币):
///         1. Only allowlisted characters: A-Z, 0-9, CJK U+4E00-9FFF, Hiragana, Katakana, Hangul syllables
///            (minus sound marks, ゠, ・ and stroke radicals; see SymbolFold.isAllowed).
///         2. Input must already be normalized (uppercase, half-width). The contract never converts.
///         3. Display width 2-12 (CJK/kana/Hangul = 2, A-Z/0-9 = 1).
///         4. Uniqueness key = keccak256(UTF-8 of the symbol after folding lookalikes), so lookalike
///            names collide on the same registry slot.
library SymbolRules {
    /// @notice Full names preserve English letter case; only ordinary ASCII spaces
    ///         and the same visible character allowlist are accepted, up to 64 UTF-8 bytes.
    function validName(bytes memory name) internal pure returns (bool) {
        if (name.length == 0 || name.length > 64) return false;
        bool visible;
        for (uint256 i; i < name.length;) {
            uint256 c0 = uint8(name[i]);
            uint256 cp;
            if (c0 < 0x80) { cp = c0; ++i; }
            else if (c0 & 0xF0 == 0xE0) {
                if (i + 2 >= name.length) return false;
                uint256 c1 = uint8(name[i + 1]);
                uint256 c2 = uint8(name[i + 2]);
                if (c1 & 0xC0 != 0x80 || c2 & 0xC0 != 0x80) return false;
                cp = ((c0 & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F);
                if (cp < 0x800) return false;
                i += 3;
            } else return false;
            if (cp == 0x20) continue;
            if (cp >= 0x61 && cp <= 0x7A) cp -= 0x20;
            if (!SymbolFold.isAllowed(cp)) return false;
            visible = true;
        }
        return visible;
    }
    uint256 internal constant MIN_WIDTH = 2;
    uint256 internal constant MAX_WIDTH = 12;
    /// @dev 12 width units can never need more than 12 code points of at most 3 UTF-8 bytes.
    uint256 internal constant MAX_BYTES = 36;

    uint8 internal constant OK = 0;
    uint8 internal constant BAD_ENCODING = 1;
    uint8 internal constant BAD_CHARACTER = 2;
    uint8 internal constant BAD_WIDTH = 3;

    /// @notice Validates `symbol` and returns its uniqueness key. Never reverts.
    /// @return code OK / BAD_ENCODING / BAD_CHARACTER / BAD_WIDTH
    /// @return key  keccak256 of the folded symbol (zero unless code == OK)
    function tryKey(bytes memory symbol) internal pure returns (uint8 code, bytes32 key) {
        uint256 len = symbol.length;
        if (len == 0 || len > MAX_BYTES) return (BAD_WIDTH, bytes32(0));

        // Folding can grow a character: ASCII T/Y fold to 3-byte CJK 丅/丫, so reserve 3x.
        bytes memory folded = new bytes(len * 3);
        uint256 out;
        uint256 w;
        uint256 i;
        while (i < len) {
            uint256 c0 = uint8(symbol[i]);
            uint256 cp;
            if (c0 < 0x80) {
                cp = c0;
                i += 1;
            } else if (c0 & 0xF0 == 0xE0) {
                // Every allowed non-ASCII range lies in U+0800..U+FFFF, i.e. 3-byte UTF-8.
                if (i + 2 >= len) return (BAD_ENCODING, bytes32(0));
                uint256 c1 = uint8(symbol[i + 1]);
                uint256 c2 = uint8(symbol[i + 2]);
                if (c1 & 0xC0 != 0x80 || c2 & 0xC0 != 0x80) return (BAD_ENCODING, bytes32(0));
                cp = ((c0 & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F);
                if (cp < 0x800) return (BAD_ENCODING, bytes32(0)); // overlong encoding
                i += 3;
            } else {
                // 2-byte or 4-byte sequences (and stray continuation bytes) can only encode
                // characters outside the allowlist.
                return (BAD_CHARACTER, bytes32(0));
            }

            if (!SymbolFold.isAllowed(cp)) return (BAD_CHARACTER, bytes32(0));
            w += cp < 0x80 ? 1 : 2;

            uint256 f = SymbolFold.fold(cp);
            if (f < 0x80) {
                folded[out++] = bytes1(uint8(f));
            } else {
                folded[out++] = bytes1(uint8(0xE0 | (f >> 12)));
                folded[out++] = bytes1(uint8(0x80 | ((f >> 6) & 0x3F)));
                folded[out++] = bytes1(uint8(0x80 | (f & 0x3F)));
            }
        }
        if (w < MIN_WIDTH || w > MAX_WIDTH) return (BAD_WIDTH, bytes32(0));

        assembly {
            mstore(folded, out)
        }
        return (OK, keccak256(folded));
    }

    /// @notice Display width of an already-valid symbol (for UI / events).
    function width(bytes memory symbol) internal pure returns (uint256 w) {
        for (uint256 i; i < symbol.length;) {
            if (uint8(symbol[i]) < 0x80) {
                w += 1;
                i += 1;
            } else {
                w += 2;
                i += 3;
            }
        }
    }
}
