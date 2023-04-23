//SPDX-License-Identifier:ISC
pragma solidity ^0.8.9;

// Interfaces
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptionMarket} from "@lyrafinance/protocol/contracts/interfaces/IOptionMarket.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SimpleInitializable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializable.sol";

import "./interfaces/ILyraBase.sol";
import {BasicFeeCounter} from "@lyrafinance/protocol/contracts/periphery/BasicFeeCounter.sol";
import {ITradeTypes} from "./interfaces/ITradeTypes.sol";

/**
 * @title LyraAdapter
 * @author Otus
 * @dev Forked from LyraAdapter by Lyra Finance for use with Multi Leg Multi Market One click trading on Otus
 */
contract LyraAdapter is Ownable, SimpleInitializable, ITradeTypes {
    /************************************************
     *  STORED CONTRACT ADDRESSES
     ***********************************************/

    // susd is used for quoteasset
    IERC20 internal quoteAsset;
    // Lyra trading rewards
    BasicFeeCounter public feeCounter;

    /************************************************
     *  INIT STATE
     ***********************************************/

    mapping(bytes32 => ILyraBase) public lyraBases;

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    constructor() {}

    /************************************************
     *  INIT
     ***********************************************/

    function adapterInitialize(
        address _quoteAsset,
        address _ethLyraBase,
        address _btcLyraBase,
        address _feeCounter
    ) internal onlyOwner initializer {
        quoteAsset = IERC20(_quoteAsset);

        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);
        feeCounter = BasicFeeCounter(_feeCounter);
    }

    function setFeeCounter(address _feeCounter) external onlyOwner {
        feeCounter = BasicFeeCounter(_feeCounter);
    }

    function setLyraBase(bytes32 _market, address _lyraBase) external onlyOwner {
        lyraBases[_market] = ILyraBase(_lyraBase);
    }

    /************************************************
     *  Market Position Actions
     ***********************************************/

    /**
     * @notice open a position in lyra mm
     * @param params params to open trade on lyra
     * @return result of opening trade
     */
    function _openPosition(
        bytes32 _market,
        TradeInputParameters memory params
    ) internal returns (TradeResultDirect memory) {
        IOptionMarket.TradeInputParameters memory convertedParams = _convertParams(params);
        IOptionMarket optionMarket = IOptionMarket(lyraBase(_market).getOptionMarket());
        IOptionMarket.Result memory result = optionMarket.openPosition(convertedParams);

        if (params.rewardRecipient != address(0)) {
            feeCounter.trackFee(
                address(optionMarket),
                params.rewardRecipient,
                _convertParams(params).amount,
                result.totalCost,
                result.totalFee
            );
        }

        return
            TradeResultDirect({
                market: _market,
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee
            });
    }

    /**
     * @notice Attempt close under normal condition or forceClose
     *          if position is outside of delta or too close to expiry.
     *
     * @param params The parameters for the requested trade
     */
    function _closeOrForceClosePosition(
        bytes32 _market,
        TradeInputParameters memory params
    ) internal returns (TradeResultDirect memory tradeResult) {
        if (
            !lyraBase(_market)._isOutsideDeltaCutoff(_market, params.strikeId) &&
            !lyraBase(_market)._isWithinTradingCutoff(_market, params.strikeId)
        ) {
            return _closePosition(_market, params);
        } else {
            // will pay less competitive price to close position but bypasses Lyra delta/trading cutoffs
            return _forceClosePosition(_market, params);
        }
    }

    /**
     * @notice close a position in lyra mm
     * @param params params to close trade on lyra
     * @return result of trade
     */
    function _closePosition(
        bytes32 _market,
        TradeInputParameters memory params
    ) internal returns (TradeResultDirect memory) {
        IOptionMarket optionMarket = IOptionMarket(lyraBase(_market).getOptionMarket());

        IOptionMarket.Result memory result = optionMarket.closePosition(_convertParams(params));

        if (params.rewardRecipient != address(0)) {
            feeCounter.trackFee(
                address(optionMarket),
                params.rewardRecipient,
                _convertParams(params).amount,
                result.totalCost,
                result.totalFee
            );
        }

        return
            TradeResultDirect({
                market: _market,
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee
            });
    }

    /**
     * @notice forceclose a position in lyra mm
     * @param params params to close trade on lyra
     * @return result of trade
     */
    function _forceClosePosition(
        bytes32 _market,
        TradeInputParameters memory params
    ) internal returns (TradeResultDirect memory) {
        IOptionMarket optionMarket = IOptionMarket(lyraBase(_market).getOptionMarket());
        IOptionMarket.Result memory result = optionMarket.forceClosePosition(_convertParams(params));

        if (params.rewardRecipient != address(0)) {
            feeCounter.trackFee(
                address(optionMarket),
                params.rewardRecipient,
                _convertParams(params).amount,
                result.totalCost,
                result.totalFee
            );
        }

        return
            TradeResultDirect({
                market: _market,
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee
            });
    }

    /************************************************
     *  Misc
     ***********************************************/

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
}
