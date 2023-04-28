// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "hardhat/console.sol";

library MaxLossCalculator {
    enum OptionType {
        LONG_CALL,
        LONG_PUT,
        SHORT_CALL_BASE,
        SHORT_CALL_QUOTE,
        SHORT_PUT_QUOTE
    }

    uint constant MIN = 0;
    uint constant MAX = type(uint).max;

    function calculate(uint strikePrice, uint amount, uint premium, uint optionType) public pure returns (uint) {
        bool isBuy = _isLong(optionType);
        bool isCall = _isCall(optionType);

        if (isBuy && isCall) {
            return _calculateLongCall(strikePrice, amount, premium);
        } else if (isBuy && !isCall) {
            return _calculateLongPut(strikePrice, amount, premium);
        } else if (!isBuy && isCall) {
            return _calculateShortCall(strikePrice, amount, premium);
        } else if (!isBuy && !isCall) {
            return _calculateShortPut(strikePrice, amount, premium);
        }
    }

    function _calculateLongCall(uint strikePrice, uint amount, uint premium) internal pure returns (uint) {
        uint pnlAtMin = premium * amount; 
        uint pnlAtMax = ((MAX - strikePrice) * amount) - premium * amount;
        uint pnlAtStrike = premium * amount;
    }

    function _calculateLongPut(uint strikePrice, uint amount, uint premium) internal pure returns (uint) {
        uint pnlAtMin = ((strikePrice - MIN) * amount) - premium * amount; 
        uint pnlAtMax = premium * amount; 
        uint pnlAtStrike = premium * amount;
    }

    function _calculateShortCall(uint strikePrice, uint amount, uint premium) internal pure returns (uint) {
        uint pnlAtMin = premium; 
        uint pnlAtMax = premium * amount; 
        uint pnlAtStrike = premium * amount;
    }

    function _calculateShortPut(uint strikePrice, uint amount, uint premium) internal pure returns (uint) {
        return MAX;
    }

    function _isLong(uint _optionType) internal pure returns (bool isLong) {
        if (OptionType(_optionType) == OptionType.LONG_CALL || OptionType(_optionType) == OptionType.LONG_PUT) {
            isLong = true;
        }
    }

    function _isCall(uint _optionType) public pure returns (bool isCall) {
        if (OptionType(_optionType) == OptionType.LONG_CALL || OptionType(_optionType) == OptionType.SHORT_CALL_QUOTE) {
            isCall = true;
        }
    }
}
