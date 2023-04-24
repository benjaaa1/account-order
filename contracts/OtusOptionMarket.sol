// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

import "hardhat/console.sol";

// inherits
import {LyraAdapter} from "./LyraAdapter.sol";

// libraries
import "./libraries/ConvertDecimals.sol";

contract OtusOptionMarket is LyraAdapter {
    constructor() LyraAdapter() {}

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize users account
     */
    function initialize(
        address _quoteAsset,
        address _ethLyraBase,
        address _btcLyraBase,
        address _feeCounter
    ) external onlyOwner {
        adapterInitialize(_quoteAsset, _ethLyraBase, _btcLyraBase, _feeCounter);
    }

    /************************************************
     *  Lyra Trade
     ***********************************************/

    function openLyraPosition(
        bytes32 market,
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades
    ) external nonReentrant {
        TradeInputParameters memory trade;
        TradeResultDirect memory result;

        // calculate collateral required
        uint setCollateralTo;
        for (uint i = 0; i < _shortTrades.length; i++) {
            trade = _shortTrades[i];
            setCollateralTo += trade.setCollateralTo;
        }

        // transfer collateral required
        if (setCollateralTo > 0) {
            _transferFromQuote(msg.sender, address(this), setCollateralTo);
        }

        // premium of shorts
        uint premium;
        for (uint i = 0; i < _shortTrades.length; i++) {
            trade = _shortTrades[i];
            result = _openPosition(market, trade);
            premium += result.totalCost;
        }

        // calculate cost of longs first
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
            actualCost += result.totalCost;
        }

        console.log(quoteAsset.balanceOf(address(this)));

        if ((cost > actualCost) && (quoteAsset.balanceOf(address(this)) > (cost - actualCost))) {
            sendFundsToTrader(msg.sender, cost - actualCost);
        }

        console.log(quoteAsset.balanceOf(address(this)));
    }

    function closeLyraPosition(bytes32 market, TradeInputParameters memory _trade) external nonReentrant {
        _closeOrForceClosePosition(market, _trade);
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
