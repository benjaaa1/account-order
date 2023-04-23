// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SimpleInitializeable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializeable.sol";
import {LyraAdapter} from "./LyraAdapter.sol";

// interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OtusOptionMarket is LyraAdapter {
    constructor(address _quoteAsset) LyraAdapter(_quoteAsset) {}

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize users account
     */
    function initialize(address _ethLyraBase, address _btcLyraBase, address _feeCounter) external onlyOwner {
        adapterInitialize(_ethLyraBase, _btcLyraBase, _feeCounter);
    }

    /************************************************
     *  Lyra Trade
     ***********************************************/

    function openLyraPosition(bytes32 market, TradeInputParameters[] memory _trades) external {
        TradeInputParameters memory _trade;
        for (uint i = 0; i < _trades.length; i++) {
            _trade = _trades[i];
            _openPosition(market, _trade);
        }
    }

    function closeLyraPosition(bytes32 market, TradeInputParameters memory _trade) external {
        _closeOrForceClosePosition(market, _trade);
    }
}
