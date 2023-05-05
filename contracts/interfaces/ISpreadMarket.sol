//SPDX-License-Identifier:ISC
pragma solidity ^0.8.9;

import {ITradeTypes} from "./ITradeTypes.sol";

/**
 * @title ISpreadMarket
 * @author Otus
 * @notice Spread Options Market Interface
 */
interface ISpreadMarket is ITradeTypes {
    function openPosition(
        TradeInfo memory _tradeInfo,
        TradeInputParameters[] memory shortTrades,
        TradeInputParameters[] memory longTrades
    ) external;

    function closePosition(bytes32 _market, uint _spreadPositionId, TradeInputParameters[] memory _params) external;

    function settleOption(uint _spreadPositionId) external;

    function validMaxLoss(
        bytes32 _market,
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades
    ) external returns (uint maxLoss);

    function validSpread(
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades
    ) external returns (bool);

    function getRequiredCollateralOnClose(
        bytes32 _market,
        TradeInputParameters memory _trade
    ) external returns (uint collateralToRemove, uint setCollateralTo);
}
