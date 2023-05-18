// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

import {ITradeTypes} from "./ITradeTypes.sol";

interface IStrategy is ITradeTypes {
    function open(
        TradeInfo memory tradeInfo,
        TradeInputParameters memory _trade,
        uint round
    ) external returns (uint capitalUsed);

    function close() external;
}
