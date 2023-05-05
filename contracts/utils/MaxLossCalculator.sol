// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../synthetix/SafeDecimalMath.sol";

/**
 * @title MaxLossCalculator
 * @author Otus
 * @notice Calculate max loss at min, max and each strike price
 */
contract MaxLossCalculator {
    using SafeDecimalMath for uint;

    struct Strike {
        uint strikePrice;
        uint amount;
        uint premium; // total amount paid / received for the option (premium * amount)
        uint optionType;
    }

    enum OptionType {
        LONG_CALL,
        LONG_PUT,
        SHORT_CALL_BASE,
        SHORT_CALL_QUOTE,
        SHORT_PUT_QUOTE
    }

    int constant MAX_VALUE = 1000000e18; // 1 million max expiry asset value

    function calculate(Strike[] memory strikes) external pure returns (uint) {
        int maxLoss;

        if (strikes.length == 1) {
            maxLoss = _calculate1Strike(strikes[0]);
        } else if (strikes.length == 2) {
            maxLoss = _calculate2Strikes(strikes);
        } else if (strikes.length == 3) {
            maxLoss = _calculate3Strikes(strikes);
        } else if (strikes.length == 4) {
            maxLoss = _calculate4Strikes(strikes);
        } else {
            revert("MaxLossCalculator: number of strikes not supported");
        }

        return _abs(maxLoss);
    }

    function _calculate1Strike(Strike memory strike1) internal pure returns (int) {
        (int pnlAtMin, int pnlAtMax) = _calculateStrikeMinMax(strike1);
        int pnlAtStrike = _calculateAtStrikePriceExpiry(strike1.strikePrice, strike1);
        return _min(pnlAtStrike, _min(pnlAtMin, pnlAtMax));
    }

    function _calculate2Strikes(Strike[] memory strikes) internal pure returns (int) {
        if (strikes.length != 2) {
            revert("MaxLossCalculator: invalid number of strikes");
        }

        (int pnlAtMin1, int pnlAtMax1) = _calculateStrikeMinMax(strikes[0]);

        (int pnlAtMin2, int pnlAtMax2) = _calculateStrikeMinMax(strikes[1]);

        int pnlAtStrike;

        {
            Strike memory strike;

            for (uint i = 0; i < 2; i++) {
                strike = strikes[i];
                int tempPnlAtStrike;

                tempPnlAtStrike += _calculateAtStrikePriceExpiry(strike.strikePrice, strikes[0]);

                tempPnlAtStrike += _calculateAtStrikePriceExpiry(strike.strikePrice, strikes[1]);

                if (tempPnlAtStrike < pnlAtStrike) {
                    pnlAtStrike = tempPnlAtStrike;
                }
            }
        }

        int pnlAtMin = pnlAtMin1 + pnlAtMin2;
        int pnlAtMax = pnlAtMax1 + pnlAtMax2;

        return _min(pnlAtStrike, _min(pnlAtMin, pnlAtMax));
    }

    function _calculate3Strikes(Strike[] memory strikes) internal pure returns (int) {
        if (strikes.length != 3) {
            revert("MaxLossCalculator: invalid number of strikes");
        }

        (int pnlAtMin1, int pnlAtMax1) = _calculateStrikeMinMax(strikes[0]);

        (int pnlAtMin2, int pnlAtMax2) = _calculateStrikeMinMax(strikes[1]);

        (int pnlAtMin3, int pnlAtMax3) = _calculateStrikeMinMax(strikes[2]);

        int pnlAtStrike;

        {
            Strike memory strike;

            for (uint i = 0; i < 3; i++) {
                strike = strikes[i];
                int tempPnlAtStrike;

                tempPnlAtStrike += _calculateAtStrikePriceExpiry(strike.strikePrice, strikes[0]);

                tempPnlAtStrike += _calculateAtStrikePriceExpiry(strike.strikePrice, strikes[1]);

                tempPnlAtStrike += _calculateAtStrikePriceExpiry(strike.strikePrice, strikes[2]);

                if (tempPnlAtStrike < pnlAtStrike) {
                    pnlAtStrike = tempPnlAtStrike;
                }
            }
        }
        int pnlAtMin = pnlAtMin1 + pnlAtMin2 + pnlAtMin3;
        int pnlAtMax = pnlAtMax1 + pnlAtMax2 + pnlAtMax3;

        return _min(pnlAtStrike, _min(pnlAtMin, pnlAtMax));
    }

    function _calculate4Strikes(Strike[] memory strikes) internal pure returns (int) {
        if (strikes.length != 4) {
            revert("MaxLossCalculator: invalid number of strikes");
        }

        (int pnlAtMin1, int pnlAtMax1) = _calculateStrikeMinMax(strikes[0]);
        (int pnlAtMin2, int pnlAtMax2) = _calculateStrikeMinMax(strikes[1]);
        (int pnlAtMin3, int pnlAtMax3) = _calculateStrikeMinMax(strikes[2]);
        (int pnlAtMin4, int pnlAtMax4) = _calculateStrikeMinMax(strikes[3]);

        int pnlAtStrike;

        {
            Strike memory strike;

            for (uint i = 0; i < 4; i++) {
                strike = strikes[i];
                int tempPnlAtStrike;

                tempPnlAtStrike += _calculateAtStrikePriceExpiry(strike.strikePrice, strikes[0]);

                tempPnlAtStrike += _calculateAtStrikePriceExpiry(strike.strikePrice, strikes[1]);

                tempPnlAtStrike += _calculateAtStrikePriceExpiry(strike.strikePrice, strikes[2]);

                tempPnlAtStrike += _calculateAtStrikePriceExpiry(strike.strikePrice, strikes[3]);
            }
        }

        int pnlAtMin = pnlAtMin1 + pnlAtMin2 + pnlAtMin3 + pnlAtMin4;
        int pnlAtMax = pnlAtMax1 + pnlAtMax2 + pnlAtMax3 + pnlAtMax4;

        return _min(pnlAtStrike, _min(pnlAtMin, pnlAtMax));
    }

    function _calculateStrikeMinMax(Strike memory strike) internal pure returns (int, int) {
        uint strikePrice = strike.strikePrice;
        uint amount = strike.amount;
        uint premium = strike.premium;
        uint optionType = strike.optionType;

        bool isBuy = _isLong(optionType);
        bool isCall = _isCall(optionType);

        if (isBuy && isCall) {
            return _calculateLongCallMinMax(strikePrice, amount, premium);
        } else if (isBuy && !isCall) {
            return _calculateLongPutMinMax(strikePrice, amount, premium);
        } else if (!isBuy && isCall) {
            return _calculateShortCallMinMax(strikePrice, amount, premium);
        } else {
            // !isBuy && !isCall
            return _calculateShortPutMinMax(strikePrice, amount, premium);
        }
    }

    function _calculateAtStrikePriceExpiry(uint expiryPrice, Strike memory strike) internal pure returns (int) {
        uint strikePrice = strike.strikePrice;
        uint amount = strike.amount;
        uint premium = strike.premium;
        uint optionType = strike.optionType;

        bool isBuy = _isLong(optionType);
        bool isCall = _isCall(optionType);

        if (isBuy && isCall) {
            return _calculateLongCallAtStrike(expiryPrice, strikePrice, amount, premium);
        } else if (isBuy && !isCall) {
            return _calculateLongPutAtStrike(expiryPrice, strikePrice, amount, premium);
        } else if (!isBuy && isCall) {
            return _calculateShortCallAtStrike(expiryPrice, strikePrice, amount, premium);
        } else {
            // !isBuy && !isCall
            return _calculateShortPutAtStrike(expiryPrice, strikePrice, amount, premium);
        }
    }

    function _calculateLongCallMinMax(
        uint strikePrice,
        uint amount,
        uint premium
    ) internal pure returns (int pnlAtMin, int pnlAtMax) {
        pnlAtMin = -SafeCast.toInt256(premium);
        // use an infinite amount
        pnlAtMax = MAX_VALUE;
    }

    function _calculateLongPutMinMax(
        uint strikePrice,
        uint amount,
        uint premium
    ) internal pure returns (int pnlAtMin, int pnlAtMax) {
        pnlAtMin = SafeCast.toInt256((strikePrice.multiplyDecimal(amount)) - premium);
        pnlAtMax = -SafeCast.toInt256(premium);
    }

    function _calculateShortCallMinMax(
        uint strikePrice,
        uint amount,
        uint premium
    ) internal pure returns (int pnlAtMin, int pnlAtMax) {
        pnlAtMin = SafeCast.toInt256(premium);
        pnlAtMax = -SafeCast.toInt256((strikePrice.multiplyDecimal(amount)) - (premium));
    }

    function _calculateShortPutMinMax(
        uint strikePrice,
        uint amount,
        uint premium
    ) internal pure returns (int pnlAtMin, int pnlAtMax) {
        pnlAtMin = -SafeCast.toInt256((strikePrice.multiplyDecimal(amount)) - (premium.multiplyDecimal(amount)));
        pnlAtMax = SafeCast.toInt256(premium.multiplyDecimal(amount));
    }

    function _calculateLongCallAtStrike(
        uint expiryPrice, // using strike price
        uint strikePricePrimary,
        uint amount,
        uint premium
    ) internal pure returns (int pnlAtStrike) {
        if (expiryPrice >= strikePricePrimary) {
            pnlAtStrike = SafeCast.toInt256((expiryPrice - strikePricePrimary).multiplyDecimal(amount));
            pnlAtStrike -= SafeCast.toInt256(premium);
        } else {
            pnlAtStrike = -SafeCast.toInt256(premium);
        }
    }

    function _calculateLongPutAtStrike(
        uint expiryPrice, // using strike price
        uint strikePricePrimary,
        uint amount,
        uint premium
    ) internal pure returns (int pnlAtStrike) {
        if (expiryPrice > strikePricePrimary) {
            pnlAtStrike = -SafeCast.toInt256(premium);
        } else {
            pnlAtStrike = SafeCast.toInt256((strikePricePrimary - expiryPrice).multiplyDecimal(amount));
            pnlAtStrike -= SafeCast.toInt256(premium);
        }
    }

    function _calculateShortCallAtStrike(
        uint expiryPrice, // using strike price
        uint strikePricePrimary,
        uint amount,
        uint premium
    ) internal pure returns (int pnlAtStrike) {
        if (expiryPrice > strikePricePrimary) {
            pnlAtStrike = -SafeCast.toInt256((expiryPrice - strikePricePrimary).multiplyDecimal(amount));
            pnlAtStrike += SafeCast.toInt256(premium);
        } else {
            pnlAtStrike = SafeCast.toInt256(premium);
        }
    }

    function _calculateShortPutAtStrike(
        uint expiryPrice, // using strike price
        uint strikePricePrimary,
        uint amount,
        uint premium
    ) internal pure returns (int pnlAtStrike) {
        if (expiryPrice > strikePricePrimary) {
            pnlAtStrike = SafeCast.toInt256(premium);
        } else {
            pnlAtStrike = -SafeCast.toInt256((strikePricePrimary - expiryPrice));
            pnlAtStrike += SafeCast.toInt256(premium);
        }
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

    function _min(int x, int y) internal pure returns (int) {
        return (x < y) ? x : y;
    }

    function _abs(int val) internal pure returns (uint) {
        return val >= 0 ? uint(val) : uint(-val);
    }
}
