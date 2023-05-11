// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import {ITradeTypes} from "./ITradeTypes.sol";

interface IStrategy is ITradeTypes {
    function open(
        TradeInfo memory tradeInfo,
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades,
        uint round
    ) external returns (uint capitalUsed);

    function close() external;
}
