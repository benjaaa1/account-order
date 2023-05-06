// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../synthetix/SafeDecimalMath.sol";

import "../positions/OtusOptionToken.sol";

/**
 * @title SettlementCalculator
 * @author Otus
 * @notice Calculate settlement amounts from lyra options
 */
contract SettlementCalculator {
    using SafeDecimalMath for uint;

    enum OptionType {
        LONG_CALL,
        LONG_PUT,
        SHORT_CALL_BASE,
        SHORT_CALL_QUOTE,
        SHORT_PUT_QUOTE
    }

    function calculate(
        OtusOptionToken.SettledPosition[] memory optionPositions
    )
        external
        pure
        returns (
            uint totalLPSettlementAmount, // totalPendingCollateral
            uint traderSettlementAmount, // traderProfit
            uint totalCollateral
        )
    {
        for (uint i = 0; i < optionPositions.length; i++) {
            OtusOptionToken.SettledPosition memory settledPosition = optionPositions[i];

            if (settledPosition.optionType == OptionMarket.OptionType.LONG_CALL) {
                traderSettlementAmount += _calculateLongCallProceeds(
                    settledPosition.amount,
                    settledPosition.strikePrice,
                    settledPosition.priceAtExpiry
                );
            } else if (settledPosition.optionType == OptionMarket.OptionType.LONG_PUT) {
                traderSettlementAmount += _calculateLongPutProceeds(
                    settledPosition.amount,
                    settledPosition.strikePrice,
                    settledPosition.priceAtExpiry
                );
            } else if (settledPosition.optionType == OptionMarket.OptionType.SHORT_CALL_QUOTE) {
                (uint collateralSettlementAmount, ) = _calculateShortCallProceeds(
                    settledPosition.collateral,
                    settledPosition.amount,
                    settledPosition.strikePrice,
                    settledPosition.priceAtExpiry
                );
                totalLPSettlementAmount += collateralSettlementAmount;
                totalCollateral += settledPosition.collateral;
            } else if (settledPosition.optionType == OptionMarket.OptionType.SHORT_PUT_QUOTE) {
                // to be recovered (lploss)
                (uint collateralSettlementAmount, ) = _calculateShortPutProceeds(
                    settledPosition.collateral,
                    settledPosition.amount,
                    settledPosition.strikePrice,
                    settledPosition.priceAtExpiry
                );
                totalLPSettlementAmount += collateralSettlementAmount;
                totalCollateral += settledPosition.collateral;
            }
        }
    }

    /// @dev calculates profit made by a long call
    function _calculateLongCallProceeds(
        uint _amount,
        uint _strikePrice,
        uint _priceAtExpiry
    ) internal pure returns (uint settlementAmount) {
        settlementAmount = (_priceAtExpiry > _strikePrice)
            ? (_priceAtExpiry - _strikePrice).multiplyDecimal(_amount)
            : 0;
        return settlementAmount;
    }

    /// @dev calculates profit made by a long put
    function _calculateLongPutProceeds(
        uint _amount,
        uint _strikePrice,
        uint _priceAtExpiry
    ) internal pure returns (uint settlementAmount) {
        settlementAmount = (_strikePrice > _priceAtExpiry)
            ? (_strikePrice - _priceAtExpiry).multiplyDecimal(_amount)
            : 0;
        return settlementAmount;
    }

    /// @dev calculates collateral settlement and collateral loss made by a short call
    /// @dev liquidityPoolLoss priceAtExpiry - strikePrice = liquidity pool loss
    function _calculateShortCallProceeds(
        uint _collateral,
        uint _amount,
        uint _strikePrice,
        uint _priceAtExpiry
    ) internal pure returns (uint collateralSettlementAmount, uint liquidityPoolLoss) {
        // liquidity pool loss (ammProfit)
        liquidityPoolLoss = (_priceAtExpiry > _strikePrice)
            ? (_priceAtExpiry - _strikePrice).multiplyDecimal(_amount)
            : 0;

        collateralSettlementAmount = _collateral - liquidityPoolLoss;
    }

    /// @dev calculates collateral settlement and collateral loss made by a short put
    /// @dev liquidityPoolLoss strikePrice - priceAtExpiry = liquidity pool loss
    function _calculateShortPutProceeds(
        uint _collateral,
        uint _amount,
        uint _strikePrice,
        uint _priceAtExpiry
    ) internal pure returns (uint collateralSettlementAmount, uint liquidityPoolLoss) {
        liquidityPoolLoss = (_priceAtExpiry < _strikePrice)
            ? (_strikePrice - _priceAtExpiry).multiplyDecimal(_amount)
            : 0;
        collateralSettlementAmount = _collateral - liquidityPoolLoss;
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
