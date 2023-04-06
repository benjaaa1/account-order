// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

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

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SimpleInitializeable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializeable.sol";

// interfaces
import "./interfaces/ILyraBase.sol";
import {ITradeTypes} from "./interfaces/ITradeTypes.sol";
import {IOptionMarket} from "@lyrafinance/protocol/contracts/interfaces/IOptionMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SpreadOptionMarket
 * @author Otus
 * @dev Trades, Validates and Settles Spread Options Positions on Lyra.
 */
contract SpreadOptionMarket is Ownable, SimpleInitializeable, ReentrancyGuard, ITradeTypes {
    using SafeDecimalMath for uint;
    using SignedDecimalMath for int;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    uint internal constant COLLATERAL_BUFFER = 1e18 * 1.1; // 100%
    uint internal constant COLLATERAL_REQUIRED = 1e18;
    uint private constant ONE_PERCENT = 1e16;

    /************************************************
     *  INIT STATE
     ***********************************************/

    IERC20 public quoteAsset;

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
        quoteAsset = IERC20(_quoteAsset);
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
     * @param _maxLossPosted set by trader for spread position
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

        bool isValidSingle = validSingleMarket(_tradeInfo.market, _trades);

        if (!isValidSingle) {
            revert NotSingleMarketTrade(_trades);
        }

        // check validity of spread
        // @dev current method doesn't support updating existing positions
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
        bool _isPartialClose,
        TradeInputParameters[] memory _params
    ) external nonReentrant {
        // @dev only trader can close
        // @dev only allowed to close full position and all positions
        // need to check that _params are closing the same amount
        if (_isPartialClose && !validPartialClose(_params)) {
            revert NotValidPartialClose(_params);
        }

        SpreadOptionToken.SpreadOptionPosition memory position = spreadOptionToken.getPosition(_spreadPositionId);

        if (position.trader != msg.sender) {
            revert OnlyOwnerCanClose(msg.sender, position.trader);
        }
        // commented out for now to deal with deep stack later
        // OptionToken optionToken = OptionToken(lyraBase(_market).getOptionToken());
        // partial close doesn't  work because position collateral is 0!!!
        // setCollateralTo needs to be set to greater than 0 remember a min. of 200 is needed.
        IOptionMarket.Result memory result;

        uint totalTraderProfit;
        uint totalFees;
        uint totalPendingCollateral;
        uint totalCollateral;

        for (uint i = 0; i < _params.length; i++) {
            TradeInputParameters memory param = _params[i];

            (, , OptionMarket.OptionType optionType, uint amount, uint collateral, ) = OptionToken(
                lyraBase(_market).getOptionToken()
            ).positions(param.positionId);

            if (_isPartialClose && param.amount > amount) {
                revert ClosingMoreThanInPosition();
            }

            // need to make sure param has correct close size for full position
            if (!_isPartialClose) {
                param.amount = amount;
            }

            result = _closePosition(_market, param);

            if (optionType == OptionMarket.OptionType.LONG_CALL || optionType == OptionMarket.OptionType.LONG_PUT) {
                totalTraderProfit = totalTraderProfit + result.totalCost;
                totalFees = totalFees + result.totalFee;
            } else {
                // OptionMarket.OptionType.SHORT_CALL_QUOTE || trade.optionType == OptionMarket.OptionType.SHORT_PUT_QUOTE
                totalPendingCollateral = totalPendingCollateral + (collateral - result.totalCost);
                totalCollateral = totalCollateral + collateral;
            }
        }

        // @dev add max loss posted as credit to user
        int traderTotal = SafeCast.toInt256(totalTraderProfit); //  - SafeCast.toInt256(totalFees); fees from trader profits?
        // @dev totalPendingCollateral - collateral released by lyra market
        // @dev totalCollateral - collateral originally lent
        int collateralToRecover = SafeCast.toInt256(totalCollateral) - SafeCast.toInt256(totalPendingCollateral);
        // @dev return collaral to liquidity pool
        _routeCollateralToLP(totalPendingCollateral);

        // if trader total is < 0 not allowed to close in market if partial
        if (_isPartialClose && traderTotal <= 0) {
            revert NotAbleToPartialClose();
        }

        // @dev trader is in profit - likely collateral lost
        if (traderTotal > 0) {
            if (traderTotal > collateralToRecover) {
                // transfer funds to trader
                // since fees were subtracted from trader total the
                _routeFundsToTrader(position.trader, uint(traderTotal - collateralToRecover));

                // free locked liquidity
                _routeCollateralToLP(uint(collateralToRecover));
                // transfer/add max loss to trader
                spreadMaxLossCollateral.sendQuoteToTrader(position.trader, position.maxLossPosted);
            } else {
                _routeCollateralToLPFromUser(uint(-collateralToRecover));
            }
        } else {
            // traderTotal <= 0
            // pay for fees
            //_routeFundsToTrader(position.trader, uint(-traderTotal));

            if (SafeCast.toInt256(position.maxLossPosted) > collateralToRecover) {
                _routeMaxLossCollateralToLP(uint(collateralToRecover));

                spreadMaxLossCollateral.sendQuoteToTrader(
                    position.trader,
                    uint(SafeCast.toInt256(position.maxLossPosted) - collateralToRecover)
                );
            } else {
                _routeCollateralToLPFromUser(uint(collateralToRecover - SafeCast.toInt256(position.maxLossPosted)));
            }
        }

        if (!_isPartialClose) {
            spreadOptionToken.settlePosition(_spreadPositionId);
        }
    }

    /// @dev executes close position or force close position on lyra option market
    function _closePosition(
        bytes32 _market,
        TradeInputParameters memory param
    ) internal returns (IOptionMarket.Result memory result) {
        IOptionMarket optionMarket = IOptionMarket(lyraBase(_market).getOptionMarket());

        IOptionMarket.TradeInputParameters memory convertedParams = _convertParams(param);

        bool outsideDeltaCutoff = lyraBase(_market)._isOutsideDeltaCutoff(convertedParams.strikeId);

        if (!outsideDeltaCutoff) {
            result = optionMarket.closePosition(convertedParams);
        } else {
            // will pay less competitive price to close position
            result = optionMarket.forceClosePosition(convertedParams);
        }
    }

    /// @dev returns sell strikeids, short/long trades and sum of max cost total set by trader
    function buildTrades(
        TradeInputParameters[] memory _trades,
        uint totalSells
    )
        internal
        pure
        returns (
            uint[] memory sellStrikeIds,
            TradeInputParameters[] memory shortTrades,
            TradeInputParameters[] memory longTrades
        )
    {
        shortTrades = new TradeInputParameters[](totalSells);
        longTrades = new TradeInputParameters[](_trades.length - totalSells);
        sellStrikeIds = new uint[](totalSells);
        uint sells;
        uint buys;

        for (uint i = 0; i < _trades.length; i++) {
            if (!_isLong(_trades[i].optionType)) {
                shortTrades[sells] = _trades[i];
                sellStrikeIds[sells] = _trades[i].strikeId;
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

    // @dev helper method calculate additional premium received > expected
    function _minPremium(TradeInputParameters[] memory _shortTrades) internal pure returns (uint minPremium) {
        for (uint i = 0; i < _shortTrades.length; i++) {
            minPremium += _shortTrades[i].minTotalCost;
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
        (
            uint[] memory sellStrikeIds,
            TradeInputParameters[] memory shortTrades,
            TradeInputParameters[] memory longTrades
        ) = buildTrades(_trades, totalSells);

        (uint totalCollateralToAdd, uint totalSetCollateralTo) = _getTotalRequiredCollateral(
            _tradeInfo.market,
            shortTrades,
            sellStrikeIds
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
     * @dev fees are sent to this contract
     * @param _market eth / btc
     * @param _totalCollateralToAdd collateral to be borrowed from liquidity pool
     * @param _maxLossPosted max loss posted by user including (collateral loss cover+ costs + fees) and excluding premiums
     * @param shortTrades trades
     * @param longTrades trades
     * @return sellResults results from selling
     * @return buyResults results from buying
     * @dev any premium collected from selling is subtracted from total cost for buying
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
        uint fee;
        uint premiumCollected;

        /// @dev route collateral from liquidity pool
        _routeLPFundsForCollateral(_totalCollateralToAdd);
        // uint balBefore = quoteAsset.balanceOf(address(this));
        (sellResults, premiumCollected) = _sellStrikes(_market, shortTrades);
        // uint balAfter = quoteAsset.balanceOf(address(this)); comes back with premium

        /// @dev route cost to option market from trader
        (buyResults, actualCost) = _buyStrikes(_market, longTrades);

        // why are we adding here the premium
        // if user posts $2000 as max loss (dont add premium because it's already taken into account so need to do some math there)
        maxLossPostedCollateral = _maxLossPosted; // + premiumCollected;
        // @dev confirm max loss posted meets required
        (uint maxLossCollateralRequirement, uint maxExpiry) = validMaxLossAndExpiries(_market, sellResults, buyResults);
        console.log("maxLossPostedCollateral");
        console.log(maxLossPostedCollateral);
        console.log(maxLossCollateralRequirement);

        if (maxLossCollateralRequirement > maxLossPostedCollateral) {
            revert MaxLossRequirementNotMet(maxLossCollateralRequirement, _maxLossPosted);
        }

        /// @dev route fees from user to lp (calculate to )
        if (_totalCollateralToAdd > 0) {
            _calculateFeesAndRouteFundsFromUser(_totalCollateralToAdd, maxExpiry);
        }

        /// @dev route max loss to short collateral
        /// @bug askig for premiumCollected from user again
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
    ) private returns (TradeResult[] memory results, uint actualCost) {
        uint maxCost = _maxCost(_longTrades);

        _routeCostsFromUser(maxCost);

        results = new TradeResult[](_longTrades.length);
        address optionMarket = lyraBase(_market).getOptionMarket();
        quoteAsset.approve(address(optionMarket), type(uint).max);

        for (uint i = 0; i < _longTrades.length; i++) {
            TradeInputParameters memory trade = _longTrades[i];

            IOptionMarket.TradeInputParameters memory convertedParams = _convertParams(trade);

            IOptionMarket.Result memory result = IOptionMarket(optionMarket).openPosition(convertedParams);

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
            _routeExtraBackToUser(maxCost, actualCost);
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

            IOptionMarket.TradeInputParameters memory convertedParams = _convertParams(trade);

            IOptionMarket.Result memory result = IOptionMarket(optionMarket).openPosition(convertedParams);

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
     *  SETTLEMENT
     ***********************************************/
    /**
     * @notice Settles positions in spread option market
     * @dev Only settles if all lyra positions are settled
     * @param _spreadPositionId position id in SpreadOptionToken
     */
    function settleOption(uint _spreadPositionId) external nonReentrant returns (uint settlementInsolvency) {
        SpreadOptionToken.SpreadOptionPosition memory position = spreadOptionToken.getPosition(_spreadPositionId);

        // reverts if positions are not settled in lyra
        (address trader, SpreadOptionToken.SettledPosition[] memory optionPositions) = spreadOptionToken
            .checkLyraPositionsSettled(_spreadPositionId);

        spreadOptionToken.settlePosition(_spreadPositionId);

        uint totalLPSettlementAmount;
        uint totalLPLossToBeRecovered;
        uint traderSettlementAmount;

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
            }
        }

        // @dev totalLPLossToBeRecovered - funds not returned from collateral locked
        // @dev totalLPSettlementAmount - collateral returned
        // @dev traderSettlementAmount usually when loss there is a profit
        if (totalLPLossToBeRecovered > 0) {
            // need to recover from user profits if any
            // if no user profits recover from maxLossPosted
            // @example collateral loss is $500 tradersettlement is $200
            if (totalLPLossToBeRecovered > traderSettlementAmount) {
                // send all tradersettlement to lp
                _routeCollateralToLP(totalLPSettlementAmount + traderSettlementAmount);
                uint leftOverToRecover = totalLPLossToBeRecovered - traderSettlementAmount;
                // @dev  totalLPLossToBeRecovered is $1000 trader profit is $500 => $500 is
                // greater than the max loss posted $400
                if (leftOverToRecover > position.maxLossPosted) {
                    _routeMaxLossCollateralToLP(position.maxLossPosted);
                    // @dev free locked liquidity
                    // _routeFundsToTrader(trader, leftOverToRecover - position.maxLossPosted);
                } else {
                    _routeMaxLossCollateralToLP(leftOverToRecover);

                    spreadMaxLossCollateral.sendQuoteToTrader(
                        position.trader,
                        position.maxLossPosted - leftOverToRecover
                    );
                }
            } else if (traderSettlementAmount > 0) {
                traderSettlementAmount = traderSettlementAmount - totalLPLossToBeRecovered;
                _routeFundsToTrader(trader, traderSettlementAmount);
                _routeCollateralToLP(totalLPSettlementAmount + totalLPLossToBeRecovered);
                spreadMaxLossCollateral.sendQuoteToTrader(trader, position.maxLossPosted);
            } else {
                _routeMaxLossCollateralToLP(position.maxLossPosted);
            }
        } else {
            // @dev return max loss posted
            spreadMaxLossCollateral.sendQuoteToTrader(trader, position.maxLossPosted);

            // spreadMaxLossCollateral.sendMaxLossQuoteCollateral(trader, position.maxLossPosted);
            _routeFundsToTrader(trader, traderSettlementAmount);
            _routeCollateralToLP(totalLPSettlementAmount);
        }
    }

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
        if (!quoteAsset.transferFrom(msg.sender, address(this), _amount)) {
            revert TransferFundsFromTraderFailed(msg.sender, _amount);
        }
    }

    function _routeExtraBackToUser(uint __maxCost, uint _actualCost) internal {
        if (!quoteAsset.transfer(msg.sender, __maxCost - _actualCost)) {
            revert TransferFundsToTraderFailed(msg.sender, __maxCost - _actualCost);
        }
    }

    function _calculateFeesAndRouteFundsFromUser(uint _collateral, uint _maxExpiry) internal {
        uint fee = spreadLiquidityPool.calculateCollateralFee(_collateral, _maxExpiry);
        if (!quoteAsset.transferFrom(msg.sender, address(spreadLiquidityPool), fee)) {
            revert TransferFundsFromTraderFailed(msg.sender, fee);
        }
    }

    /**
     * @notice transfer funds from trader to max loss
     */
    function _routeMaxLossCollateralFromTrader(uint _amount) internal {
        if (!quoteAsset.transferFrom(msg.sender, address(spreadMaxLossCollateral), _amount)) {
            revert TransferFundsFromTraderFailed(msg.sender, _amount);
        }
    }

    function _routeMaxLossCollateralFromMarket(uint _amount) internal {
        if (!quoteAsset.transfer(address(spreadMaxLossCollateral), _amount)) {
            // update this revert error
            revert TransferCollateralToLPFailed(_amount);
        }
    }

    function _routeFundsToTrader(address _trader, uint _amount) internal {
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
        TradeResult[] memory _buyResults
    ) internal view returns (uint maxLoss, uint expiry) {
        TradeResult memory result;
        int maxLossCall;
        int maxLossPut;
        uint shortExpiry;
        uint longExpiry;

        ILyraBase _lyraBase = lyraBase(_market);

        if (_sellResults.length == 0) {
            return (0, 0);
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
                } else {
                    maxLossCall =
                        maxLossCall +
                        SafeCast.toInt256(strikePrice.multiplyDecimal(longCallCount - shortCallCount));
                }
            } else {
                longPutCount += result.amount;
                if (longPutCount < shortPutCount) {
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

        expiry = shortExpiry;
        maxLoss = _abs(maxLossCall) > _abs(maxLossPut) ? _abs(maxLossCall) : _abs(maxLossPut);
    }

    /**
     * @notice validates spread trade max loss
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
     * @notice spreads are single market
     * @param _market eth btc ...
     * @param _trades trades
     */
    function validSingleMarket(bytes32 _market, TradeInputParameters[] memory _trades) internal pure returns (bool) {
        uint tradesLen = _trades.length;
        TradeInputParameters memory trade;

        for (uint i = 0; i < tradesLen; i++) {
            trade = _trades[i];
            if (_market != _market) {
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
    function validPartialClose(TradeInputParameters[] memory _params) internal pure returns (bool) {
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
        uint amount,
        uint tradeDirection,
        bool isForceClose
    ) public view returns (uint totalPremium, uint totalFees) {
        (totalPremium, totalFees) = lyraBase(_market).getQuote(
            strikeId,
            1,
            optionType,
            amount,
            tradeDirection, // 0 open 1 close 2 liquidate
            isForceClose
        );
    }

    /************************************************
     *  COLLATERAL REQUIREMENTS
     ***********************************************/
    /**
     * @notice gets required collateral for a position
     * @param _market btc/eth
     * @param _trade trade attempted
     * @param _strikePrice strike price for trade
     * @param _expiry expiry for trade
     * @return collateralToAdd additional collateral required (collateralToAdd = setCollateralTo - existingCollateral)
     * @return setCollateralTo total collateral required for position
     */
    function _getRequiredCollateral(
        bytes32 _market,
        TradeInputParameters memory _trade,
        uint _strikePrice,
        uint _expiry
    ) internal view returns (uint collateralToAdd, uint setCollateralTo) {
        (collateralToAdd, setCollateralTo) = lyraBase(_market).getRequiredCollateral(
            _trade.amount,
            _trade.optionType,
            _trade.positionId,
            _strikePrice,
            _expiry,
            COLLATERAL_BUFFER,
            COLLATERAL_REQUIRED
        );
    }

    /**
     *
     * @param _trades can hold multiple markets
     * @param _market btc eth
     * @param _strikeIds strikeIds trading
     * @return totalCollateralToAdd total required from user/liquidity pool
     * @return totalSetCollateralTo total for all strikes and markets to set in lyra option market
     */
    function _getTotalRequiredCollateral(
        bytes32 _market,
        TradeInputParameters[] memory _trades,
        uint[] memory _strikeIds
    ) internal view returns (uint totalCollateralToAdd, uint totalSetCollateralTo) {
        if (_trades.length > 0) {
            ILyraBase.Strike[] memory strikes = lyraBase(_market).getStrikes(_strikeIds);

            for (uint i = 0; i < _trades.length; i++) {
                TradeInputParameters memory trade = _trades[i];
                ILyraBase.Strike memory strike = strikes[i];
                (uint collateralToAdd, uint setCollateralTo) = _getRequiredCollateral(
                    _market,
                    trade,
                    strike.strikePrice,
                    strike.expiry
                );
                // @dev currently used for testing ranged markets
                // @dev 200usd is the minimum set collateral allowed by lyra
                setCollateralTo = setCollateralTo < 200e18 ? 200e18 : setCollateralTo;
                collateralToAdd = collateralToAdd < 200e18 ? 200e18 : collateralToAdd;
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

    function _isCall(uint _optionType) public view returns (bool isCall) {
        console.log("_optionType");
        console.log(_optionType);
        if (OptionType(_optionType) == OptionType.LONG_CALL || OptionType(_optionType) == OptionType.SHORT_CALL_QUOTE) {
            console.log("is call");
            isCall = true;
        }
    }

    function _convertParams(
        TradeInputParameters memory _params
    ) internal pure returns (IOptionMarket.TradeInputParameters memory) {
        return
            IOptionMarket.TradeInputParameters({
                strikeId: _params.strikeId,
                positionId: _params.positionId,
                iterations: _params.iterations,
                optionType: IOptionMarket.OptionType(uint(_params.optionType)),
                amount: _params.amount,
                setCollateralTo: _params.setCollateralTo,
                minTotalCost: _params.minTotalCost,
                maxTotalCost: _params.maxTotalCost
            });
    }

    /************************************************
     *  Internal Lyra Base Getter
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

    /************************************************
     *  ERRORS
     ***********************************************/
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
