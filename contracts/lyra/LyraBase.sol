//SPDX-License-Identifier:ISC
pragma solidity ^0.8.9;

import "hardhat/console.sol";

// Libraries
import {BlackScholes} from "@lyrafinance/protocol/contracts/libraries/BlackScholes.sol";
import {DecimalMath} from "@lyrafinance/protocol/contracts/synthetix/DecimalMath.sol";

// Interfaces
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionToken} from "@lyrafinance/protocol/contracts/OptionToken.sol";
import {OptionMarket} from "@lyrafinance/protocol/contracts/OptionMarket.sol";
import {LiquidityPool} from "@lyrafinance/protocol/contracts/LiquidityPool.sol";
import {ShortCollateral} from "@lyrafinance/protocol/contracts/ShortCollateral.sol";
import {OptionGreekCache} from "@lyrafinance/protocol/contracts/OptionGreekCache.sol";
import {BasicFeeCounter} from "@lyrafinance/protocol/contracts/periphery/BasicFeeCounter.sol";
import {OptionMarketPricer} from "@lyrafinance/protocol/contracts/OptionMarketPricer.sol";
import {GWAVOracle} from "@lyrafinance/protocol/contracts/periphery/GWAVOracle.sol";

import {BaseExchangeAdapter} from "@lyrafinance/protocol/contracts/BaseExchangeAdapter.sol";
import {GMXAdapter} from "@lyrafinance/protocol/contracts/GMXAdapter.sol";
import {ILyraQuoter} from "../interfaces/ILyraQuoter.sol";
import {IOptionMarket} from "@lyrafinance/protocol/contracts/interfaces/IOptionMarket.sol";

/**
 * @title LyraBase
 * @author Lyra
 * @dev for each lyra market deployed by otus
 */
contract LyraBase {
    using DecimalMath for uint;

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
        // The amount of options traded to move baseIv for the board up or down 1 point (depending on trade direction)
        uint standardSize;
        // Determines relative move of skew for a given strike compared to shift in baseIv
        uint skewAdjustmentParam;
        // Interest/risk free rate used in BlackScholes
        int rateAndCarry;
        // Delta cutoff past which options can be traded (optionD > minD && optionD < 1 - minD) - can use forceClose to bypass
        int deltaCutOff;
        // Time when trading closes - can use forceClose to bypass
        uint tradingCutoff;
        // Delta cutoff at which forceClose can be called (optionD < minD || optionD > 1 - minD) - using call delta
        int minForceCloseDelta;
    }

    struct ExchangeRateParams {
        // current snx oracle base price
        uint spotPrice;
        // snx spot exchange rate from quote to base
        uint quoteBaseFeeRate;
        // snx spot exchange rate from base to quote
        uint baseQuoteFeeRate;
    }

    ///////////////
    // Variables //
    ///////////////

    bytes32 public marketKey;

    OptionToken internal optionToken;
    OptionMarket public optionMarket;
    LiquidityPool internal liquidityPool;
    ShortCollateral internal shortCollateral;
    GMXAdapter internal immutable exchangeAdapter;
    OptionMarketPricer internal optionPricer;
    OptionGreekCache internal greekCache;
    GWAVOracle internal gwavOracle;

    ILyraQuoter internal lyraQuoter;

    /**
     * @notice Assigns synthetix adapter
     * @param _marketKey synth market name
     * @param _exchangeAdapter BaseExchangeAdapter address synthetix (OP) / gmx (ONE)
     * @param _optionToken OptionToken Address
     * @param _optionMarket OptionMarket Address
     * @param _liquidityPool LiquidityPool address
     * @param _shortCollateral ShortCollateral address
     * @param _optionPricer OptionPricer address
     * @param _greekCache GreekCache address
     * @param _gwavOracle GWAVOracle address
     */
    constructor(
        bytes32 _marketKey,
        address _exchangeAdapter,
        address _optionToken,
        address _optionMarket,
        address _liquidityPool,
        address _shortCollateral,
        address _optionPricer,
        address _greekCache,
        address _gwavOracle,
        address _lyraQuoter
    ) {
        marketKey = _marketKey;
        exchangeAdapter = GMXAdapter(_exchangeAdapter); // when optimism ExchangeAdapter(_synthetix) when arbritrum ExchangeAdapter(_gmx)
        optionToken = OptionToken(_optionToken); // option token will be different
        optionMarket = OptionMarket(_optionMarket); // option market will be different
        liquidityPool = LiquidityPool(_liquidityPool); // liquidity pool will be different
        shortCollateral = ShortCollateral(_shortCollateral); // short collateral will be different
        optionPricer = OptionMarketPricer(_optionPricer);
        greekCache = OptionGreekCache(_greekCache);
        gwavOracle = GWAVOracle(_gwavOracle);
        lyraQuoter = ILyraQuoter(_lyraQuoter); // lyra quoter
    }

    //////////////
    // Exchange //
    //////////////

    /**
     * @notice helper to get price of asset
     * @return spotPrice
     */
    function getSpotPriceForMarket(BaseExchangeAdapter.PriceType pricing) public view returns (uint spotPrice) {
        spotPrice = exchangeAdapter.getSpotPriceForMarket(address(optionMarket), pricing);
    }

    ////////////////////
    // Market Getters //
    ////////////////////

    function getOptionMarket() external view returns (address) {
        return address(optionMarket);
    }

    function getOptionToken() external view returns (address) {
        return address(optionToken);
    }

    function getLiveBoards() internal view returns (uint[] memory liveBoards) {
        liveBoards = optionMarket.getLiveBoards();
    }

    // get all board related info (non GWAV)
    function getBoard(uint boardId) internal view returns (Board memory) {
        OptionMarket.OptionBoard memory board = optionMarket.getOptionBoard(boardId);
        return Board({id: board.id, expiry: board.expiry, boardIv: board.iv, strikeIds: board.strikeIds});
    }

    function getStrike(uint strikeId) public view returns (Strike memory strike) {
        (OptionMarket.Strike memory _strike, OptionMarket.OptionBoard memory board) = optionMarket.getStrikeAndBoard(
            strikeId
        );

        strike = Strike({
            id: _strike.id,
            expiry: board.expiry,
            strikePrice: _strike.strikePrice,
            skew: _strike.skew,
            boardIv: board.iv
        });
    }

    // get all strike related info (non GWAV)
    function getStrikes(uint[] memory strikeIds) public view returns (Strike[] memory allStrikes) {
        allStrikes = new Strike[](strikeIds.length);

        for (uint i = 0; i < strikeIds.length; i++) {
            (OptionMarket.Strike memory strike, OptionMarket.OptionBoard memory board) = optionMarket.getStrikeAndBoard(
                strikeIds[i]
            );

            allStrikes[i] = Strike({
                id: strike.id,
                expiry: board.expiry,
                strikePrice: strike.strikePrice,
                skew: strike.skew,
                boardIv: board.iv
            });
        }

        return allStrikes;
    }

    // iv * skew only
    function getVols(uint[] memory strikeIds) public view returns (uint[] memory vols) {
        vols = new uint[](strikeIds.length);

        for (uint i = 0; i < strikeIds.length; i++) {
            (OptionMarket.Strike memory strike, OptionMarket.OptionBoard memory board) = optionMarket.getStrikeAndBoard(
                strikeIds[i]
            );

            vols[i] = board.iv.multiplyDecimal(strike.skew);
        }
        return vols;
    }

    // get deltas only
    function getDeltas(uint[] memory strikeIds) public view returns (int[] memory callDeltas) {
        callDeltas = new int[](strikeIds.length);
        for (uint i = 0; i < strikeIds.length; i++) {
            BlackScholes.BlackScholesInputs memory bsInput = _getBsInput(strikeIds[i]);
            (callDeltas[i], ) = BlackScholes.delta(bsInput);
        }
    }

    function getVegas(uint[] memory strikeIds) public view returns (uint[] memory vegas) {
        vegas = new uint[](strikeIds.length);
        for (uint i = 0; i < strikeIds.length; i++) {
            BlackScholes.BlackScholesInputs memory bsInput = _getBsInput(strikeIds[i]);
            vegas[i] = BlackScholes.vega(bsInput);
        }
    }

    // get pure black-scholes premium
    function getPurePremium(
        uint secondsToExpiry,
        uint vol,
        uint spotPrice,
        uint strikePrice
    ) public view returns (uint call, uint put) {
        BlackScholes.BlackScholesInputs memory bsInput = BlackScholes.BlackScholesInputs({
            timeToExpirySec: secondsToExpiry,
            volatilityDecimal: vol,
            spotDecimal: spotPrice,
            strikePriceDecimal: strikePrice,
            rateDecimal: exchangeAdapter.rateAndCarry(address(optionMarket))
        });
        (call, put) = BlackScholes.optionPrices(bsInput);
    }

    // get pure black-scholes premium
    function getPurePremiumForStrike(uint strikeId) internal view returns (uint call, uint put) {
        BlackScholes.BlackScholesInputs memory bsInput = _getBsInput(strikeId);
        (call, put) = BlackScholes.optionPrices(bsInput);
    }

    function getFreeLiquidity() internal view returns (uint freeLiquidity) {
        freeLiquidity = liquidityPool.getLiquidity().freeLiquidity;
    }

    function getMarketParams() internal view returns (MarketParams memory) {
        OptionMarketPricer.PricingParameters memory pricingParams = optionPricer.getPricingParams();
        OptionMarketPricer.TradeLimitParameters memory tradeLimitParams = optionPricer.getTradeLimitParams();

        return
            MarketParams({
                standardSize: pricingParams.standardSize,
                skewAdjustmentParam: pricingParams.skewAdjustmentFactor,
                rateAndCarry: exchangeAdapter.rateAndCarry(address(optionMarket)),
                deltaCutOff: tradeLimitParams.minDelta,
                tradingCutoff: tradeLimitParams.tradingCutoff,
                minForceCloseDelta: tradeLimitParams.minForceCloseDelta
            });
    }

    /////////////////////////////
    // Option Position Getters //
    /////////////////////////////

    function getPositions(uint[] memory positionIds) public view returns (OptionPosition[] memory) {
        OptionToken.OptionPosition[] memory positions = optionToken.getOptionPositions(positionIds);

        OptionPosition[] memory convertedPositions = new OptionPosition[](positions.length);
        for (uint i = 0; i < positions.length; i++) {
            convertedPositions[i] = OptionPosition({
                positionId: positions[i].positionId,
                strikeId: positions[i].strikeId,
                optionType: OptionType(uint(positions[i].optionType)),
                amount: positions[i].amount,
                collateral: positions[i].collateral,
                state: PositionState(uint(positions[i].state))
            });
        }

        return convertedPositions;
    }

    function getMinCollateral(
        OptionType optionType,
        uint strikePrice,
        uint expiry,
        uint spotPrice,
        uint amount
    ) public view returns (uint) {
        return
            greekCache.getMinCollateral(
                OptionMarket.OptionType(uint(optionType)),
                strikePrice,
                expiry,
                spotPrice,
                amount
            );
    }

    function getMinCollateralForPosition(uint positionId) public view returns (uint) {
        OptionToken.PositionWithOwner memory position = optionToken.getPositionWithOwner(positionId);
        if (_isLong(OptionType(uint(position.optionType)))) return 0;

        uint strikePrice;
        uint expiry;
        (strikePrice, expiry) = optionMarket.getStrikeAndExpiry(position.strikeId);

        return
            getMinCollateral(
                OptionType(uint(position.optionType)),
                strikePrice,
                expiry,
                exchangeAdapter.getSpotPriceForMarket(address(optionMarket), BaseExchangeAdapter.PriceType.REFERENCE),
                position.amount
            );
    }

    function getMinCollateralForStrike(OptionType optionType, uint strikeId, uint amount) internal view returns (uint) {
        if (_isLong(optionType)) return 0;

        uint strikePrice;
        uint expiry;
        (strikePrice, expiry) = optionMarket.getStrikeAndExpiry(strikeId);

        return
            getMinCollateral(
                optionType,
                strikePrice,
                expiry,
                exchangeAdapter.getSpotPriceForMarket(address(optionMarket), BaseExchangeAdapter.PriceType.REFERENCE),
                amount
            );
    }

    //////////
    // Misc //
    //////////

    function _getBsInput(uint strikeId) internal view returns (BlackScholes.BlackScholesInputs memory bsInput) {
        (OptionMarket.Strike memory strike, OptionMarket.OptionBoard memory board) = optionMarket.getStrikeAndBoard(
            strikeId
        );
        bsInput = BlackScholes.BlackScholesInputs({
            timeToExpirySec: board.expiry - block.timestamp,
            volatilityDecimal: board.iv.multiplyDecimal(strike.skew),
            spotDecimal: exchangeAdapter.getSpotPriceForMarket(
                address(optionMarket),
                BaseExchangeAdapter.PriceType.REFERENCE
            ),
            strikePriceDecimal: strike.strikePrice,
            rateDecimal: exchangeAdapter.rateAndCarry(address(optionMarket))
        });
    }

    function _isLong(OptionType optionType) internal pure returns (bool) {
        return (optionType < OptionType.SHORT_CALL_BASE);
    }

    //////////
    // Misc //
    //////////

    function volGWAV(uint strikeId, uint secondsAgo) public view returns (uint) {
        OptionMarket.Strike memory strike = optionMarket.getStrike(strikeId);
        return gwavOracle.ivGWAV(strike.boardId, secondsAgo).multiplyDecimal(gwavOracle.skewGWAV(strikeId, secondsAgo));
    }

    /**
     * @dev use latest optionMarket delta cutoff to determine whether trade delta is out of bounds
     */
    function _isOutsideDeltaCutoff(uint strikeId) public view returns (bool) {
        MarketParams memory marketParams = getMarketParams();
        int callDelta = getDeltas(_toDynamic(strikeId))[0];
        return callDelta > (int(DecimalMath.UNIT) - marketParams.deltaCutOff) || callDelta < marketParams.deltaCutOff;
    }

    /// @notice use latest optionMarket trading cutoff to determine whether trade is too close to expiry
    function _isWithinTradingCutoff(bytes32 _market, uint strikeId) internal view returns (bool) {
        MarketParams memory marketParams = getMarketParams();
        uint[] memory dynamicArray = new uint[](1);
        dynamicArray[0] = strikeId;

        Strike memory strike = getStrikes(dynamicArray)[0];
        return strike.expiry - block.timestamp <= marketParams.tradingCutoff;
    }

    /*****************************************************
     *  VAULT STRATEGY DELTA HELPERS
     *****************************************************/
    /**
     * @dev checks delta for vault for a market - helpful in user hedge / dynamic
     * @dev this is grabbing all the striketrades and not separating by market
     * @dev need to filter out by market first
     */
    function checkNetDelta(uint[] memory _positionIds) public view returns (int netDelta) {
        OptionPosition[] memory positions = getPositions(_positionIds);
        uint _positionsLen = positions.length;
        uint[] memory strikeIds = new uint[](_positionsLen);

        for (uint i = 0; i < _positionsLen; i++) {
            OptionPosition memory position = positions[i];
            if (position.state == PositionState.ACTIVE) {
                strikeIds[i] = positions[i].strikeId;
            }
        }

        int[] memory deltas = getDeltas(strikeIds);

        for (uint i = 0; i < deltas.length; i++) {
            netDelta = netDelta + deltas[i];
        }
    }

    /**
     * @dev get required collateral for close
     */
    function getRequiredCollateralClose(
        uint _closeSize,
        uint _optionType,
        uint _positionId,
        uint _strikePrice,
        uint _strikeExpiry,
        uint _collatBuffer
    ) public view returns (uint collateralRemoved, uint setCollateralTo) {
        uint existingAmount;
        uint existingCollateral;

        if (_positionId > 0) {
            OptionPosition memory position = getPositions(_toDynamic(_positionId))[0];
            existingCollateral = position.collateral;
            existingAmount = position.amount;
        }

        // remove all collateral
        if (_closeSize == existingAmount) {
            return (0, 0);
        }

        setCollateralTo = _getBufferCollateralMax(
            _strikePrice,
            _strikeExpiry,
            existingAmount - _closeSize, // existingAmount - _size
            _optionType,
            _collatBuffer
        );

        collateralRemoved = existingCollateral - setCollateralTo;
    }

    /**
     * @dev get required collateral for short with collateral percent
     *
     */
    function getRequiredCollateral(
        uint _size,
        uint _optionType,
        uint _positionId,
        uint _strikePrice,
        uint _strikeExpiry,
        uint _collatBuffer,
        uint _collatPercent
    ) public view returns (uint collateralToAdd, uint setCollateralTo) {
        // get existing position info if active
        uint existingAmount;
        uint existingCollateral;

        if (_positionId > 0) {
            OptionPosition memory position = getPositions(_toDynamic(_positionId))[0];
            existingCollateral = position.collateral;
            existingAmount = position.amount;
        }

        uint minCollatWithBuffer = _getBufferCollateralMin(
            _strikePrice,
            _strikeExpiry,
            existingAmount + _size, // existingAmount - _size
            _optionType,
            _collatBuffer
        );

        uint targetCollat = _getTargetCollateral(existingCollateral, _strikePrice, _size, _optionType, _collatPercent);

        setCollateralTo = _max(minCollatWithBuffer, targetCollat);

        collateralToAdd = setCollateralTo - existingCollateral;
    }

    function _getTargetCollateral(
        uint _existingCollateral,
        uint _strikePrice,
        uint _size,
        uint _optionType,
        uint _collatPercent
    ) internal pure returns (uint targetCollat) {
        targetCollat =
            _existingCollateral +
            _getFullCollateral(_strikePrice, _size, _optionType).multiplyDecimal(_collatPercent);
    }

    function _getTargetCollateralClose(
        uint _strikePrice,
        uint _size,
        uint _optionType,
        uint _collatPercent
    ) internal pure returns (uint targetCollat) {
        targetCollat = _getFullCollateral(_strikePrice, _size, _optionType).multiplyDecimal(_collatPercent);
    }

    /**
     * @dev get amount of collateral needed for shorting {amount} of strike, according to the strategy
     */
    function _getBufferCollateralMax(
        uint _strikePrice,
        uint _expiry,
        uint _amount,
        uint _optionType,
        uint _collatBuffer
    ) internal view returns (uint) {
        uint _spotPrice = getSpotPriceForMarket(BaseExchangeAdapter.PriceType.REFERENCE);
        uint minCollat = getMinCollateral(OptionType(_optionType), _strikePrice, _expiry, _spotPrice, _amount);

        require(minCollat > 0, "min collat must be more");

        uint minCollatWithBuffer = minCollat.multiplyDecimal(_collatBuffer);

        uint fullCollat = _getFullCollateral(_strikePrice, _amount, _optionType);
        require(fullCollat > 0, "fullCollat collat must be more");

        return _max(minCollatWithBuffer, fullCollat);
    }

    function _getBufferCollateralMin(
        uint _strikePrice,
        uint _expiry,
        uint _amount,
        uint _optionType,
        uint _collatBuffer
    ) internal view returns (uint) {
        uint _spotPrice = getSpotPriceForMarket(BaseExchangeAdapter.PriceType.REFERENCE);
        uint minCollat = getMinCollateral(OptionType(_optionType), _strikePrice, _expiry, _spotPrice, _amount);

        require(minCollat > 0, "min collat must be more");

        uint minCollatWithBuffer = minCollat.multiplyDecimal(_collatBuffer);

        uint fullCollat = _getFullCollateral(_strikePrice, _amount, _optionType);
        require(fullCollat > 0, "fullCollat collat must be more");

        return _min(minCollatWithBuffer, fullCollat);
    }

    function _getFullCollateral(
        uint strikePrice,
        uint amount,
        uint _optionType
    ) internal pure returns (uint fullCollat) {
        // calculate required collat based on collatBuffer and collatPercent
        fullCollat = _isBaseCollat(_optionType) ? amount : amount.multiplyDecimal(strikePrice);
    }

    function _isBaseCollat(uint _optionType) internal pure returns (bool isBase) {
        isBase = (OptionType(_optionType) == OptionType.SHORT_CALL_BASE) ? true : false;
    }

    function _min(uint x, uint y) internal pure returns (uint) {
        return (x < y) ? x : y;
    }

    function _max(uint x, uint y) internal pure returns (uint) {
        return (x > y) ? x : y;
    }

    function _abs(int val) internal pure returns (uint) {
        return val >= 0 ? uint(val) : uint(-val);
    }

    // temporary fix - eth core devs promised Q2 2022 fix
    function _toDynamic(uint val) internal pure returns (uint[] memory dynamicArray) {
        dynamicArray = new uint[](1);
        dynamicArray[0] = val;
    }

    /************************************************
     * LYRA QUOTER - GET TOTAL PRICING
     ***********************************************/

    function getQuote(
        uint256 _strikeId,
        uint256 _iterations,
        uint256 _optionType,
        uint256 _amount,
        uint256 _tradeDirection,
        bool _isForceClose
    ) public view returns (uint256 totalPremium, uint256 totalFee) {
        address _optionMarket = address(optionMarket);
        (totalPremium, totalFee) = lyraQuoter.quote(
            IOptionMarket(_optionMarket),
            _strikeId,
            _iterations,
            IOptionMarket.OptionType(_optionType),
            _amount,
            IOptionMarket.TradeDirection(_tradeDirection),
            _isForceClose
        );
    }
}
