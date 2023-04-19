// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

import "hardhat/console.sol";

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SimpleInitializable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// interfaces
import {ITradeTypes} from "../interfaces/ITradeTypes.sol";
import "../interfaces/ILyraBase.sol";

// libraries
import "../synthetix/DecimalMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

// spread option market
import {SpreadOptionMarket} from "../SpreadOptionMarket.sol";
import {RangedMarketToken} from "./RangedMarketToken.sol";
import {PositionMarket} from "./PositionMarket.sol";
import {OtusAMM} from "../OtusAMM.sol";

/**
 * @title Ranged Market
 * @author Otus
 * @dev Setup a ranged market through the Spread Market for users to buy and sell
 * @dev Currently can buy more
 * @dev Currently not able to sell!!! Need to be able to decrease size on Spread Option Market
 */
contract RangedMarket is SimpleInitializable, ReentrancyGuard, ITradeTypes {
    using DecimalMath for uint;

    uint private constant ONE_PERCENT = 1e16;

    uint public constant IN_STRIKES_LIMIT = 4;

    uint public constant OUT_STRIKES_LIMIT = 2;

    /************************************************
     *  INIT STATE
     ***********************************************/
    SpreadOptionMarket public immutable spreadOptionMarket;

    OtusAMM public immutable otusAMM;

    ILyraBase public lyraBase;

    TradeInputParameters[] public inTrades;

    TradeInputParameters[] public outTrades;

    ERC20 public quoteAsset;

    PositionMarket public positionMarketIn;

    PositionMarket public positionMarketOut;

    RangedMarketToken public tokenIn;

    RangedMarketToken public tokenOut;

    // @dev set per size of 1
    // @dev max loss of collateral possible
    uint internal maxLossIn;

    bytes32 public market;

    // expiry of board selected for market
    uint public expiry;

    // to be cleared at settlement or not - if we use ranged market address for single IN/OUT position+expiry
    mapping(uint => mapping(uint => uint)) public positionIdByStrikeId;

    /************************************************
     *  MODIFIERS
     ***********************************************/
    modifier onlyOtusAMM() {
        if (msg.sender != address(otusAMM)) {
            revert OnlyOtusAMM(msg.sender, address(otusAMM));
        }
        _;
    }

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/
    constructor(address payable _spreadOptionMarket, address _otusAMM) {
        spreadOptionMarket = SpreadOptionMarket(_spreadOptionMarket);
        otusAMM = OtusAMM(_otusAMM);
    }

    function initialize(
        address _quoteAsset,
        address _positionMarketIn, // clones of PositionMarket
        address _positionMarketOut, // clones of PositionMarket
        address _tokenIn, // clones of RangeMarketToken
        address _tokenOut, // clones of RangeMarketToken
        bytes32 _market,
        uint _expiry,
        TradeInputParameters[] memory _inTrades,
        TradeInputParameters[] memory _outTrades
    ) external initializer {
        // should be otussettings
        lyraBase = otusAMM.lyraBase(_market);
        // validate ranged positions are valid spreads
        (bool isValidIn, ) = spreadOptionMarket.validSpread(_inTrades);

        if (!isValidIn) {
            revert NotValidRangedPositionIn(_inTrades);
        }

        (bool isValidOut, ) = spreadOptionMarket.validSpread(_outTrades);
        if (!isValidOut) {
            revert NotValidRangedPositionOut(_outTrades);
        }

        quoteAsset = ERC20(_quoteAsset);
        positionMarketIn = PositionMarket(_positionMarketIn);
        positionMarketOut = PositionMarket(_positionMarketOut);
        tokenIn = RangedMarketToken(_tokenIn);
        tokenOut = RangedMarketToken(_tokenOut);
        _setRangedPositionDetails(_market, _expiry, _inTrades, _outTrades);
    }

    // @dev should have an expiry too
    // @dev set max loss for in position
    function _setRangedPositionDetails(
        bytes32 _market,
        uint _expiry,
        TradeInputParameters[] memory _inTrades,
        TradeInputParameters[] memory _outTrades
    ) internal {
        market = _market;
        expiry = _expiry;
        TradeInputParameters memory inTrade;
        int maxLossCall;
        int maxLossPut;

        if (IN_STRIKES_LIMIT < _inTrades.length) {
            revert NotValidRangedPositionIn(_inTrades);
        }

        for (uint i = 0; i < _inTrades.length; i++) {
            inTrade = _inTrades[i];

            ILyraBase.Strike memory strike = lyraBase.getStrike(inTrade.strikeId);

            int strikePrice = SafeCast.toInt256(strike.strikePrice);

            if (_isLong(inTrade.optionType)) {
                if (_isCall(inTrade.optionType)) {
                    maxLossCall = maxLossCall + strikePrice;
                } else {
                    maxLossPut = maxLossPut + strikePrice;
                }
            } else {
                if (_isCall(inTrade.optionType)) {
                    maxLossCall = maxLossCall - strikePrice;
                } else {
                    maxLossPut = maxLossPut - strikePrice;
                }
            }

            inTrades.push(inTrade);
        }

        // no max loss on when long call strike below short call
        if (maxLossCall < 0) {
            maxLossCall = 0;
        }

        maxLossIn = _abs(maxLossCall) > _abs(maxLossPut) ? _abs(maxLossCall) : _abs(maxLossPut);

        if (OUT_STRIKES_LIMIT < _outTrades.length) {
            revert NotValidRangedPositionOut(_outTrades);
        }

        for (uint i = 0; i < _outTrades.length; i++) {
            outTrades.push(_outTrades[i]);
        }
    }

    /************************************************
     *  Pricing
     ***********************************************/

    /**
     * @notice Used externally to get a quote for IN token
     * @param pricing info
     */
    function getInPricing(
        Pricing memory pricing
    ) external view returns (uint price, TradeInputParameters[] memory tradesWithCosts) {
        // get cost + premium + max loss
        tradesWithCosts = new TradeInputParameters[](inTrades.length);
        TradeInputParameters memory trade;

        uint totalCosts; // longs
        uint totalPremium; // shorts
        uint totalFees;

        for (uint i = 0; i < inTrades.length; i++) {
            trade = inTrades[i];

            (uint totalCost, uint totalFee) = spreadOptionMarket.getQuote(
                market,
                trade.strikeId,
                trade.optionType,
                pricing
            );

            // if long open
            // this will add costs + maxloss expected for size
            // if short open
            // this will subtract premium

            // if long close
            // this will pay us any premium
            // if short close
            // this will return any collateral owed to lp and mx
            // so basically need to get some help from close process in spreadoptionmarket
            // if (pricing.tradeDirection == 1) {} else {
            //     if (_isLong(trade.optionType)) {
            //         trade.minTotalCost = totalCost + totalCost.multiplyDecimal(pricing.slippage);
            //         totalCosts += trade.maxTotalCost;
            //     } else {
            //         trade.maxTotalCost = totalCost - totalCost.multiplyDecimal(pricing.slippage);
            //         totalPremium += trade.minTotalCost;
            //     }
            // }

            if (_isLong(trade.optionType)) {
                trade.maxTotalCost = totalCost + totalCost.multiplyDecimal(pricing.slippage);
                totalCosts += trade.maxTotalCost;
            } else {
                trade.minTotalCost = totalCost - totalCost.multiplyDecimal(pricing.slippage);
                totalPremium += trade.minTotalCost;
            }

            // set amount to trade
            trade.amount = pricing.amount;
            tradesWithCosts[i] = trade;
            totalFees += totalFee;
        }

        price = maxLossIn.multiplyDecimal(pricing.amount) + totalCosts + totalFees - totalPremium;

        // if (pricing.tradeDirection == 0) {
        //     price = maxLossIn.multiplyDecimal(pricing.amount) + totalCosts + totalFees - totalPremium;
        // } else {
        //     price = maxLossIn.multiplyDecimal(pricing.amount) + totalPremium - totalCosts - totalFees;
        // }

        return (price, tradesWithCosts);
    }

    /**
     * @notice Used externally to get a quote for OUT token
     * @param pricing price info
     */
    function getOutPricing(
        Pricing memory pricing
    ) external view returns (uint price, TradeInputParameters[] memory tradesWithCosts) {
        // get cost + premium + max loss
        tradesWithCosts = new TradeInputParameters[](outTrades.length);
        TradeInputParameters memory trade;

        uint totalCosts; // longs
        uint totalFees;

        for (uint i = 0; i < outTrades.length; i++) {
            trade = outTrades[i];

            (uint totalCost, uint totalFee) = spreadOptionMarket.getQuote(
                market,
                trade.strikeId,
                trade.optionType,
                pricing
            );

            // unnecessary out trades only have longs
            if (_isLong(trade.optionType)) {
                // sub slippage if closing position
                trade.maxTotalCost = totalCost + totalCost.multiplyDecimal(pricing.slippage);
                totalCosts += trade.maxTotalCost;
            }

            // set amount to trade
            trade.amount = pricing.amount;
            tradesWithCosts[i] = trade;
            totalFees += totalFee;
        }

        price = totalCosts + totalFees;

        return (price, tradesWithCosts);
    }

    /************************************************
     *  EXECUTE TRADES
     ***********************************************/

    /**
     * @notice Buys options positions that represent a ranged position returns a token to trader
     * @param _amount buy amount
     * @param _trader buyer address
     * @param _price max price with slippage (maxloss + maxcost) - premium checks will be done in spread option market
     * @param tradesWithPricing trades
     */
    function buyIn(
        uint _amount,
        address _trader,
        uint _price, // max price for amount with slippage
        TradeInputParameters[] memory tradesWithPricing
    ) external nonReentrant onlyOtusAMM {
        bool isIncrease;
        uint positionId;

        TradeResult[] memory sellResults;
        TradeResult[] memory buyResults;
        // user should only set price from ui with slippage if it's enough to cover
        // then it'll succeed if not it'll fail in spread option market
        // needs to be more validation here to check tradesWithPricing inputs

        if (tradesWithPricing.length != inTrades.length) {
            revert InvalidTrade();
        }

        (positionId, sellResults, buyResults, isIncrease) = positionMarketIn.buy(
            _price,
            _trader,
            _convertParams(tradesWithPricing, _amount)
        );

        if (!isIncrease) {
            // assign position ids
            _assignLyraPositionIds(sellResults, buyResults, inTrades);
        }

        mint(RangedPosition.IN, _trader, _amount);
    }

    /**
     * @notice Buys options positions that represent a ranged position returns a token to trader
     * @param _amount buy amount
     * @param _trader buyer address
     * @param _price max price with slippage (maxloss + maxcost) - premium checks will be done in spread option market
     * @param tradesWithPricing trades
     */
    function buyOut(
        uint _amount,
        address _trader,
        uint _price,
        TradeInputParameters[] memory tradesWithPricing
    ) external nonReentrant onlyOtusAMM {
        bool isIncrease;
        uint positionId;

        if (tradesWithPricing.length != outTrades.length) {
            revert InvalidTrade();
        }

        TradeResult[] memory sellResults;
        TradeResult[] memory buyResults;
        /// @dev max loss out is 0 - longs only
        (positionId, sellResults, buyResults, isIncrease) = positionMarketOut.buy(
            _price,
            _trader,
            _convertParams(tradesWithPricing, _amount)
        );

        if (!isIncrease) {
            // assign position ids
            _assignLyraPositionIds(sellResults, buyResults, outTrades);
        }

        mint(RangedPosition.OUT, _trader, _amount);
    }

    function _convertParams(
        TradeInputParameters[] memory tradesWithPricing,
        uint _amount // used to confirm matching amounts
    ) internal view returns (TradeInputParameters[] memory tradesWithPositions) {
        TradeInputParameters memory trade;
        tradesWithPositions = new TradeInputParameters[](tradesWithPricing.length);
        for (uint i = 0; i < tradesWithPricing.length; i++) {
            trade = tradesWithPricing[i];
            trade.positionId = positionIdByStrikeId[trade.optionType][trade.strikeId];
            trade.amount = _amount;
            tradesWithPositions[i] = trade;
        }
    }

    /**
     *
     * @notice Sell Ranged IN Positions will have multiple options
     * @dev Users can sell to market (expensive)
     * @dev Users can put a "LIMIT" sell order - Buys will get a discount
     * @param _trader sell in range token or out
     * @param _amount sell in range token or out
     * @param _price sell in range token or out
     * @param _slippage sell in range token or out
     * @param tradesWithPricing tradesWithPricing
     */
    function sellIn(
        address _trader,
        uint _amount,
        uint _price,
        uint _slippage,
        TradeInputParameters[] memory tradesWithPricing
    ) external nonReentrant onlyOtusAMM {
        // check if _amount is < rangedmarkettoken amount revert if more
        uint tokenInBal = tokenIn.balanceOf(_trader);
        if (tokenInBal < _amount) {
            revert SellExceedsBalance(tokenInBal, _amount);
        }

        uint funds = positionMarketIn.sell(_price, _slippage, _convertParams(tradesWithPricing, _amount));
        burn(RangedPosition.IN, _trader, _amount, funds);
    }

    error SellExceedsBalance(uint tokenBalance, uint amount);

    /**
     *
     * @notice Sell Ranged OUT Positions will have multiple options
     * @dev Users can sell to market (expensive)
     * @dev Users can put a "LIMIT" sell order - Buys will get a discount
     * @param _amount sell in range token or out
     * @param _price sell in range token or out
     * @param _trader sell in range token or out
     * @param tradesWithPricing tradesWithPricing
     */
    function sellOut(
        address _trader,
        uint _amount,
        uint _price,
        uint _slippage,
        TradeInputParameters[] memory tradesWithPricing
    ) external nonReentrant onlyOtusAMM {
        uint tokenOutBal = tokenOut.balanceOf(_trader);
        if (tokenOutBal < _amount) {
            revert SellExceedsBalance(tokenOutBal, _amount);
        }

        uint funds = positionMarketOut.sell(_price, _slippage, _convertParams(tradesWithPricing, _amount));
        burn(RangedPosition.OUT, _trader, _amount, funds);
    }

    function burn(RangedPosition _position, address _trader, uint _amount, uint _funds) internal {
        if (_position == RangedPosition.IN) {
            tokenIn.burn(_trader, _amount);

            if (_funds > 0) {
                positionMarketIn.sendFundsToTrader(_trader, _funds);
            }
        } else {
            tokenOut.burn(_trader, _amount);

            if (_funds > 0) {
                positionMarketOut.sendFundsToTrader(_trader, _funds);
            }
        }

        emit Burn(_position, _trader, _amount);
    }

    function mint(RangedPosition _position, address _trader, uint _amount) internal {
        if (RangedPosition.IN == _position) {
            tokenIn.mint(_trader, _amount);
        } else {
            tokenOut.mint(_trader, _amount);
        }
        emit Mint(_position, _trader, _amount);
    }

    /************************************************
     *  SETTLEMENT
     ***********************************************/

    /**
     * @notice settles traders IN and OUT positions
     * @dev routes funds from PositionMarket to trader
     */
    function exerciseRangedPositions() external nonReentrant {
        // check all positions are settled on spread option market
        positionMarketIn.canSettlePosition();

        positionMarketOut.canSettlePosition();

        // trader ranged market token balance
        // accounts for their share of funds from position markets
        uint tokenInBal = tokenIn.balanceOf(msg.sender);
        uint tokenOutBal = tokenOut.balanceOf(msg.sender);

        if (tokenInBal == 0 && tokenOutBal == 0) {
            revert NotAbleToExercise();
        }

        // because these are not perfect in vs out
        // there is potential for a small amount of funds available on the losing side
        uint positionInBal = quoteAsset.balanceOf(address(positionMarketIn));
        uint positionOutBal = quoteAsset.balanceOf(address(positionMarketOut));

        if (positionInBal > 0) {
            uint tokenInSupply = tokenIn.getTotalSupply();
            uint shareOfProfit = tokenInBal.divideDecimal(tokenInSupply);
            uint payout = positionInBal.multiplyDecimal(shareOfProfit);
            positionMarketIn.sendFundsToTrader(msg.sender, payout);
        }

        if (positionOutBal > 0) {
            uint tokenOutSupply = tokenOut.getTotalSupply();
            uint shareOfProfit = tokenOutBal.divideDecimal(tokenOutSupply);
            uint payout = positionOutBal.multiplyDecimal(shareOfProfit);
            positionMarketOut.sendFundsToTrader(msg.sender, payout);
        }

        if (tokenInBal > 0) {
            tokenIn.burn(msg.sender, tokenInBal);
        }

        if (tokenOutBal > 0) {
            tokenOut.burn(msg.sender, tokenOutBal);
        }
    }

    /**
     * @notice settles range positions
     */
    function settleRangedPositions() external {
        positionMarketIn.settlePosition();
        positionMarketOut.settlePosition();
    }

    /************************************************
     *  POSITION STATE ASSIGNMENT
     ***********************************************/

    function _assignLyraPositionIds(
        TradeResult[] memory sellResults,
        TradeResult[] memory buyResults,
        TradeInputParameters[] storage trades // can be inTrades can be outTrades
    ) internal {
        for (uint i = 0; i < sellResults.length; i++) {
            TradeResult memory result = sellResults[i];
            positionIdByStrikeId[result.optionType][result.strikeId] = result.positionId;
        }
        for (uint i = 0; i < buyResults.length; i++) {
            TradeResult memory result = buyResults[i];
            positionIdByStrikeId[result.optionType][result.strikeId] = result.positionId;
        }

        for (uint i = 0; i < trades.length; i++) {
            TradeInputParameters storage trade = trades[i];
            trade.positionId = positionIdByStrikeId[trade.optionType][trade.strikeId];
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

    function _isCall(uint _optionType) public pure returns (bool isCall) {
        if (OptionType(_optionType) == OptionType.LONG_CALL || OptionType(_optionType) == OptionType.SHORT_CALL_QUOTE) {
            isCall = true;
        }
    }

    /************************************************
     *  EVENTS
     ***********************************************/

    event Mint(RangedPosition rangedPosition, address _trader, uint _amount);
    event Burn(RangedPosition rangedPosition, address _trader, uint _amount);

    /************************************************
     *  ERRORS
     ***********************************************/

    /// @notice only otus amm
    /// @param caller address
    /// @param optionMarket address
    error OnlyOtusAMM(address caller, address optionMarket);

    error NotValidRangedPositionOut(TradeInputParameters[] outTrades);
    error NotValidRangedPositionIn(TradeInputParameters[] inTrades);

    error NotAbleToExercise();
    error InvalidTrade();
}
