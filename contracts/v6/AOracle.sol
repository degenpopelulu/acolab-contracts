// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./Types.sol";

interface IV6Feed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
contract AOracle is V6Component {
    struct Observation { uint256 timestamp; uint256 cumulative; }
    Observation[24] public observations;
    uint256 public nextIndex;
    uint256 public lastObservation;
    address public feed;
    address public wbnb;
    event ObservationUpdated(uint256 indexed index, uint256 timestamp, uint256 cumulative);

    function initialize(V6Addresses calldata c, address p, address f, address w) external {
        _initialize(c, p); feed = f; wbnb = w;
    }
    function _current() private view returns (bool valid, uint256 cumulative) {
        address pair = IV6Token(components.token).pair();
        (uint112 r0, uint112 r1, uint32 last) = IV6Pair(pair).getReserves();
        if (r0 == 0 || r1 == 0) return (false, 0);
        bool tokenFirst = IV6Pair(pair).token0() == components.token;
        cumulative = tokenFirst ? IV6Pair(pair).price0CumulativeLast() : IV6Pair(pair).price1CumulativeLast();
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - last;
            cumulative += ((uint256(tokenFirst ? r1 : r0) << 112) / (tokenFirst ? r0 : r1)) * elapsed;
        }
        return (true, cumulative);
    }
    function update() external {
        require(IV6Token(components.token).tradingOpen(), "NOT_OPEN");
        if (lastObservation != 0 && block.timestamp < lastObservation + 1 hours) return;
        (bool valid, uint256 cumulative) = _current(); require(valid, "NO_RESERVES");
        observations[nextIndex] = Observation(block.timestamp, cumulative);
        emit ObservationUpdated(nextIndex, block.timestamp, cumulative);
        nextIndex = (nextIndex + 1) % 24; lastObservation = block.timestamp;
    }
    function marketCap() external view returns (bool valid, uint256 usd8) {
        if (!IV6Token(components.token).tradingOpen()
            || block.timestamp < IV6Token(components.token).openTimestamp() + 24 hours || block.timestamp < lastObservation
            || lastObservation == 0 || block.timestamp - lastObservation > 2 hours) return (false, 0);
        // At most 24 reads; choose the observation nearest a full 24-hour window.
        uint256 best = type(uint256).max;
        Observation memory chosen;
        for (uint256 i; i < 24; ++i) {
            Observation memory o = observations[i];
            if (o.timestamp == 0 || block.timestamp < o.timestamp) continue;
            uint256 age = block.timestamp - o.timestamp;
            if (age < 22 hours || age > 26 hours) continue;
            uint256 distance = age > 24 hours ? age - 24 hours : 24 hours - age;
            if (distance < best) { best = distance; chosen = o; }
        }
        if (chosen.timestamp == 0) return (false, 0);
        (bool ok, uint256 cumulative) = _current(); if (!ok) return (false, 0);
        uint256 average;
        unchecked { average = (cumulative - chosen.cumulative) / (block.timestamp - chosen.timestamp); }
        try IV6Feed(feed).latestRoundData() returns (uint80 round, int256 answer, uint256, uint256 updated, uint80 answered) {
            if (answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > 3 hours
                || answered < round) return (false, 0);
            uint8 decimals = IV6Feed(feed).decimals();
            if (decimals > 18) return (false, 0);
            uint256 capBnbWei = Math.mulDiv(average, SUPPLY, 1 << 112);
            usd8 = Math.mulDiv(capBnbWei, uint256(answer) * 1e8, 1e18 * 10 ** decimals);
            return (usd8 != 0, usd8);
        } catch { return (false, 0); }
    }
}
