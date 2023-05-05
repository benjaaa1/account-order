// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "hardhat/console.sol";

// inherits
import {LyraAdapter} from "../lyra/LyraAdapter.sol";
import {OtusOptionToken} from "../positions/OtusOptionToken.sol";
import {OtusManager} from "../OtusManager.sol";

// interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ISettlementCalculator.sol";

// libraries
import "../libraries/ConvertDecimals.sol";

contract OtusOptionMarket is LyraAdapter {
    /************************************************
     *  INIT STATE
     ***********************************************/

    OtusManager internal otusManager;

    OtusOptionToken internal otusOptionToken;

    address internal settlementCalculator;

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    constructor() LyraAdapter() {}

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize users account
     */
    function initialize(
        address _otusManager,
        address _quoteAsset,
        address _ethLyraBase,
        address _btcLyraBase,
        address _feeCounter,
        address _otusOptionToken,
        address _settlementCalculator
    ) external onlyOwner {
        adapterInitialize(_quoteAsset, _ethLyraBase, _btcLyraBase, _feeCounter);
        otusManager = OtusManager(_otusManager);
        otusOptionToken = OtusOptionToken(_otusOptionToken);
        settlementCalculator = _settlementCalculator;
    }

    /************************************************
     *  Lyra Trade
     ***********************************************/

    function openPosition(
        TradeInfo memory tradeInfo,
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades
    ) external nonReentrant {
        if (otusManager.maxTrades() < (_shortTrades.length + _longTrades.length)) {
            revert("Too many trades");
        }

        (TradeResult[] memory sellResults, TradeResult[] memory buyResults) = _openLyraPosition(
            tradeInfo.market,
            _shortTrades,
            _longTrades
        );

        if ((sellResults.length + buyResults.length) == 1) {
            // send lyra option token to trader
            uint lyraPositionId = sellResults.length > 0 ? sellResults[0].positionId : buyResults[0].positionId;
            _transferToken(tradeInfo.market, msg.sender, lyraPositionId);
        } else {
            // send combo token to trader
            uint positionId = otusOptionToken.openPosition(tradeInfo, msg.sender, sellResults, buyResults);
            emit Trade(msg.sender, positionId, sellResults, buyResults, 0, 0, 0, TradeType.MULTI);
        }
    }

    /**
     * @notice Opens a position on Lyra
     * @dev exeuctes a series of trades on Lyra
     * @param market the market to trade on
     * @param _shortTrades the trades to open short positions
     * @param _longTrades the trades to open long positions
     */
    function _openLyraPosition(
        bytes32 market,
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades
    ) internal returns (TradeResult[] memory sellResults, TradeResult[] memory buyResults) {
        TradeInputParameters memory trade;
        TradeResult memory result;

        sellResults = new TradeResult[](_shortTrades.length);
        buyResults = new TradeResult[](_longTrades.length);

        // calculate collateral required from trader
        // and transfer to this contract
        uint setCollateralTo;
        for (uint i = 0; i < _shortTrades.length; i++) {
            trade = _shortTrades[i];
            setCollateralTo += trade.setCollateralTo;
        }

        if (setCollateralTo > 0) {
            _transferFromQuote(msg.sender, address(this), setCollateralTo);
        }

        // premium of shorts
        uint premium;
        for (uint i = 0; i < _shortTrades.length; i++) {
            trade = _shortTrades[i];
            result = _openPosition(market, trade);
            sellResults[i] = result;
            premium += result.totalCost;
        }

        // calculate max cost of longs
        uint cost;
        for (uint i = 0; i < _longTrades.length; i++) {
            trade = _longTrades[i];
            cost += trade.maxTotalCost;
        }

        if (cost > premium) {
            _transferFromQuote(msg.sender, address(this), cost - premium);
        }

        // trade longs
        uint actualCost;
        for (uint i = 0; i < _longTrades.length; i++) {
            trade = _longTrades[i];
            result = _openPosition(market, trade);
            buyResults[i] = result;
            actualCost += result.totalCost;
        }

        // send extra back to user
        if (cost > actualCost) {
            sendFundsToTrader(msg.sender, cost - actualCost);
        }
    }

    function closeLyraPosition(bytes32 market, TradeInputParameters memory _trade) external nonReentrant {
        _closeOrForceClosePosition(market, _trade);
    }

    /************************************************
     *  POSITION SPLIT
     ***********************************************/

    /**
     * @notice Burns otus option token and transfers lyra tokens to trader if position not settled
     * @param _multiLegPositionId the position id of the multi leg position
     */
    function burnAndTransfer(uint _multiLegPositionId) external {
        OtusOptionToken.OtusOptionPosition memory position = otusOptionToken.getPosition(_multiLegPositionId);

        if (position.trader != msg.sender) {
            revert("not your position");
        }

        if (position.tradeType != TradeType.MULTI) {
            revert("not a multi leg position");
        }

        /// @dev transfer lyra positions to trader
        _bulkTransferToken(position.market, position.trader, position.allPositions);

        // otusOptionToken._bulkTransferToken(position.positionId);
        /// @dev empties otus option token
        otusOptionToken.emptyPosition(_multiLegPositionId);
    }

    /************************************************
     *  MULTI LEG SETTLEMENT
     ***********************************************/
    /**
     * @notice Settles positions in option market
     * @dev Only settles if all lyra positions are settled
     * @param _multiLegPositionId the position id of the multi leg position
     */
    function settleOption(uint _multiLegPositionId) external nonReentrant {
        OtusOptionToken.OtusOptionPosition memory position = otusOptionToken.getPosition(_multiLegPositionId);

        // reverts if positions are not settled in lyra
        OtusOptionToken.SettledPosition[] memory optionPositions = otusOptionToken.checkLyraPositionsSettled(
            _multiLegPositionId
        );

        otusOptionToken.settlePosition(_multiLegPositionId);

        (
            uint totalCollateralSettlementAmount, // totalPendingCollateral
            uint traderSettlementAmount, // traderProfit

        ) = ISettlementCalculator(settlementCalculator).calculate(optionPositions);

        // send funds to trader
        address trader = position.trader;
        sendFundsToTrader(trader, traderSettlementAmount + totalCollateralSettlementAmount);
        // emit position settled
    }

    /************************************************
     *  MISC
     ***********************************************/

    /// @dev transfers cost from user
    function _transferFromQuote(address from, address to, uint amount) internal {
        amount = ConvertDecimals.convertFrom18(amount, quoteAsset.decimals());
        if (!quoteAsset.transferFrom(from, to, amount)) {
            revert QuoteTransferFailed(address(this), from, to, amount);
        }
    }

    /**
     * @notice Sends funds to trader after trader exercises positions
     */
    function sendFundsToTrader(address _trader, uint _amount) internal {
        _amount = ConvertDecimals.convertFrom18(_amount, quoteAsset.decimals());
        if (!quoteAsset.transfer(_trader, _amount)) {
            revert TransferFundsToTraderFailed(_trader, _amount);
        }
    }

    /************************************************
     *  ERRORS
     ***********************************************/

    /// @notice failed attempt to transfer quote
    /// @param trader address
    /// @param amount in quote asset
    error TransferFundsToTraderFailed(address trader, uint amount);

    /// @notice failed attempt to transfer quote
    /// @param thrower address
    /// @param from address
    /// @param to address
    /// @param amount in quote asset
    error QuoteTransferFailed(address thrower, address from, address to, uint amount);
}
