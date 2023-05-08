// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "hardhat/console.sol";

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SimpleInitializeable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// interfaces
import {ITradeTypes} from "../interfaces/ITradeTypes.sol";

// libraries
import "../synthetix/DecimalMath.sol";

// spread option market
import {SpreadMarket} from "../markets/SpreadMarket.sol";
import {RangedMarket} from "./RangedMarket.sol";

/**
 * @title Position Market
 * @author Otus
 * @dev A market that has made a trade through the Spread Option Market for Token traders
 * @dev Executes and Holds any profits until settlement by Ranged Market keeper
 */
contract PositionMarket is SimpleInitializeable, ReentrancyGuard, ITradeTypes {
    using DecimalMath for uint;

    uint private constant ONE_PERCENT = 1e16;

    /************************************************
     *  INIT STATE
     ***********************************************/
    SpreadMarket public spreadMarket;

    OtusOptionMarket public otusOtionMarket;

    RangedMarket public rangedMarket;

    ERC20 public quoteAsset;

    uint public positionId;

    bytes32 public market;

    /************************************************
     *  MODIFIERS
     ***********************************************/

    modifier onlyRangedMarket() {
        if (msg.sender != address(rangedMarket)) {
            revert OnlyRangedMarket(address(this), msg.sender, address(rangedMarket));
        }
        _;
    }

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/
    constructor() {}

    function initialize(
        address payable _spreadMarket,
        address _otusOptionMarket,
        address _rangedMarket,
        address _quoteAsset,
        bytes32 _market
    ) external initializer {
        spreadMarket = SpreadMarket(_spreadMarket);
        otusOptionMarket = OtusOptionMarket(_otusOptionMarket);
        rangedMarket = RangedMarket(_rangedMarket);
        quoteAsset = ERC20(_quoteAsset);
        market = _market;
        // approve spread option market max (approve price/cost of position)
        quoteAsset.approve(address(spreadMarket), type(uint).max);
        quoteAsset.approve(address(otusOptionMarket), type(uint).max);
    }

    function buyOut(
        uint price,
        address _trader,
        TradeInputParameters[] memory _buysWithPricing
    ) external onlyRangedMarket returns (uint, TradeResult[] memory, TradeResult[] memory, bool isIncrease) {
        _transferFromQuote(_trader, address(this), price);
        TradeInfo memory tradeInfo = TradeInfo({positionId: positionId, market: market});

        (uint openedPositionId, TradeResult[] memory sellResults, TradeResult[] memory buyResults) = otusOptionMarket
            .openPosition(tradeInfo, [], _buysWithPricing);

        // spread option token position is valid
        if (openedPositionId == 0) {
            revert NotValidPosition();
        }

        // will only be updated once during trade period
        // update with lyra position ids
        if (tradeInfo.positionId == 0) {
            positionId = openedPositionId;
        } else {
            isIncrease = true;
        }

        return (positionId, sellResults, buyResults, isIncrease);
    }

    function buyIn(
        uint price,
        address _trader,
        TradeInputParameters[] memory _sellsWithPricing,
        TradeInputParameters[] memory _buysWithPricing
    ) external onlyRangedMarket returns (uint, TradeResult[] memory, TradeResult[] memory, bool isIncrease) {
        // transfer cost from user
        _transferFromQuote(_trader, address(this), price);

        TradeInfo memory tradeInfo = TradeInfo({positionId: positionId, market: market});

        (uint openedPositionId, TradeResult[] memory sellResults, TradeResult[] memory buyResults) = spreadOptionMarket
            .openPosition(tradeInfo, _sellsWithPricing, _buysWithPricing);

        // spread option token position is valid
        if (openedPositionId == 0) {
            revert NotValidPosition();
        }

        // will only be updated once during trade period
        // update with lyra position ids
        if (tradeInfo.positionId == 0) {
            positionId = openedPositionId;
        } else {
            isIncrease = true;
        }

        return (positionId, sellResults, buyResults, isIncrease);
    }

    function sellOut(
        uint _price,
        uint _slippage,
        TradeInputParameters[] memory _tradesWithPricing
    ) external onlyRangedMarket returns (uint funds) {
        otusOptionMarket.closePosition(market, positionId, _tradesWithPricing);

        funds = quoteAsset.balanceOf(address(this));

        _price = _price - _price.multiplyDecimal(_slippage);

        if (_price > funds) {
            revert BelowExpectedPrice(_price, funds);
        }
    }

    function sellIn(
        uint _price,
        uint _slippage,
        TradeInputParameters[] memory _tradesWithPricing
    ) external onlyRangedMarket returns (uint funds) {
        spreadMarket.closePosition(market, positionId, _tradesWithPricing);

        funds = quoteAsset.balanceOf(address(this));

        _price = _price - _price.multiplyDecimal(_slippage);

        if (_price > funds) {
            revert BelowExpectedPrice(_price, funds);
        }
    }

    /**
     * @notice Resets positionId after settlement
     */
    function settlePosition() external {
        canSettlePosition();

        positionId = 0;

        emit PositionSettled(positionId);
    }

    /**
     * @notice Checks if positions settled on Spread Option Market
     */
    function canSettlePosition() public view returns (bool) {
        // no position was opened nothing to settle
        if (positionId == 0) {
            return false;
        }
        PositionState state = spreadMarket.getOptionStatus(positionId);

        if (state != PositionState.SETTLED) {
            revert PositionNotSettled();
        }

        return true;
    }

    /************************************************
     *  MISC
     ***********************************************/

    /**
     * @notice Sends funds to trader after trader exercises positions
     */
    function sendFundsToTrader(address _trader, uint _amount) public onlyRangedMarket {
        if (!quoteAsset.transfer(_trader, _amount)) {
            revert TransferFundsToTraderFailed(_trader, _amount);
        }
    }

    /// @dev transfers cost from user to this position market
    function _transferFromQuote(address from, address to, uint amount) internal {
        if (!quoteAsset.transferFrom(from, to, amount)) {
            revert QuoteTransferFailed(address(this), from, to, amount);
        }
    }

    /************************************************
     *  EVENTS
     ***********************************************/
    event PositionSettled(uint positionId);

    /************************************************
     *  ERRORS
     ***********************************************/

    error NotValidPosition();

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

    /// @notice only otus amm
    /// @param caller address
    /// @param optionMarket address
    error OnlyOtusAMM(address caller, address optionMarket);

    /// @notice only ranged market
    /// @param thrower address
    /// @param caller address
    /// @param rangedMarket address
    error OnlyRangedMarket(address thrower, address caller, address rangedMarket);

    /// @notice spread position not settled
    error PositionNotSettled();

    error BelowExpectedPrice(uint price, uint received);
}
