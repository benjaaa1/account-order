// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

import "hardhat/console.sol";

// spread market contracts
import {SpreadMaxLossCollateral} from "./SpreadMaxLossCollateral.sol";
import {SpreadOptionToken} from "./SpreadOptionToken.sol";
import {SpreadLiquidityPool} from "./SpreadLiquidityPool.sol";
import {OptionToken} from "@lyrafinance/protocol/contracts/OptionToken.sol";
import {OptionMarket} from "@lyrafinance/protocol/contracts/OptionMarket.sol";

// libraries
import "./synthetix/SafeDecimalMath.sol";
import "./synthetix/SignedDecimalMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./libraries/ConvertDecimals.sol";

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SimpleInitializable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializable.sol";

// interfaces
import "./interfaces/ILyraBase.sol";
import {ITradeTypes} from "./interfaces/ITradeTypes.sol";
import {IOptionMarket} from "@lyrafinance/protocol/contracts/interfaces/IOptionMarket.sol";
import {IERC20Decimals} from "./interfaces/IERC20Decimals.sol";

/**
 * @title SpreadOptionMarket
 * @author Otus
 * @dev Trades, Validates and Settles Spread Options Positions on Lyra.
 */
contract SpreadOptionMarket is Ownable, SimpleInitializable, ReentrancyGuard, ITradeTypes {
    using SafeDecimalMath for uint;
    using SignedDecimalMath for int;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    uint internal constant COLLATERAL_BUFFER = 1e18; // 100%
    uint internal constant COLLATERAL_REQUIRED = 1e18; // 100% more tests required with lower required collateral
    uint private constant ONE_PERCENT = 1e16;

    /************************************************
     *  INIT STATE
     ***********************************************/

    IERC20Decimals public quoteAsset;

    mapping(bytes32 => ILyraBase) public lyraBases;

    SpreadMaxLossCollateral internal spreadMaxLossCollateral;

    SpreadOptionToken internal spreadOptionToken;

    SpreadLiquidityPool internal spreadLiquidityPool;

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    constructor() Ownable() {}

    /// @dev can deposit eth
    receive() external payable onlyOwner {}

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize users account
     * @param _quoteAsset address used as margin asset (USDC / SUSD)
     * @param _ethLyraBase (lyra adapter for eth market)
     * @param _btcLyraBase (lyra adapter for btc market)
     * @param _spreadOptionToken gelato ops address
     * @param _spreadLiquidityPool gelato ops address
     */
    function initialize(
        address _quoteAsset,
        address _ethLyraBase,
        address _btcLyraBase,
        address _spreadMaxLossCollateral,
        address _spreadOptionToken,
        address _spreadLiquidityPool
    ) external onlyOwner initializer {
        quoteAsset = IERC20Decimals(_quoteAsset);
        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);

        spreadMaxLossCollateral = SpreadMaxLossCollateral(_spreadMaxLossCollateral);
        spreadOptionToken = SpreadOptionToken(_spreadOptionToken);
        spreadLiquidityPool = SpreadLiquidityPool(_spreadLiquidityPool);
    }

    /************************************************
     *  TRADE
     ***********************************************/

    /**
     * @notice openPosition
     * @param _tradeInfo position and market info (0 if new position)
     * @param _trades trades
     * @param _maxLossPosted set by trader for spread position (maxloss + maxcost - premium expected + fee)
     * @return positionId is a valid spread
     * @return sellResults
     * @return buyResults
     */
    function openPosition(
        TradeInfo memory _tradeInfo,
        TradeInputParameters[] memory _trades,
        uint _maxLossPosted
    )
        external
        nonReentrant
        returns (uint positionId, TradeResult[] memory sellResults, TradeResult[] memory buyResults)
    {
        // if increasing previous spreadposition id
        // there needs to be more validity checks
        // 1. check increase of tradeinputparemeters is equal across the trades
        if (_tradeInfo.positionId > 0) {
            bool isValidIncrease = validIncrease(_trades);
            if (!isValidIncrease) {
                revert NotValidIncrease(_trades);
                // check if lyra position id exists in spread position id
            }
        }

        // check validity of spread
        (bool isValid, uint totalSells) = validSpread(_trades);

        if (!isValid) {
            revert NotValidSpread(_trades);
        }

        (positionId, sellResults, buyResults) = _openPosition(_tradeInfo, _trades, totalSells, _maxLossPosted);
    }

    /**
     * @notice Handle all settlement between user/spreadoptionmarket/liquidity pool
     * @param _market btc / eth
     * @param _spreadPositionId SpreadOptionToken.SpreadOptionPosition positionId
     * @param _params need to have max cost for close data and strikeid
     * @dev Trader must close all positions on lyra and then settles position on otus option market
     * @dev to do - or they can close equal amounts on all
     * @dev require only trader/owner of position can execute
     */
    function closePosition(
        bytes32 _market,
        uint _spreadPositionId,
        TradeInputParameters[] memory _params
    ) external nonReentrant {
        (uint partialSum, TradeResult[] memory sellCloseResults, TradeResult[] memory buyCloseResults) = _closePosition(
            _market,
            _spreadPositionId,
            _params
        );

        if (partialSum == 0) {
            spreadOptionToken.settlePosition(_spreadPositionId);
        } else {
            // update spread opition token position adjust
            spreadOptionToken.closePosition(
                msg.sender,
                partialSum,
                _spreadPositionId,
                sellCloseResults,
                buyCloseResults
            );
        }
    }

    /// @dev executes close position or force close position on lyra option market
    function _closePosition(
        bytes32 _market,
        uint _spreadPositionId,
        TradeInputParameters[] memory _trades
    ) internal returns (uint partialSum, TradeResult[] memory sellCloseResults, TradeResult[] memory buyCloseResults) {
        SpreadOptionToken.SpreadOptionPosition memory position = spreadOptionToken.getPosition(_spreadPositionId);

        if (position.trader != msg.sender) {
            // only owner can close before settlement
            revert OnlyOwnerCanClose(msg.sender, position.trader);
        }

        uint totalSells;

        for (uint i = 0; i < _trades.length; i++) {
            if (!_isLong(_trades[i].optionType)) {
                totalSells++;
            }
        }

        (TradeInputParameters[] memory shortTrades, TradeInputParameters[] memory longTrades) = buildTrades(
            _trades,
            totalSells
        );

        (partialSum, sellCloseResults, buyCloseResults) = _executeCloseTrade(
            _market,
            position,
            _trades,
            shortTrades,
            longTrades
        );
    }

    function _executeCloseTrade(
        bytes32 _market,
        SpreadOptionToken.SpreadOptionPosition memory position,
        TradeInputParameters[] memory _params,
        TradeInputParameters[] memory shortTrades,
        TradeInputParameters[] memory longTrades
    ) internal returns (uint partialSum, TradeResult[] memory sellCloseResults, TradeResult[] memory buyCloseResults) {
        uint totalPendingCollateral;
        uint totalCollateral;

        (partialSum, sellCloseResults, totalPendingCollateral, totalCollateral) = _closeSellStrikes(
            _market,
            shortTrades
        );

        uint totalTraderProfit;
        uint totalFees;
        (partialSum, buyCloseResults, totalTraderProfit, totalFees) = _closeBuyStrikes(partialSum, _market, longTrades);

        // @dev only allowed to close full position and all positions
        // need to check that trades are closing the same size
        if (partialSum > 0 && !validClose(_params)) {
            revert NotValidPartialClose(_params);
        }

        // add closeBeforeSettlementFlag
        _routeFundsOnClose(position, partialSum, totalTraderProfit, totalCollateral, totalPendingCollateral);
    }

    function _closeBuyStrikes(
        uint _partialSum,
        bytes32 _market,
        TradeInputParameters[] memory longTrades
    ) internal returns (uint partialSum, TradeResult[] memory buyCloseResults, uint totalTraderProfit, uint totalFees) {
        OptionMarket.Result memory result;
        buyCloseResults = new TradeResult[](longTrades.length);
        for (uint i = 0; i < longTrades.length; i++) {
            (, uint amount, ) = getLyraPosition(_market, longTrades[i].positionId);

            if (longTrades[i].amount > amount) {
                revert ClosingMoreThanInPosition();
            }

            // check if any close is less than original position amount
            // set partialclose status
            if (longTrades[i].amount < amount) {
                // used to calcualte maxlossposted owed
                partialSum += longTrades[i].amount;
            }

            OptionMarket optionMarket = OptionMarket(lyraBase(_market).getOptionMarket());

            OptionMarket.TradeInputParameters memory convertedParams = _convertParams(address(this), longTrades[i]);

            bool outsideDeltaCutoff = lyraBase(_market)._isOutsideDeltaCutoff(convertedParams.strikeId);

            if (!outsideDeltaCutoff) {
                result = optionMarket.closePosition(convertedParams);
            } else {
                // will pay less competitive price to close position
                result = optionMarket.forceClosePosition(convertedParams);
            }

            buyCloseResults[i] = TradeResult({
                market: _market,
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee,
                optionType: longTrades[i].optionType,
                amount: longTrades[i].amount,
                setCollateralTo: longTrades[i].setCollateralTo,
                strikeId: longTrades[i].strikeId
            });

            totalTraderProfit = totalTraderProfit + result.totalCost;
            totalFees = totalFees + result.totalFee;
        }

        partialSum += _partialSum;
    }

    function _closeSellStrikes(
        bytes32 _market,
        TradeInputParameters[] memory shortTrades
    )
        internal
        returns (
            uint partialSum,
            TradeResult[] memory sellCloseResults,
            uint totalPendingCollateral,
            uint totalCollateral
        )
    {
        OptionMarket.Result memory result;
        sellCloseResults = new TradeResult[](shortTrades.length);

        for (uint i = 0; i < shortTrades.length; i++) {
            (, uint amount, uint collateral) = getLyraPosition(_market, shortTrades[i].positionId);

            if (shortTrades[i].amount > amount) {
                revert ClosingMoreThanInPosition();
            }

            // check if any close is less than original position amount
            // set partialclose status
            if (shortTrades[i].amount < amount) {
                // used to calcualte maxlossposted owed
                partialSum += shortTrades[i].amount;
            }

            // collateral owed on sell
            (uint collateralToRemove, uint setCollateralTo) = getRequiredCollateralOnClose(_market, shortTrades[i]);

            OptionMarket optionMarket = OptionMarket(lyraBase(_market).getOptionMarket());
            // should set collateral to correctly for full closes too
            if (partialSum > 0) {
                shortTrades[i].setCollateralTo = setCollateralTo;
            }

            OptionMarket.TradeInputParameters memory convertedParams = _convertParams(address(this), shortTrades[i]);

            if (!lyraBase(_market)._isOutsideDeltaCutoff(convertedParams.strikeId)) {
                result = optionMarket.closePosition(convertedParams);
            } else {
                // will pay less competitive price to close position
                result = optionMarket.forceClosePosition(convertedParams);
            }

            sellCloseResults[i] = TradeResult({
                market: _market,
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee,
                optionType: shortTrades[i].optionType,
                amount: shortTrades[i].amount,
                setCollateralTo: shortTrades[i].setCollateralTo,
                strikeId: shortTrades[i].strikeId
            });

            if (partialSum == 0) {
                collateralToRemove = collateral;
            }

            totalPendingCollateral = totalPendingCollateral + (collateralToRemove - result.totalCost);
            // collateral that we return to LP!!!
            totalCollateral = totalCollateral + collateralToRemove;
        }
    }

    /**
     * @notice Execute Trades on Lyra, borrow from LP, with user fees transfer
     * @param _tradeInfo position and market info (0 if new position)
     * @param _trades trades info
     * @param totalSells total sell strike trades counter
     * @param _maxLossPosted max cost set by trader
     * @return positionId spread option position id
     */
    function _openPosition(
        TradeInfo memory _tradeInfo,
        TradeInputParameters[] memory _trades,
        uint totalSells,
        uint _maxLossPosted
    ) internal returns (uint positionId, TradeResult[] memory sellResults, TradeResult[] memory buyResults) {
        (TradeInputParameters[] memory shortTrades, TradeInputParameters[] memory longTrades) = buildTrades(
            _trades,
            totalSells
        );

        // total collateral required
        (uint totalCollateralToAdd, uint totalSetCollateralTo) = _getTotalRequiredCollateral(
            _tradeInfo.market,
            shortTrades
        );

        uint _maxLossPostedCollateral;

        (sellResults, buyResults, _maxLossPostedCollateral) = _executeTrade(
            _tradeInfo.market,
            totalCollateralToAdd,
            _maxLossPosted,
            shortTrades,
            longTrades
        );

        positionId = spreadOptionToken.openPosition(
            _tradeInfo,
            msg.sender,
            sellResults,
            buyResults,
            totalSetCollateralTo, // same as totalCollateralToAdd on new opens
            _maxLossPostedCollateral
        );
    }

    /**
     * @notice executes and routes funds from lp and to lyra option market
     * @param _market eth / btc
     * @param _totalCollateralToAdd collateral to be borrowed from liquidity pool
     * @param _maxLossPosted max loss posted by user including (collateral loss cover + costs + fees) and excluding premiums
     * @param shortTrades trades
     * @param longTrades trades
     * @return sellResults results from selling
     * @return buyResults results from buying
     */
    function _executeTrade(
        bytes32 _market,
        uint _totalCollateralToAdd,
        uint _maxLossPosted,
        TradeInputParameters[] memory shortTrades,
        TradeInputParameters[] memory longTrades
    )
        internal
        returns (TradeResult[] memory sellResults, TradeResult[] memory buyResults, uint maxLossPostedCollateral)
    {
        uint actualCost;
        uint maxCost;
        uint fee;
        uint premiumCollected;
        /// @dev route collateral from liquidity pool
        _routeLPFundsForCollateral(_totalCollateralToAdd);

        (sellResults, premiumCollected) = _sellStrikes(_market, shortTrades);

        /// @dev routes max cost to option market from trader
        /// @dev maxcost - actualcost is sent back to trader
        /// @dev routing is done in _buyStrikes
        (buyResults, actualCost, maxCost) = _buyStrikes(_market, longTrades);

        // fee is calcualted and transferred separately
        // @bug
        maxLossPostedCollateral = _maxLossPosted + premiumCollected - actualCost;

        uint maxLossCollateralRequirement = validMaxLossAndExpiries(
            _market,
            sellResults,
            buyResults,
            _totalCollateralToAdd
        );

        if (maxLossCollateralRequirement > maxLossPostedCollateral) {
            revert MaxLossRequirementNotMet(maxLossCollateralRequirement, _maxLossPosted);
        }

        /// @dev route max loss to short collateral
        /// @dev no need to ask for premiumCollected from user again
        /// @dev maxcost + maxloss - premium = maxlosscollateral needed
        _routeMaxLossCollateralFromTrader(maxLossPostedCollateral - premiumCollected);
        _routeMaxLossCollateralFromMarket(premiumCollected);

        emit Trade(
            msg.sender,
            sellResults,
            buyResults,
            _totalCollateralToAdd, // borrowed
            actualCost,
            fee
        );
    }

    /**
     * @notice Executes Buys
     * @param _longTrades Long trade info
     * @return results
     */
    function _buyStrikes(
        bytes32 _market,
        TradeInputParameters[] memory _longTrades
    ) private returns (TradeResult[] memory results, uint actualCost, uint maxCost) {
        maxCost = _maxCost(_longTrades);

        // routes to this market => then routes to lyra option market
        _routeCostsFromUser(maxCost);

        results = new TradeResult[](_longTrades.length);
        address optionMarket = lyraBase(_market).getOptionMarket();
        quoteAsset.approve(address(optionMarket), type(uint).max);

        for (uint i = 0; i < _longTrades.length; i++) {
            TradeInputParameters memory trade = _longTrades[i];

            OptionMarket.TradeInputParameters memory convertedParams = _convertParams(address(this), trade);

            OptionMarket.Result memory result = OptionMarket(optionMarket).openPosition(convertedParams);

            if (result.totalCost > trade.maxTotalCost) {
                revert PremiumAboveExpected(result.totalCost, trade.maxTotalCost);
            }

            results[i] = TradeResult({
                market: _market,
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee,
                optionType: trade.optionType,
                amount: trade.amount,
                setCollateralTo: trade.setCollateralTo,
                strikeId: trade.strikeId
            });

            actualCost += result.totalCost;
        }

        /// @dev return difference in actual cost from max cost set
        if (maxCost > actualCost) {
            _routeExtraBackToUser(maxCost - actualCost);
        }
    }

    /**
     * @notice Executes Buys
     * @param _shortTrades short trade info
     * @return results
     */
    function _sellStrikes(
        bytes32 _market,
        TradeInputParameters[] memory _shortTrades
    ) private returns (TradeResult[] memory results, uint premiumCollected) {
        address optionMarket = lyraBase(_market).getOptionMarket();
        quoteAsset.approve(address(optionMarket), type(uint).max);

        results = new TradeResult[](_shortTrades.length);

        for (uint i = 0; i < _shortTrades.length; i++) {
            TradeInputParameters memory trade = _shortTrades[i];

            OptionMarket.TradeInputParameters memory convertedParams = _convertParams(address(this), trade);

            OptionMarket.Result memory result = OptionMarket(optionMarket).openPosition(convertedParams);

            if (result.totalCost < trade.minTotalCost) {
                revert PremiumBelowExpected(result.totalCost, trade.minTotalCost);
            }

            results[i] = TradeResult({
                market: _market,
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee,
                optionType: trade.optionType,
                amount: trade.amount,
                setCollateralTo: trade.setCollateralTo,
                strikeId: trade.strikeId
            });

            premiumCollected += result.totalCost;
        }
    }

    /************************************************
     *  UTILS - TRADE EXECUTION
     ***********************************************/
    /// @dev returns sell strikeids, short/long trades and sum of max cost total set by trader
    function buildTrades(
        TradeInputParameters[] memory _trades,
        uint totalSells
    ) internal pure returns (TradeInputParameters[] memory shortTrades, TradeInputParameters[] memory longTrades) {
        shortTrades = new TradeInputParameters[](totalSells);
        longTrades = new TradeInputParameters[](_trades.length - totalSells);
        uint sells;
        uint buys;

        for (uint i = 0; i < _trades.length; i++) {
            if (!_isLong(_trades[i].optionType)) {
                shortTrades[sells] = _trades[i];
                sells++;
            } else {
                longTrades[buys] = _trades[i];
                buys++;
            }
        }
    }

    // @dev helper method to sum up max cost limit of long trades
    function _maxCost(TradeInputParameters[] memory _trades) internal pure returns (uint maxCost) {
        for (uint i = 0; i < _trades.length; i++) {
            if (_isLong(_trades[i].optionType)) {
                maxCost += _trades[i].maxTotalCost;
            }
        }
    }

    /************************************************
     *  SETTLEMENT
     ***********************************************/
    /**
     * @notice Settles positions in spread option market
     * @dev Only settles if all lyra positions are settled
     * @param _spreadPositionId position id in SpreadOptionToken
     */
    function settleOption(uint _spreadPositionId) external nonReentrant {
        SpreadOptionToken.SpreadOptionPosition memory position = spreadOptionToken.getPosition(_spreadPositionId);

        // reverts if positions are not settled in lyra
        SpreadOptionToken.SettledPosition[] memory optionPositions = spreadOptionToken.checkLyraPositionsSettled(
            _spreadPositionId
        );

        spreadOptionToken.settlePosition(_spreadPositionId);

        uint totalLPSettlementAmount; // totalPendingCollateral
        uint totalLPLossToBeRecovered; // collateralToRecover
        uint traderSettlementAmount; // traderProfit
        uint totalCollateral;

        for (uint i = 0; i < optionPositions.length; i++) {
            SpreadOptionToken.SettledPosition memory settledPosition = optionPositions[i];

            if (settledPosition.optionType == OptionMarket.OptionType.LONG_CALL) {
                traderSettlementAmount =
                    traderSettlementAmount +
                    _calculateLongCallProceeds(
                        settledPosition.amount,
                        settledPosition.strikePrice,
                        settledPosition.priceAtExpiry
                    );
            } else if (settledPosition.optionType == OptionMarket.OptionType.LONG_PUT) {
                traderSettlementAmount =
                    traderSettlementAmount +
                    _calculateLongPutProceeds(
                        settledPosition.amount,
                        settledPosition.strikePrice,
                        settledPosition.priceAtExpiry
                    );
            } else if (settledPosition.optionType == OptionMarket.OptionType.SHORT_CALL_QUOTE) {
                (uint collateralSettlementAmount, uint lpLoss) = _calculateShortCallProceeds(
                    settledPosition.collateral,
                    settledPosition.amount,
                    settledPosition.strikePrice,
                    settledPosition.priceAtExpiry
                );
                totalLPSettlementAmount = totalLPSettlementAmount + collateralSettlementAmount;
                totalLPLossToBeRecovered = totalLPLossToBeRecovered + lpLoss;
                totalCollateral += settledPosition.collateral;
            } else if (settledPosition.optionType == OptionMarket.OptionType.SHORT_PUT_QUOTE) {
                // to be recovered (lploss)
                (uint collateralSettlementAmount, uint lpLoss) = _calculateShortPutProceeds(
                    settledPosition.collateral,
                    settledPosition.amount,
                    settledPosition.strikePrice,
                    settledPosition.priceAtExpiry
                );
                totalLPSettlementAmount = totalLPSettlementAmount + collateralSettlementAmount;
                totalLPLossToBeRecovered = totalLPLossToBeRecovered + lpLoss;
                totalCollateral += settledPosition.collateral;
            }
        }

        // @dev totalLPLossToBeRecovered - funds not returned from collateral locked
        // @dev totalLPSettlementAmount - collateral returned
        // @dev traderSettlementAmount usually when loss there is a profit
        _routeFundsOnClose(position, 0, traderSettlementAmount, totalCollateral, totalLPSettlementAmount);
    }

    /// @dev spread option state
    function getOptionStatus(uint _spreadPositionId) public view returns (PositionState state) {
        SpreadOptionToken.SpreadOptionPosition memory position = spreadOptionToken.getPosition(_spreadPositionId);
        return position.state;
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

    /************************************************
     *  ON CLOSE/SETTLEMENT FUNDS ROUTING
     ***********************************************/

    /**
     * @notice routes funds to liquidity pool, and to the trader
     * @param partialSum if greater than 0 it is not a full close
     * @param totalTraderProfit profit from closing position
     * @param totalCollateral original collateral
     * @param totalPendingCollateral all collateral returned from lyra option market by closing
     * @dev include a fee on profit and partial close
     */
    function _routeFundsOnClose(
        SpreadOptionToken.SpreadOptionPosition memory position,
        uint partialSum,
        uint totalTraderProfit,
        uint totalCollateral,
        uint totalPendingCollateral
    ) internal {
        int traderTotal = SafeCast.toInt256(totalTraderProfit);
        // @dev totalPendingCollateral - collateral released by lyra market
        // @dev totalCollateral - collateral originally lent
        int collateralToRecover = SafeCast.toInt256(totalCollateral) - SafeCast.toInt256(totalPendingCollateral);
        // @dev return collateral to liquidity pool

        _routeCollateralToLP(totalPendingCollateral);

        /**
         * @notice Origin of available funds during close
         * 1. Lyra Option Market (returned collateral and profit)
         * 2. From max loss collateral
         */

        /**
         * @notice Funds source
         * 1. In spread option market (this)
         * 2. In max loss collateral contract
         * 3. Insolvent
         */

        /**
         * @notice Possible loss recovery scenarios
         * 1. Trader In Profit
         * 1.a. Trader profit can cover collateralToRecover
         * 1.b. Trader profit cannot recovery collateralToRecover
         * 2. Trader Not In Profit
         * 2.a. Max loss posted can cover collateralToRecover
         */

        // calculate all possible funds for lp and trader
        uint percentageOwed = partialSum > 0 ? partialSum.divideDecimal(position.size) : SafeDecimalMath.UNIT;

        int availableMaxLoss = SafeCast.toInt256(position.maxLossPosted.multiplyDecimal(percentageOwed));

        // first need to find out if we have enough to cover lps
        // @bug settlement before expiry can also be partial sum 0
        if (partialSum > 0 && (traderTotal + availableMaxLoss - collateralToRecover < 0)) {
            // Because of fees and closing with LyraAmm
            // settlement is more likely to be solvent for LPs
            revert PositionInsolventBeforeSettlement();
        }

        int fundsAfterMaxLossCollateralCover = _routeAvailableMaxLossOnClose(availableMaxLoss, collateralToRecover);

        int amountInsolvent = _routeAvailableTraderFundsOnClose(
            position.trader,
            traderTotal,
            fundsAfterMaxLossCollateralCover
        );

        if (amountInsolvent < 0) {
            emit LPInsolvent(uint(-amountInsolvent));
        }
    }

    /// @dev routes available max loss left over and trader profit to trader
    /// @dev routes to lp if fundsAfterMaxLossCollateralCover < 0 (not enough to cover)
    function _routeAvailableTraderFundsOnClose(
        address _trader,
        int traderTotal,
        int fundsAfterMaxLossCollateralCover
    ) internal returns (int amountInsolvent) {
        if (fundsAfterMaxLossCollateralCover > 0) {
            // send to trader from max loss collateral
            _routeMaxLossCollateralToTrader(_trader, SafeDecimalMath.UNIT, uint(fundsAfterMaxLossCollateralCover));
            _routeFundsToTrader(_trader, uint(traderTotal));
        } else {
            _routeCollateralToLP(uint(-fundsAfterMaxLossCollateralCover));
            _routeFundsToTrader(_trader, uint(traderTotal + fundsAfterMaxLossCollateralCover));

            amountInsolvent = fundsAfterMaxLossCollateralCover + traderTotal;
        }
    }

    /// @dev routes available max loss collatreal to liquidity pool
    function _routeAvailableMaxLossOnClose(
        int availableMaxLoss,
        int collateralToRecover
    ) internal returns (int fundsAfterMaxLossCollateralCover) {
        // = 400 - 300 = 100 usd left over (send to trader)
        // = 400 - 500 = -100 usd left to cover (send 400 to lp) (recover 100 from trader profit)
        fundsAfterMaxLossCollateralCover = availableMaxLoss - collateralToRecover;

        if (fundsAfterMaxLossCollateralCover > 0) {
            _routeMaxLossCollateralToLP(uint(collateralToRecover));
            // fundsAfterMaxLossCollateralCover is positive meaning there was enough to cover collateral
        } else {
            _routeMaxLossCollateralToLP(uint(availableMaxLoss));
            // fundsAfterMaxLossCollateralCover is negative meaning there wasn't enough to cover collateral lost
        }
    }

    /************************************************
     *  TRANSFER FUNDS
     ***********************************************/

    /**
     * @notice Transfer max loss posted to LP and frees pool liquidity
     */
    function _routeMaxLossCollateralToLP(uint _amount) internal {
        spreadMaxLossCollateral.sendQuoteToLiquidityPool(_amount);
        spreadLiquidityPool.freeLockedLiquidity(_amount);
    }

    /**
     * @notice transfers additional collateral required to close from trader
     */
    function _routeCollateralToLPFromUser(uint _amount) internal {
        _amount = ConvertDecimals.convertFrom18AndRoundUp(_amount, quoteAsset.decimals());
        // current quote asset is holding in 6 decimals no need to convert
        if (!quoteAsset.transferFrom(msg.sender, address(spreadLiquidityPool), _amount)) {
            revert TransferFundsFromTraderFailed(msg.sender, _amount);
        }

        spreadLiquidityPool.freeLockedLiquidity(_amount);
    }

    /**
     * @notice Transfer funds from LP to this contract
     * @param _amount total collateral requested
     */
    function _routeLPFundsForCollateral(uint _amount) private {
        // transfer LP funds to optionmarket and lock liquidity
        spreadLiquidityPool.transferShortCollateral(_amount);
    }

    /**
     * @notice Transfer funds to Liquidity Pool from market
     * @param _amount total collateral returned
     */
    function _routeCollateralToLP(uint _amount) internal {
        _amount = ConvertDecimals.convertFrom18AndRoundUp(_amount, quoteAsset.decimals());

        // @dev free locked liquidity
        if (!quoteAsset.transfer(address(spreadLiquidityPool), _amount)) {
            revert TransferCollateralToLPFailed(_amount);
        }
        spreadLiquidityPool.freeLockedLiquidity(_amount);
    }

    /**
     * @notice Transfer funds from user to cover options costs
     */
    function _routeCostsFromUser(uint _amount) internal {
        _amount = ConvertDecimals.convertFrom18AndRoundUp(_amount, quoteAsset.decimals());
        // current quote asset is holding in 6 decimals no need to convert
        if (!quoteAsset.transferFrom(msg.sender, address(this), _amount)) {
            revert TransferFundsFromTraderFailed(msg.sender, _amount);
        }
    }

    function _routeExtraBackToUser(uint _amount) internal {
        _amount = ConvertDecimals.convertFrom18(_amount, quoteAsset.decimals());
        if (!quoteAsset.transfer(msg.sender, _amount)) {
            revert TransferFundsToTraderFailed(msg.sender, _amount);
        }
    }

    function _calculateFeesAndRouteFundsFromUser(uint _collateral, uint _maxExpiry) internal {
        uint fee = spreadLiquidityPool.calculateCollateralFee(_collateral, _maxExpiry);
        fee = ConvertDecimals.convertFrom18AndRoundUp(fee, quoteAsset.decimals());
        // current quote asset is holding in 6 decimals no need to convert

        if (!quoteAsset.transferFrom(msg.sender, address(spreadLiquidityPool), fee)) {
            revert TransferFundsFromTraderFailed(msg.sender, fee);
        }
    }

    /**
     * @notice transfer funds from trader to max loss
     */
    function _routeMaxLossCollateralFromTrader(uint _amount) internal {
        _amount = ConvertDecimals.convertFrom18AndRoundUp(_amount, quoteAsset.decimals());
        // current quote asset is holding in 6 decimals no need to convert

        if (!quoteAsset.transferFrom(msg.sender, address(spreadMaxLossCollateral), _amount)) {
            revert TransferFundsFromTraderFailed(msg.sender, _amount);
        }
    }

    /**
     * @notice Routes collateral back to trader on close or settlement
     * @dev rewrite this to make calculation outside
     */
    function _routeMaxLossCollateralToTrader(address _trader, uint percentageOwed, uint maxLossPosted) internal {
        // transfer/add max loss to trader if partial close then get percentage to return
        spreadMaxLossCollateral.sendQuoteToTrader(_trader, maxLossPosted.multiplyDecimal(percentageOwed));
    }

    function _routeMaxLossCollateralFromMarket(uint _amount) internal {
        _amount = ConvertDecimals.convertFrom18AndRoundUp(_amount, quoteAsset.decimals());
        if (!quoteAsset.transfer(address(spreadMaxLossCollateral), _amount)) {
            // update this revert error
            revert TransferCollateralToLPFailed(_amount);
        }
    }

    function _routeFundsToTrader(address _trader, uint _amount) internal {
        _amount = ConvertDecimals.convertFrom18AndRoundUp(_amount, quoteAsset.decimals());
        if (!quoteAsset.transfer(_trader, _amount)) {
            revert TransferFundsToTraderFailed(_trader, _amount);
        }
    }

    /************************************************
     *  CAULCULATE FEES
     ***********************************************/

    function stakeLyra(uint) external {
        // transfer lyra to this
        // stkLyraOtus token needs to be minted for accounting
        // Trading rewards
        // https://app.lyra.finance/#/rewards/trading/optimism 47.5% fee rebate for 100,000
    }

    /************************************************
     *  VALIDATE SPREAD TRADE
     ***********************************************/
    /**
     * @notice Sums up max loss for each side of spread
     * @dev This validation is run after validSpread checks
     * @param _market market
     * @param _sellResults results from buys
     * @param _buyResults results from buys
     */
    function validMaxLossAndExpiries(
        bytes32 _market,
        TradeResult[] memory _sellResults,
        TradeResult[] memory _buyResults,
        uint _totalCollateralToAdd
    ) internal returns (uint maxLoss) {
        TradeResult memory result;
        int maxLossCall;
        int maxLossPut;
        uint shortExpiry;
        uint longExpiry;

        ILyraBase _lyraBase = lyraBase(_market);

        if (_sellResults.length == 0) {
            return (0);
        }

        uint shortCallCount;
        uint shortPutCount;

        for (uint i = 0; i < _sellResults.length; i++) {
            result = _sellResults[i];

            ILyraBase.Strike memory strike = _lyraBase.getStrike(result.strikeId);

            int strikePriceTotal = SafeCast.toInt256(strike.strikePrice.multiplyDecimal(result.amount));

            if (_isCall(result.optionType)) {
                maxLossCall = maxLossCall - strikePriceTotal;
                shortCallCount += result.amount; // add amount
            } else {
                maxLossPut = maxLossPut - strikePriceTotal;
                shortPutCount += result.amount;
            }

            shortExpiry = shortExpiry > strike.expiry ? shortExpiry : strike.expiry;
        }

        uint longCallCount;
        uint longPutCount;

        for (uint i = 0; i < _buyResults.length; i++) {
            result = _buyResults[i];

            ILyraBase.Strike memory strike = _lyraBase.getStrike(result.strikeId);

            uint strikePrice = strike.strikePrice;
            int strikePriceTotal = SafeCast.toInt256(strike.strikePrice.multiplyDecimal(result.amount));

            if (_isCall(result.optionType)) {
                longCallCount += result.amount;
                if (longCallCount <= shortCallCount) {
                    maxLossCall = maxLossCall + strikePriceTotal;
                    shortCallCount -= longCallCount;
                } else if (maxLossCall > 0) {
                    maxLossCall =
                        maxLossCall +
                        SafeCast.toInt256(strikePrice.multiplyDecimal(longCallCount - shortCallCount));
                }
            } else {
                longPutCount += result.amount;
                if (longPutCount <= shortPutCount) {
                    maxLossPut = maxLossPut + strikePriceTotal;
                    shortPutCount -= longPutCount;
                } else {
                    maxLossPut =
                        maxLossPut +
                        SafeCast.toInt256(strikePrice.multiplyDecimal(longPutCount - shortPutCount));
                }
            }

            longExpiry = longExpiry > strike.expiry ? longExpiry : strike.expiry;
        }

        if (longExpiry > 0 && longExpiry < shortExpiry) {
            revert InvalidLongExpiry(longExpiry, shortExpiry);
        }

        if (maxLossCall < 0) {
            maxLossCall = 0;
        }

        /// @dev route fees from user to lp (calculate to )
        if (_totalCollateralToAdd > 0) {
            _calculateFeesAndRouteFundsFromUser(_totalCollateralToAdd, shortExpiry);
        }

        // expiry = shortExpiry;
        maxLoss = _abs(maxLossCall) > _abs(maxLossPut) ? _abs(maxLossCall) : _abs(maxLossPut);
    }

    /**
     * @notice validates equal sizes
     * @param _trades trades
     * @return isValid is a valid spread
     * @return totalSells total trades
     */
    function validSpread(TradeInputParameters[] memory _trades) public pure returns (bool isValid, uint totalSells) {
        uint tradesLen = _trades.length;
        TradeInputParameters memory trade;

        uint buyCallAmount;
        uint sellCallAmount;
        uint buyPutAmount;
        uint sellPutAmount;
        uint sells;

        for (uint i = 0; i < tradesLen; i++) {
            trade = _trades[i];

            if (OptionType(trade.optionType) == OptionType.LONG_CALL) {
                buyCallAmount = buyCallAmount + trade.amount;
            } else if (OptionType(trade.optionType) == OptionType.SHORT_CALL_QUOTE) {
                sellCallAmount = sellCallAmount + trade.amount;
                sells++;
            } else if (OptionType(trade.optionType) == OptionType.LONG_PUT) {
                buyPutAmount = buyPutAmount + trade.amount;
            } else if (OptionType(trade.optionType) == OptionType.SHORT_PUT_QUOTE) {
                sellPutAmount = sellPutAmount + trade.amount;
                sells++;
            }
        }

        if (buyCallAmount < sellCallAmount) {
            return (false, 0);
        }

        if (buyPutAmount < sellPutAmount) {
            return (false, 0);
        }

        return (true, sells);
    }

    /**
     * @notice validate increase is valid
     * @dev Used to support ranged markets
     * @dev must have a lyra position id
     * @dev last example would pass validIncrease check but wouldn't pass validSpread (even if it might be valid)
     * @dev must also have position ids set
     * @param _trades trades
     */
    function validIncrease(TradeInputParameters[] memory _trades) internal pure returns (bool) {
        for (uint i = 0; i < _trades.length; i++) {
            TradeInputParameters memory trade = _trades[i];
            if (trade.positionId == 0) {
                // should have lyra position id
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Equal amount required when partial close
     */
    function validClose(TradeInputParameters[] memory _params) internal pure returns (bool) {
        TradeInputParameters memory param;
        uint equalCloseAmount;

        for (uint i = 0; i < _params.length; i++) {
            param = _params[i];
            if (equalCloseAmount == 0) {
                equalCloseAmount = param.amount;
                continue;
            }

            if (equalCloseAmount != param.amount) {
                return false;
            }
        }

        return true;
    }

    /************************************************
     *  lyra quoter
     ***********************************************/

    /**
     * @notice gets quote for trade
     */
    function getQuote(
        bytes32 _market,
        uint strikeId,
        uint optionType,
        Pricing memory pricing
    ) public view returns (uint totalPremium, uint totalFees) {
        (totalPremium, totalFees) = lyraBase(_market).getQuote(
            strikeId,
            1,
            optionType,
            pricing.amount,
            pricing.tradeDirection, // 0 open 1 close 2 liquidate
            pricing.forceClose
        );
    }

    /************************************************
     *  COLLATERAL REQUIREMENTS
     ***********************************************/
    /**
     * @notice gets required collateral for a position
     * @param _market btc/eth
     * @param _trade trade attempted
     * @return collateralToAdd additional collateral required (collateralToAdd = setCollateralTo - existingCollateral)
     * @return setCollateralTo total collateral required for position
     */
    function _getRequiredCollateral(
        bytes32 _market,
        TradeInputParameters memory _trade
    )
        internal
        view
        returns (
            // uint _strikePrice,
            // uint _expiry
            uint collateralToAdd,
            uint setCollateralTo
        )
    {
        ILyraBase.Strike memory strike = lyraBase(_market).getStrike(_trade.strikeId);

        (collateralToAdd, setCollateralTo) = lyraBase(_market).getRequiredCollateral(
            _trade.amount,
            _trade.optionType,
            _trade.positionId,
            strike.strikePrice,
            strike.expiry,
            COLLATERAL_BUFFER,
            COLLATERAL_REQUIRED
        );
    }

    /**
     * @notice gets required collateral for a position to be left on close
     * @param _market btc/eth
     * @param _trade trade attempted
     * @return collateralToRemove additional collateral required (collateralToAdd = setCollateralTo - existingCollateral)
     * @return setCollateralTo total collateral required for position
     */
    function getRequiredCollateralOnClose(
        bytes32 _market,
        TradeInputParameters memory _trade
    ) public view returns (uint collateralToRemove, uint setCollateralTo) {
        ILyraBase.Strike memory strike = lyraBase(_market).getStrike(_trade.strikeId);

        (collateralToRemove, setCollateralTo) = lyraBase(_market).getRequiredCollateralClose(
            _trade.amount,
            _trade.optionType,
            _trade.positionId,
            strike.strikePrice,
            strike.expiry,
            COLLATERAL_BUFFER
        );
    }

    /**
     *
     * @param _trades can hold multiple markets
     * @param _market btc eth
     * @return totalCollateralToAdd total required from user/liquidity pool
     * @return totalSetCollateralTo total for all strikes and markets to set in lyra option market
     */
    function _getTotalRequiredCollateral(
        bytes32 _market,
        TradeInputParameters[] memory _trades
    ) internal view returns (uint totalCollateralToAdd, uint totalSetCollateralTo) {
        if (_trades.length > 0) {
            // ILyraBase.Strike[] memory strikes = lyraBase(_market).getStrikes(_strikeIds);

            for (uint i = 0; i < _trades.length; i++) {
                TradeInputParameters memory trade = _trades[i];
                (uint collateralToAdd, uint setCollateralTo) = _getRequiredCollateral(_market, trade);
                // @dev currently used for testing ranged markets
                setCollateralTo = setCollateralTo;
                collateralToAdd = collateralToAdd;
                trade.setCollateralTo = setCollateralTo;
                totalCollateralToAdd = totalCollateralToAdd + collateralToAdd;
                totalSetCollateralTo = totalSetCollateralTo + setCollateralTo;
            }
        }
    }

    /************************************************
     *  MISC
     ***********************************************/

    function _abs(int val) internal pure returns (uint) {
        return val >= 0 ? uint(val) : uint(-val);
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

    function _convertParams(
        address referrer,
        TradeInputParameters memory _params
    ) internal pure returns (OptionMarket.TradeInputParameters memory) {
        return
            OptionMarket.TradeInputParameters({
                strikeId: _params.strikeId,
                positionId: _params.positionId,
                iterations: _params.iterations,
                optionType: OptionMarket.OptionType(uint(_params.optionType)),
                amount: _params.amount,
                setCollateralTo: _params.setCollateralTo,
                minTotalCost: _params.minTotalCost,
                maxTotalCost: _params.maxTotalCost,
                referrer: referrer
            });
    }

    /************************************************
     *  Internal Helpers - Lyra
     ***********************************************/

    /**
     * @notice get lyrabase methods
     * @param market market (btc / eth bytes32)
     * @return ILyraBase interface
     */
    function lyraBase(bytes32 market) internal view returns (ILyraBase) {
        require(address(lyraBases[market]) != address(0), "LyraBase: Not available");
        return lyraBases[market];
    }

    /**
     * @notice Used internally
     * @param _market btc / eth
     * @param positionId lyra positionid
     */
    function getLyraPosition(
        bytes32 _market,
        uint positionId
    ) internal view returns (OptionMarket.OptionType optionType, uint amount, uint collateral) {
        (, , optionType, amount, collateral, ) = OptionToken(lyraBase(_market).getOptionToken()).positions(positionId);
    }

    /************************************************
     *  EVENTS
     ***********************************************/
    /// @dev
    event Trade(
        address indexed trader,
        TradeResult[] sellResults,
        TradeResult[] buyResults,
        uint totalCollateralToAdd, // borrowed
        uint fee,
        uint maxCost
    );

    event LPInsolvent(uint amountInsolvent);

    /************************************************
     *  ERRORS
     ***********************************************/
    error PositionInsolventBeforeSettlement();

    error NotAbleToSell();

    error InvalidLongExpiry(uint longCallExpiry, uint shortCallExpiry);

    error InvalidLongCallExpiry(uint longCallExpiry, uint shortCallExpiry);

    error InvalidLongPutExpiry(uint longPutExpiry, uint shortPutExpiry);

    /// @notice cannot execute invalid order
    /// @param _trades trades attempted
    error NotValidSpread(TradeInputParameters[] _trades);

    /// @notice failed single market check
    /// @param _trades trades attempted
    error NotSingleMarketTrade(TradeInputParameters[] _trades);

    /// @notice no free funds available from lp
    /// @param _collateralToAdd collateral to add
    /// @param _freeCollateral collateral available in lp
    error FreeCollateralNotAvailable(uint _collateralToAdd, uint _freeCollateral);

    /// @notice premium below expected
    /// @param actual actual premium
    /// @param expected expected premium
    error PremiumBelowExpected(uint actual, uint expected);

    /// @notice price above expected
    /// @param actual actual premium
    /// @param expected expected premium
    error PremiumAboveExpected(uint actual, uint expected);

    /// @notice returning funds failed
    /// @param amount amount in quoteasset
    error TransferCollateralToLPFailed(uint amount);

    /// @notice sending profits failed
    /// @param trader address of owner
    /// @param amount amount in quoteasset
    error TransferFundsToTraderFailed(address trader, uint amount);

    /// @notice transfer from trader
    /// @param trader address of owner
    /// @param amount amount in quoteasset
    error TransferFundsFromTraderFailed(address trader, uint amount);

    /// @notice attempted to close position not owned
    /// @param thrower attempted by
    /// @param trader owned by
    error OnlyOwnerCanClose(address thrower, address trader);

    /// @notice posted less than calculated
    /// @param requiredMaxLossPost calculated
    /// @param maxLossPosted posted by user
    error MaxLossRequirementNotMet(uint requiredMaxLossPost, uint maxLossPosted);

    /// @notice max loss collateral transfer failed during trade
    /// @param thrower address of owner
    error MaxLossCollateralTransferFailed(address thrower);

    error NotValidIncrease(TradeInputParameters[] _trades);

    error ClosingMoreThanInPosition();
    error NotValidPartialClose(TradeInputParameters[] _params);
    error NotAbleToPartialClose();
}
