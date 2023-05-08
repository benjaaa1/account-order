//SPDX-License-Identifier:ISC
pragma solidity ^0.8.9;

import {ITradeTypes} from "./ITradeTypes.sol";

/**
 * @title IOtusOptionMarket
 * @author Otus
 * @notice Otus Options Market Interface
 */
interface IOtusOptionMarket is ITradeTypes {
    function openPosition(
        TradeInfo memory _tradeInfo,
        TradeInputParameters[] memory shortTrades,
        TradeInputParameters[] memory longTrades
    ) external;

    function settleOption(uint _multiLegPositionId) external;

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
