//SPDX-License-Identifier:ISC
pragma solidity ^0.8.9;

import "hardhat/console.sol";

// Interfaces
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptionMarket} from "@lyrafinance/protocol/contracts/interfaces/IOptionMarket.sol";
import {IOptionToken} from "@lyrafinance/protocol/contracts/interfaces/IOptionToken.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SimpleInitializeable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interfaces/ILyraBase.sol";
import {BasicFeeCounter} from "@lyrafinance/protocol/contracts/periphery/BasicFeeCounter.sol";
import {ITradeTypes} from "../interfaces/ITradeTypes.sol";

/**
 * @title LyraAdapter
 * @author Otus
 * @dev Forked from LyraAdapter by Lyra Finance for use with Multi Leg Multi Market One click trading on Otus
 */
contract LyraAdapter is Ownable, SimpleInitializeable, ReentrancyGuard, ITradeTypes {
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

        if (address(quoteAsset) != address(0)) {
            quoteAsset.approve(lyraBase(bytes32("ETH")).getOptionMarket(), type(uint).max);
            quoteAsset.approve(lyraBase(bytes32("BTC")).getOptionMarket(), type(uint).max);
        }
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
    function _openPosition(bytes32 _market, TradeInputParameters memory params) internal returns (TradeResult memory) {
        IOptionMarket.TradeInputParameters memory convertedParams = _convertParams(params);

        address optionMarket = lyraBase(_market).getOptionMarket();

        (bool success, bytes memory data) = optionMarket.call(
            abi.encodeWithSelector(IOptionMarket.openPosition.selector, convertedParams)
        );

        if (!success) {
            if (data.length > 0) {
                assembly {
                    let data_size := mload(data)
                    revert(add(32, data), data_size)
                }
            } else {
                revert("LyraAdapter: openPosition failed");
            }
        }

        IOptionMarket.Result memory result = abi.decode(data, (IOptionMarket.Result));

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
            TradeResult({
                market: _market,
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee,
                optionType: params.optionType,
                amount: params.amount,
                setCollateralTo: params.setCollateralTo,
                strikeId: params.strikeId
            });
    }

    /************************************************
     *  Transfer Lyra Option Token
     ***********************************************/

    /**
     * @notice transfer lyra option token to this trader
     * @param _market btc/eth
     * @param _to address of trader
     * @param positionId of lyra position
     */
    function _transferToken(bytes32 _market, address _to, uint positionId) internal {
        IOptionToken(lyraBase(_market).getOptionToken()).safeTransferFrom(address(this), _to, positionId);
    }

    /**
     * @notice bulk transfer lyra option tokens to this trader
     * @param _market btc/eth
     * @param _to address of trader
     * @param positionIds of lyra positions
     */
    function _bulkTransferToken(bytes32 _market, address _to, uint[] memory positionIds) internal {
        IOptionToken optionToken = IOptionToken(lyraBase(_market).getOptionToken());

        for (uint i; i < positionIds.length; ) {
            optionToken.safeTransferFrom(address(this), _to, positionIds[i]);
            unchecked {
                i++;
            }
        }
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
