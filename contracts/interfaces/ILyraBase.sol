//SPDX-License-Identifier:ISC
pragma solidity ^0.8.9;

// Libraries
import {BlackScholes} from "@lyrafinance/protocol/contracts/libraries/BlackScholes.sol";
import {IOptionMarket} from "@lyrafinance/protocol/contracts/interfaces/IOptionMarket.sol";

/**
 * @title ILyraBase
 * @author Lyra
 * @dev Interface of base to interact with different lyra markets without state
 */
interface ILyraBase {
    ///////////////////////
    // Abstract Contract //
    ///////////////////////

    struct Strike {
        uint id;
        uint expiry;
        uint strikePrice;
        uint skew;
        uint boardIv;
    }

    struct Board {
        uint id;
        uint expiry;
        uint boardIv;
        uint[] strikeIds;
    }

    struct OptionPosition {
        uint positionId;
        uint strikeId;
        OptionType optionType;
        uint amount;
        uint collateral;
        PositionState state;
    }

    enum OptionType {
        LONG_CALL,
        LONG_PUT,
        SHORT_CALL_BASE,
        SHORT_CALL_QUOTE,
        SHORT_PUT_QUOTE
    }

    enum PositionState {
        EMPTY,
        ACTIVE,
        CLOSED,
        LIQUIDATED,
        SETTLED,
        MERGED
    }

    struct TradeInputParameters {
        uint strikeId;
        uint positionId;
        uint iterations;
        OptionType optionType;
        uint amount;
        uint setCollateralTo;
        uint minTotalCost;
        uint maxTotalCost;
        address rewardRecipient;
    }

    struct TradeResult {
        uint positionId;
        uint totalCost;
        uint totalFee;
    }

    struct Liquidity {
        uint usedCollat;
        uint usedDelta;
        uint pendingDelta;
        uint freeLiquidity;
    }

    struct MarketParams {
        uint standardSize;
        uint skewAdjustmentParam;
        int rateAndCarry;
        int deltaCutOff;
    }

    struct ExchangeRateParams {
        // current snx oracle base price
        uint spotPrice;
        // snx spot exchange rate from quote to base
        uint quoteBaseFeeRate;
        // snx spot exchange rate from base to quote
        uint baseQuoteFeeRate;
    }

    //////////////
    // Exchange //
    //////////////

    function getSpotPriceForMarket() external view returns (uint spotPrice);

    ////////////////////
    // Market Getters //
    ////////////////////

    function getOptionMarket() external view returns (address);

    function getOptionToken() external view returns (address);

    function getLiveBoards() external view returns (uint[] memory liveBoards);

    function getBoard(uint boardId) external view returns (Board memory);

    function getStrikes(uint[] memory strikeIds) external view returns (Strike[] memory allStrikes);

    function getVols(uint[] memory strikeIds) external view returns (uint[] memory vols);

    function getDeltas(uint[] memory strikeIds) external view returns (int[] memory callDeltas);

    function getVegas(uint[] memory strikeIds) external view returns (uint[] memory vegas);

    function getPurePremium(
        uint secondsToExpiry,
        uint vol,
        uint spotPrice,
        uint strikePrice
    ) external view returns (uint call, uint put);

    function getPurePremiumForStrike(uint strikeId) external view returns (uint call, uint put);

    function getFreeLiquidity() external view returns (uint freeLiquidity);

    function getMarketParams() external view returns (MarketParams memory);

    function getExchangeParams() external view returns (ExchangeRateParams memory);

    /////////////////////////////
    // Option Position Getters //
    /////////////////////////////

    function getPositions(
        uint[] memory positionIds
    ) external view returns (OptionPosition[] memory);

    function getMinCollateral(
        OptionType optionType,
        uint strikePrice,
        uint expiry,
        uint spotPrice,
        uint amount
    ) external view returns (uint);

    function getMinCollateralForPosition(uint positionId) external view returns (uint);

    function getMinCollateralForStrike(
        OptionType optionType,
        uint strikeId,
        uint amount
    ) external view returns (uint);

    //////////
    // Misc //
    //////////

    function _getBsInput(
        uint strikeId
    ) external view returns (BlackScholes.BlackScholesInputs memory bsInput);

    function _isLong(OptionType optionType) external pure returns (bool);

    function _isOutsideDeltaCutoff(uint strikeId) external view returns (bool);

    function getRequiredCollateral(
        uint _size,
        uint _optionType,
        uint _positionId,
        uint _strikePrice,
        uint _strikeExpiry,
        uint _collatBuffer,
        uint _collatPercent
    ) external view returns (uint collateralToAdd, uint setCollateralTo);

    function _getBufferCollateral(
        uint _strikePrice,
        uint _expiry,
        uint _spotPrice,
        uint _amount,
        uint _optionType,
        uint _collatBuffer
    ) external view returns (uint);

    function _getFullCollateral(
        uint strikePrice,
        uint amount,
        uint _optionType
    ) external pure returns (uint fullCollat);

    //////////
    // GWAV //
    //////////

    function volGWAV(uint strikeId, uint secondsAgo) external view returns (uint);

    /************************************************
     *  LYRA QUOTER - GET TOTAL PRICING
     ***********************************************/
    function getQuote(
        uint256 _strikeId,
        uint256 _iterations,
        uint256 _optionType,
        uint256 _amount,
        uint256 _tradeDirection,
        bool _isForceClose
    ) external view returns (uint256 totalPremium, uint256 totalFee);
}
