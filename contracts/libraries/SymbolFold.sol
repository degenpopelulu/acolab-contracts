// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Lookalike folding table for token symbols.
/// Generated from Unicode confusables.txt (UTS #39, v18.0.0, 2026-08-06),
/// restricted to the platform allowlist (A-Z, 0-9, U+4E00-9FFF, Hiragana, Katakana, Hangul syllables).
/// Each entry is 6 bytes: 3-byte source code point, 3-byte canonical code point, sorted by source.
library SymbolFold {
    uint256 internal constant ENTRIES = 122;
    bytes internal constant TABLE = hex"00004900003100004f000030000054004e05000059004e2b0030780030d80030790030d900307a0030da0030a4004ebb0030a8005de50030ab00529b0030bf0059150030c800535c0030cb004e8c0030cd00793b0030cf00516b0030d20053150030db0067290030e00053b60030e1004e440030e8005f500030ed0053e30030fc004e00005002004f7500503c00502400515100514c00535d00534400543400543300544900543300555f0055530056d70053e300586b0058610058eb00571f0058ff0058ab00596c0059680059ba0059b9005a2f005a1b005a31005a1b005b00005aaf005d520055a6005e02005dff005e32005e210060520060460060a60060850062370062360062380062360062ba0062b900635d0063290063d200633f0063f700633f0064160063fa0064470063fa00655a00655300662900662700666900665a0066f00065e500672b00672a0067ff00676e0068c10068b2006a2700699d006cac006cab006d9a006d97006e4a0051d1006e6e0051d0006ea70051d3006eb00051d2006ec40051d4006f3c0051d7006f59006e88006f8c0051d8006f9f0051dc006fa40051d9006fbf0051da006fd3006fc20070060051df00734e00596800747600746400771c00771b00784f007814007a0e007a05007d5a007d59007d76007d55007dd6007dd20080a600670c0080ca0067100080d000670f00810100671300812700671800813100812b0081410080fc0081a70067230082790053440083090082ff00853f00848d0086410086370087150086fb008a7d008a2e008aac008aaa008b21008b20008b8f008b86008c63008c5c008d86008d7f008dfa008de5008e9b008e97008eb2008eb1008f27008eff0091090090f70091150090f70092ed0092b30093ae0093ad0096ba005bc90098e1006e4c0098f20098ee0099ae006ea4009e43009e42009ed2009ed100b25800723f00b9c800535f00c2a5004eca00c2b400540800c4f0004e1b00c870004e1500d2bd009577";

    /// @dev Returns the canonical code point for cp (cp itself if it has no lookalike).
    function fold(uint256 cp) internal pure returns (uint256) {
        bytes memory t = TABLE;
        uint256 lo = 0;
        uint256 hi = ENTRIES;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            uint256 off = mid * 6;
            uint256 src = (uint256(uint8(t[off])) << 16) | (uint256(uint8(t[off + 1])) << 8) | uint256(uint8(t[off + 2]));
            if (src == cp) {
                return (uint256(uint8(t[off + 3])) << 16) | (uint256(uint8(t[off + 4])) << 8) | uint256(uint8(t[off + 5]));
            }
            if (src < cp) lo = mid + 1; else hi = mid;
        }
        return cp;
    }

    /// @dev Allowlist check (see design doc 5.1). Excluded: U+3099-309C, U+30A0, U+30FB and stroke radicals.
    function isAllowed(uint256 cp) internal pure returns (bool) {
        if (cp == 0x3099 || cp == 0x309A || cp == 0x309B || cp == 0x309C || cp == 0x30A0 || cp == 0x30FB) return false;
        if (cp == 0x4E28 || cp == 0x4E36 || cp == 0x4E3F || cp == 0x4E40 || cp == 0x4E41 || cp == 0x4E5A || cp == 0x4E85) return false;
        return (cp >= 0x41 && cp <= 0x5A) || (cp >= 0x30 && cp <= 0x39)
            || (cp >= 0x4E00 && cp <= 0x9FFF)
            || (cp >= 0x3041 && cp <= 0x3096) || (cp >= 0x309D && cp <= 0x309F)
            || (cp >= 0x30A1 && cp <= 0x30FF)
            || (cp >= 0xAC00 && cp <= 0xD7A3);
    }
}
