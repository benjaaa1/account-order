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

// libraries
import "../synthetix/DecimalMath.sol";
import "../libraries/ConvertDecimals.sol";

// spread option market
import {SpreadOptionMarket} from "../SpreadOptionMarket.sol";
import {RangedMarket} from "./RangedMarket.sol";

/**
 * @title Position Market
 * @author Otus
 * @dev A market that has made a trade through the Spread Option Market for Token traders
 * @dev Executes and Holds any profits until settlement by Ranged Market keeper
 */
contract PositionMarket is SimpleInitializable, ReentrancyGuard, ITradeTypes {
    using DecimalMath for uint;

    uint private constant ONE_PERCENT = 1e16;

    /************************************************
     *  INIT STATE
     ***********************************************/
    SpreadOptionMarket public spreadOptionMarket;

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
        address payable _spreadOptionMarket,
        address _rangedMarket,
        address _quoteAsset,
        bytes32 _market
    ) external initializer {
        spreadOptionMarket = SpreadOptionMarket(_spreadOptionMarket);
        rangedMarket = RangedMarket(_rangedMarket);
        quoteAsset = ERC20(_quoteAsset);
        market = _market;
        // approve spread option market max (approve price/cost of position)
        quoteAsset.approve(address(spreadOptionMarket), type(uint).max);
    }

    function buy(
        uint price,
        address _trader,
        TradeInputParameters[] memory _tradesWithPricing
    ) external onlyRangedMarket returns (uint, TradeResult[] memory, TradeResult[] memory, bool isIncrease) {
        // transfer cost from user
        _transferFromQuote(_trader, address(this), price);

        TradeInfo memory tradeInfo = TradeInfo({positionId: positionId, market: market});

        (uint openedPositionId, TradeResult[] memory sellResults, TradeResult[] memory buyResults) = spreadOptionMarket
            .openPosition(
                tradeInfo,
                _tradesWithPricing,
                price // represents max cost + max loss - premium for amount
            );

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

    function sell(
        uint _price,
        uint _slippage,
        TradeInputParameters[] memory _tradesWithPricing
    ) external onlyRangedMarket returns (uint funds) {
        spreadOptionMarket.closePosition(market, positionId, _tradesWithPricing);

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
        PositionState state = spreadOptionMarket.getOptionStatus(positionId);

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
     *  MISC
     ***********************************************/
    /// @dev Transfers the amount from 18dp to the quoteAsset's decimals ensuring any precision loss is rounded up
    function _transferFromQuote(address from, address to, uint amount) internal {
        amount = ConvertDecimals.convertFrom18AndRoundUp(amount, quoteAsset.decimals());
        if (!quoteAsset.transferFrom(from, to, amount)) {
            // revert QuoteTransferFailed(address(this), from, to, amount);
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
