// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

interface ITradeTypes {
    enum PositionState {
        EMPTY,
        ACTIVE,
        CLOSED,
        LIQUIDATED,
        SETTLED
    }

    enum OptionType {
        LONG_CALL,
        LONG_PUT,
        SHORT_CALL_BASE,
        SHORT_CALL_QUOTE,
        SHORT_PUT_QUOTE
    }

    enum OrderTypes {
        MARKET,
        LIMIT_PRICE,
        LIMIT_VOL,
        TAKE_PROFIT,
        STOP_LOSS
    }

    enum RangedPosition {
        IN,
        OUT
    }

    struct StrikeTradeOrder {
        StrikeTrade strikeTrade;
        bytes32 gelatoTaskId;
        uint committedMargin;
    }

    struct TradeInfo {
        uint positionId;
        bytes32 market;
    }

    struct StrikeTrade {
        OrderTypes orderType;
        bytes32 market;
        uint iterations;
        uint collatPercent;
        uint collateralToAdd;
        uint setCollateralTo;
        uint optionType;
        uint strikeId;
        uint size;
        uint positionId;
        uint tradeDirection;
        uint targetPrice;
        uint targetVolatility;
    }

    struct TradeInputParameters {
        uint strikeId;
        uint positionId;
        uint iterations;
        uint optionType;
        uint amount;
        uint setCollateralTo;
        uint minTotalCost;
        uint maxTotalCost;
        address rewardRecipient;
    }

    struct TradeResult {
        bytes32 market;
        uint positionId;
        uint totalCost;
        uint totalFee;
        uint optionType;
        uint amount;
        uint setCollateralTo;
        uint strikeId;
    }

    struct Pricing {
        uint amount;
        uint slippage;
        uint tradeDirection;
        bool forceClose;
    }

    enum TradeType {
        MULTI,
        SPREAD
    }

    /************************************************
     *  EVENTS
     ***********************************************/

    /// @dev Used by otusOptionMarket and spreadMarkets to log trades
    event Trade(
        address indexed trader,
        uint positionId,
        uint collateralBorrowed, // borrowed
        uint maxCost,
        uint fee,
        TradeType tradeType
    );
}
