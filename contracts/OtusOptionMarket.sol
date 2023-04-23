// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "hardhat/console.sol";

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SimpleInitializeable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializeable.sol";
import {LyraAdapter} from "./LyraAdapter.sol";

// interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

        // $120
        // $40
        // $110

        // 120 - 40 = 80

        // 120 > 110
        // return $10 to trader

        console.log(quoteAsset.balanceOf(address(this)));
        if (cost > actualCost) {
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
        if (!quoteAsset.transferFrom(from, to, amount)) {
            revert QuoteTransferFailed(address(this), from, to, amount);
        }
    }

    /**
     * @notice Sends funds to trader after trader exercises positions
     */
    function sendFundsToTrader(address _trader, uint _amount) internal {
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
