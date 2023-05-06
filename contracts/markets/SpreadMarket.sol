// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

import "hardhat/console.sol";

import {OtusManager} from "../OtusManager.sol";

// spread market contracts
import {SpreadMaxLossCollateral} from "../pools/SpreadMaxLossCollateral.sol";
import {OtusOptionToken} from "../positions/OtusOptionToken.sol";
import {SpreadLiquidityPool} from "../pools/SpreadLiquidityPool.sol";
import {OptionToken} from "@lyrafinance/protocol/contracts/OptionToken.sol";
import {OptionMarket} from "@lyrafinance/protocol/contracts/OptionMarket.sol";
import {ConvertDecimals} from "../libraries/ConvertDecimals.sol";

// libraries
import "../synthetix/SafeDecimalMath.sol";
import "../synthetix/SignedDecimalMath.sol";
import "../interfaces/IMaxLossCalculator.sol";
import "../interfaces/ISettlementCalculator.sol";

import "@openzeppelin/contracts/utils/math/SafeCast.sol";

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SimpleInitializable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializable.sol";

// interfaces
import "../interfaces/ILyraBase.sol";
import {ITradeTypes} from "../interfaces/ITradeTypes.sol";
import {IOptionMarket} from "@lyrafinance/protocol/contracts/interfaces/IOptionMarket.sol";
import {IERC20Decimals} from "../interfaces/IERC20Decimals.sol";

/**
 * @title SpreadMarket
 * @author Otus
 * @dev Trades, Validates and Settles Spread Options Positions on Lyra and Other platforms.
 */
contract SpreadMarket is Ownable, SimpleInitializable, ReentrancyGuard, ITradeTypes {
    using SafeDecimalMath for uint;
    using SignedDecimalMath for int;

    /************************************************
     *  INIT STATE
     ***********************************************/

    IERC20Decimals public quoteAsset;

    mapping(bytes32 => ILyraBase) internal lyraBases;

    SpreadMaxLossCollateral internal spreadMaxLossCollateral;

    SpreadLiquidityPool internal spreadLiquidityPool;

    OtusOptionToken internal otusOptionToken;

    OtusManager internal otusManager;

    address internal maxLossCalculator;

    address internal settlementCalculator;

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    constructor() Ownable() {}

    /// @dev can deposit eth
    receive() external payable {}

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize users account
     * @param _quoteAsset address used as margin asset (USDC / SUSD)
     * @param _ethLyraBase (lyra adapter for eth market)
     * @param _btcLyraBase (lyra adapter for btc market)
     * @param _otusOptionToken option token address
     * @param _spreadLiquidityPool liquidity pool address
     * @param _maxLossCalculator max loss calculator address
     */
    function initialize(
        address _otusManager,
        address _quoteAsset,
        address _ethLyraBase,
        address _btcLyraBase,
        address _spreadMaxLossCollateral,
        address _otusOptionToken,
        address _spreadLiquidityPool,
        address _maxLossCalculator,
        address _settlementCalculator
    ) external onlyOwner initializer {
        otusManager = OtusManager(_otusManager);
        quoteAsset = IERC20Decimals(_quoteAsset);
        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);

        spreadMaxLossCollateral = SpreadMaxLossCollateral(_spreadMaxLossCollateral);
        otusOptionToken = OtusOptionToken(_otusOptionToken);
        spreadLiquidityPool = SpreadLiquidityPool(_spreadLiquidityPool);
        maxLossCalculator = _maxLossCalculator;
        settlementCalculator = _settlementCalculator;

        address ethOptionMarket = lyraBase(bytes32("ETH")).getOptionMarket();

        if (address(ethOptionMarket) != address(0)) {
            quoteAsset.approve(address(ethOptionMarket), type(uint).max);
        }

        address btcOptionMarket = lyraBase(bytes32("BTC")).getOptionMarket();
        if (address(btcOptionMarket) != address(0)) {
            quoteAsset.approve(address(btcOptionMarket), type(uint).max);
        }
    }

    /************************************************
     *  TRADE
     ***********************************************/

    /**
     * @notice openPosition
     * @param _tradeInfo position and market info (0 if new position)
     * @param shortTrades trades
     * @param longTrades trades
     */
    function openPosition(
        TradeInfo memory _tradeInfo,
        TradeInputParameters[] memory shortTrades,
        TradeInputParameters[] memory longTrades
    ) external nonReentrant {
        if ((shortTrades.length + longTrades.length) > otusManager.maxTrades()) {
            revert("NotValidTradeSize");
        }

        // if increasing previous spreadposition id
        // there needs to be more validity checks
        // 1. check increase of tradeinputparemeters is equal across the trades
        if (_tradeInfo.positionId > 0) {
            bool isValidIncrease = validIncrease(shortTrades, longTrades);
            if (!isValidIncrease) {
                revert("NotValidIncrease");
            }
        }

        // check validity of spread
        bool isValid = validSpread(shortTrades, longTrades);

        if (!isValid) {
            revert("NotValidSpread");
        }

        // @todo bug when calculating max loss for multiple amounts
        // @dev currently if you send maxTotalCost for longs it can be set to a large amount
        // trades are made and vali
        uint maxLoss = validMaxLoss(_tradeInfo.market, shortTrades, longTrades);
        // routes to this market => then routes to lyra option market
        _routeCostsFromUser(maxLoss);

        _openPosition(_tradeInfo, shortTrades, longTrades, maxLoss);
    }

    function _calculateFees(
        bytes32 _market,
        uint _totalCollateralToAdd,
        TradeResult[] memory _sellResults
    ) internal returns (uint fee) {
        uint shortExpiry;
        TradeResult memory result;

        ILyraBase _lyraBase = lyraBase(_market);

        for (uint i = 0; i < _sellResults.length; i++) {
            result = _sellResults[i];
            ILyraBase.Strike memory strike = _lyraBase.getStrike(result.strikeId);
            shortExpiry = shortExpiry > strike.expiry ? shortExpiry : strike.expiry;
        }

        fee = _calculateFeesAndRouteFundsFromUser(_totalCollateralToAdd, shortExpiry);
    }

    /**
     * @notice Execute Trades on Lyra, borrow from LP, with user fees transfer
     * @param _tradeInfo position and market info (0 if new position)
     * @param shortTrades trades info
     * @param longTrades trades info
     * @param maxLoss max loss of position
     */
    function _openPosition(
        TradeInfo memory _tradeInfo,
        TradeInputParameters[] memory shortTrades,
        TradeInputParameters[] memory longTrades,
        uint maxLoss
    ) internal {
        TradeResult[] memory sellResults;
        TradeResult[] memory buyResults;
        uint actualCost;
        uint premiumReceived;
        // total collateral required
        (uint totalCollateralToAdd, uint totalSetCollateralTo) = _getTotalRequiredCollateral(
            _tradeInfo.market,
            shortTrades
        );

        /// @dev route collateral from liquidity pool
        _routeLPFundsForCollateral(totalCollateralToAdd);

        (actualCost, premiumReceived, sellResults, buyResults) = _executeTrade(
            _tradeInfo.market,
            shortTrades,
            longTrades
        );

        /// @todo route collateral fee from trader
        uint fee;
        if (totalCollateralToAdd > 0) {
            fee = _calculateFees(_tradeInfo.market, totalCollateralToAdd, sellResults);
        }

        // will be more than 0 if successfull trades have processed
        uint maxLossPostedCollateral = maxLoss + premiumReceived - actualCost;
        if (maxLossPostedCollateral > 0) {
            _routeMaxLossCollateralFromMarket(maxLossPostedCollateral);
        }

        uint positionId = otusOptionToken.openPosition(
            _tradeInfo,
            msg.sender,
            sellResults,
            buyResults,
            totalSetCollateralTo, // same as totalCollateralToAdd on new opens
            maxLossPostedCollateral
        );

        emit Trade(
            msg.sender,
            positionId,
            sellResults,
            buyResults,
            totalCollateralToAdd, // borrowed
            actualCost,
            fee,
            TradeType.SPREAD
        );
    }

    /**
     * @notice executes and routes funds from lp and to lyra option market
     * @param _market eth / btc
     * @param shortTrades trades
     * @param longTrades trades
     * @return actualCost cost of trade
     * @return premiumReceived premium received from trade
     * @return sellResults results from selling
     * @return buyResults results from buying
     */
    function _executeTrade(
        bytes32 _market,
        TradeInputParameters[] memory shortTrades,
        TradeInputParameters[] memory longTrades
    )
        internal
        returns (
            uint actualCost,
            uint premiumReceived,
            TradeResult[] memory sellResults,
            TradeResult[] memory buyResults
        )
    {
        (sellResults, premiumReceived) = _sellStrikes(_market, shortTrades);

        (buyResults, actualCost) = _buyStrikes(_market, longTrades);
    }

    /**
     * @notice Executes Buys
     * @param _longTrades Long trade info
     * @return results
     */
    function _buyStrikes(
        bytes32 _market,
        TradeInputParameters[] memory _longTrades
    ) private returns (TradeResult[] memory results, uint cost) {
        results = new TradeResult[](_longTrades.length);
        address optionMarket = lyraBase(_market).getOptionMarket();

        for (uint i = 0; i < _longTrades.length; i++) {
            TradeInputParameters memory trade = _longTrades[i];

            OptionMarket.TradeInputParameters memory convertedParams = _convertParams(trade);

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

            cost += result.totalCost;
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

        results = new TradeResult[](_shortTrades.length);

        for (uint i = 0; i < _shortTrades.length; i++) {
            TradeInputParameters memory trade = _shortTrades[i];

            OptionMarket.TradeInputParameters memory convertedParams = _convertParams(trade);

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

    /**
     * @notice Handle all settlement between user/spreadoptionmarket/liquidity pool
     * @param _market btc / eth
     * @param _spreadPositionId otusOptionToken.OtusOptionPosition positionId
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

        /// @todo add a closeSpreadPosition on optionToken to close spread positions
        /// why not use closePosition on partial sum == 0

        if (partialSum == 0) {
            otusOptionToken.settlePosition(_spreadPositionId);
        } else {
            // update spread opition token position adjust
            otusOptionToken.closePosition(msg.sender, partialSum, _spreadPositionId, sellCloseResults, buyCloseResults);
        }
    }

    /// @dev executes close position or force close position on lyra option market
    function _closePosition(
        bytes32 _market,
        uint _spreadPositionId,
        TradeInputParameters[] memory _trades
    ) internal returns (uint partialSum, TradeResult[] memory sellCloseResults, TradeResult[] memory buyCloseResults) {
        OtusOptionToken.OtusOptionPosition memory position = otusOptionToken.getPosition(_spreadPositionId);

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
        OtusOptionToken.OtusOptionPosition memory position,
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

            OptionMarket.TradeInputParameters memory convertedParams = _convertParams(longTrades[i]);

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

            (uint collateralToRemove, uint setCollateralTo) = getRequiredCollateralOnClose(_market, shortTrades[i]);

            OptionMarket optionMarket = OptionMarket(lyraBase(_market).getOptionMarket());
            // should set collateral to correctly for full closes too
            if (partialSum > 0) {
                shortTrades[i].setCollateralTo = setCollateralTo;
            }

            OptionMarket.TradeInputParameters memory convertedParams = _convertParams(shortTrades[i]);

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

    /************************************************
     *  SETTLEMENT
     ***********************************************/
    /**
     * @notice Settles positions in spread option market
     * @dev Only settles if all lyra positions are settled
     * @param _spreadPositionId position id in OtusOptionToken
     */
    function settleOption(uint _spreadPositionId) external nonReentrant {
        OtusOptionToken.OtusOptionPosition memory position = otusOptionToken.getPosition(_spreadPositionId);

        // reverts if positions are not settled in lyra
        OtusOptionToken.SettledPosition[] memory optionPositions = otusOptionToken.checkLyraPositionsSettled(
            _spreadPositionId
        );

        otusOptionToken.settlePosition(_spreadPositionId);

        (
            uint totalLPSettlementAmount, // totalPendingCollateral
            uint traderSettlementAmount, // traderProfit
            uint totalCollateral
        ) = ISettlementCalculator(settlementCalculator).calculate(optionPositions);

        // @dev totalLPSettlementAmount - collateral returned
        // @dev traderSettlementAmount usually when loss there is a profit
        _routeFundsOnClose(position, 0, traderSettlementAmount, totalCollateral, totalLPSettlementAmount);
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
        OtusOptionToken.OtusOptionPosition memory position,
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
            emit LPInsolvent(_abs(amountInsolvent));
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
            _routeMaxLossCollateralToTrader(_trader, SafeDecimalMath.UNIT, _abs(fundsAfterMaxLossCollateralCover));
            _routeFundsToTrader(_trader, _abs(traderTotal));
        } else {
            _routeCollateralToLP(_abs(fundsAfterMaxLossCollateralCover));
            _routeFundsToTrader(_trader, _abs(traderTotal + fundsAfterMaxLossCollateralCover));

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

        if (!quoteAsset.transferFrom(msg.sender, address(this), _amount)) {
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
        _amount = ConvertDecimals.convertFrom18(_amount, quoteAsset.decimals());
        if (!quoteAsset.transfer(address(spreadMaxLossCollateral), _amount)) {
            // update this revert error
            revert TransferCollateralToLPFailed(_amount);
        }
    }

    function _routeFundsToTrader(address _trader, uint _amount) internal {
        _amount = ConvertDecimals.convertFrom18(_amount, quoteAsset.decimals());

        if (!quoteAsset.transfer(_trader, _amount)) {
            revert TransferFundsToTraderFailed(_trader, _amount);
        }
    }

    function _calculateFeesAndRouteFundsFromUser(uint _collateral, uint _maxExpiry) internal returns (uint fee) {
        fee = spreadLiquidityPool.calculateCollateralFee(_collateral, _maxExpiry);
        fee = ConvertDecimals.convertFrom18AndRoundUp(fee, quoteAsset.decimals());

        if (!quoteAsset.transferFrom(msg.sender, address(spreadLiquidityPool), fee)) {
            revert TransferFundsFromTraderFailed(msg.sender, fee);
        }
    }

    /************************************************
     *  VALIDATE SPREAD TRADE
     ***********************************************/

    function validMaxLoss(
        bytes32 _market,
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades
    ) public view returns (uint maxLoss) {
        TradeInputParameters memory trade;
        IMaxLossCalculator.Strike[] memory strikes = new IMaxLossCalculator.Strike[](
            _shortTrades.length + _longTrades.length
        );

        ILyraBase _lyraBase = lyraBase(_market);

        for (uint i = 0; i < _shortTrades.length; i++) {
            trade = _shortTrades[i];
            ILyraBase.Strike memory strike = _lyraBase.getStrike(trade.strikeId);

            strikes[i] = IMaxLossCalculator.Strike({
                strikePrice: strike.strikePrice,
                amount: trade.amount,
                premium: trade.minTotalCost,
                optionType: trade.optionType
            });
        }

        for (uint i = 0; i < _longTrades.length; i++) {
            trade = _longTrades[i];
            ILyraBase.Strike memory strike = _lyraBase.getStrike(trade.strikeId);
            strikes[_shortTrades.length + i] = IMaxLossCalculator.Strike({
                strikePrice: strike.strikePrice,
                amount: trade.amount,
                premium: trade.maxTotalCost,
                optionType: trade.optionType
            });
        }
        maxLoss = IMaxLossCalculator(maxLossCalculator).calculate(strikes);
    }

    /**
     * @notice validates equal sizes
     * @param _shortTrades trades
     * @param _longTrades trades
     * @return isValid is a valid spread
     */
    function validSpread(
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades
    ) public pure returns (bool) {
        uint shortTradesLen = _shortTrades.length;
        uint longTradesLen = _longTrades.length;

        uint shortTradesAmount;
        uint longTradesAmount;

        for (uint i = 0; i < shortTradesLen; i++) {
            shortTradesAmount += _shortTrades[i].amount;
        }

        for (uint i = 0; i < longTradesLen; i++) {
            longTradesAmount += _longTrades[i].amount;
        }

        if (shortTradesAmount > longTradesAmount) {
            // not a valid spread
            return false;
        }

        TradeInputParameters memory trade;

        for (uint i = 0; i < shortTradesLen; i++) {
            trade = _shortTrades[i];
            if (_isLong(trade.optionType)) {
                return false;
            }
        }

        return true;
    }

    /**
     * @notice validate increase is valid
     * @dev Used to support ranged markets
     * @dev must have a lyra position id
     * @dev last example would pass validIncrease check but wouldn't pass validSpread (even if it might be valid)
     * @dev must also have position ids set
     * @param _shortTrades trades
     * @param _longTrades trades
     */
    function validIncrease(
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades
    ) internal pure returns (bool) {
        TradeInputParameters memory trade;
        for (uint i = 0; i < _shortTrades.length; i++) {
            trade = _shortTrades[i];
            if (trade.positionId == 0) {
                // should have lyra position id
                return false;
            }
        }

        for (uint i = 0; i < _longTrades.length; i++) {
            trade = _longTrades[i];
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
     *  UTILS
     ***********************************************/

    /// @dev spread option state
    function getOptionStatus(uint _spreadPositionId) public view returns (PositionState state) {
        OtusOptionToken.OtusOptionPosition memory position = otusOptionToken.getPosition(_spreadPositionId);
        return position.state;
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
            otusManager.collateralBuffer(),
            otusManager.collateralRequirement()
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
            otusManager.collateralBuffer()
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

    function _isCall(uint _optionType) internal pure returns (bool isCall) {
        if (OptionType(_optionType) == OptionType.LONG_CALL || OptionType(_optionType) == OptionType.SHORT_CALL_QUOTE) {
            isCall = true;
        }
    }

    function _convertParams(
        TradeInputParameters memory _params
    ) internal view returns (OptionMarket.TradeInputParameters memory) {
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
                referrer: otusManager.treasury()
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
    event LPInsolvent(uint amountInsolvent);

    /************************************************
     *  ERRORS
     ***********************************************/
    error PositionInsolventBeforeSettlement();

    error NotAbleToSell();

    error InvalidLongExpiry(uint longCallExpiry, uint shortCallExpiry);

    error InvalidLongCallExpiry(uint longCallExpiry, uint shortCallExpiry);

    error InvalidLongPutExpiry(uint longPutExpiry, uint shortPutExpiry);

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

    /// @notice max loss collateral transfer failed during trade
    /// @param thrower address of owner
    error MaxLossCollateralTransferFailed(address thrower);

    error NotValidIncrease(TradeInputParameters[] _trades);

    error ClosingMoreThanInPosition();
    error NotValidPartialClose(TradeInputParameters[] _params);
    error NotAbleToPartialClose();
}
