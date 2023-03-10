// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "hardhat/console.sol";

// lyra base interface
import "./interfaces/ILyraBase.sol";
import "./interfaces/gelato/IOps.sol";

// libraries
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./synthetix/SafeDecimalMath.sol";

// inherits
import {MinimalProxyable} from "./utils/MinimalProxyable.sol";
import {OpsReady} from "./utils/OpsReady.sol";

contract AccountOrder is MinimalProxyable, OpsReady {
    using SafeDecimalMath for uint;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    uint internal constant COLLATERAL_BUFFER = 10 * 10 ** 6; // 10%

    enum OrderTypes {
        MARKET,
        LIMIT_PRICE,
        LIMIT_VOL,
        TAKE_PROFIT,
        STOP_LOSS
    }

    enum OptionType {
        LONG_CALL,
        LONG_PUT,
        SHORT_CALL_BASE,
        SHORT_CALL_QUOTE,
        SHORT_PUT_QUOTE
    }

    struct StrikeTrade {
        OrderTypes orderType;
        bytes32 market;
        uint iterations;
        uint collatPercent;
        uint optionType;
        uint strikeId;
        uint size;
        uint positionId;
        uint tradeDirection;
        uint targetPrice;
        uint targetVolatility;
    }

    struct StrikeTradeOrder {
        StrikeTrade strikeTrade;
        bytes32 gelatoTaskId;
        uint committedMargin;
    }

    struct TradeInputParameters {
        uint strikeId;
        uint positionId;
        uint iterations;
        uint optionType;
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

    /************************************************
     *  INIT STATE
     ***********************************************/

    IERC20 public quoteAsset;

    mapping(bytes32 => ILyraBase) public lyraBases;

    /************************************************
     *  STATE
     ***********************************************/

    mapping(uint => StrikeTradeOrder) public orders;

    uint public orderId;

    /// @notice margin locked for future events (ie. limit orders)
    uint256 public committedMargin;

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    constructor() {}

    /// @dev can deposit eth
    receive() external payable onlyOwner {}

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize users account
     * @param _quoteAsset address used as margin asset (USDC / SUSD)
     * @param _ethLyraBase (lyra adapter for eth market)
     * @param _btcLyraBase (lyra adapter for btc market)
     * @param _ops gelato ops address
     */
    function initialize(
        address _quoteAsset,
        address _ethLyraBase,
        address _btcLyraBase,
        address payable _ops
    ) external initOnce {
        quoteAsset = IERC20(_quoteAsset);
        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);
        _transferOwnership(msg.sender);
        ops = _ops;
    }

    /************************************************
     *  ORDERS
     ***********************************************/
    /**
     * @notice place order
     * @param _trade trade details
     */
    function placeOrder(StrikeTrade memory _trade) external payable onlyOwner returns (uint) {
        if (address(this).balance < 1 ether / 100) {
            revert InsufficientEthBalance(address(this).balance, 1 ether / 100);
        }

        // allow optionmarket to use funds
        address optionMarket = lyraBase(_trade.market).getOptionMarket();
        quoteAsset.approve(address(optionMarket), type(uint).max);

        // trigger order should have positionid &&
        // trigger order is tradeDirection close only &&
        // trigger order is take profit or stop loss &&
        if (
            _trade.tradeDirection != 1 &&
            (_trade.orderType == OrderTypes.TAKE_PROFIT ||
                _trade.orderType == OrderTypes.STOP_LOSS) &&
            _trade.positionId == 0
        ) {
            revert InvalidOrderType();
        }

        uint requiredCapital = _getRequiredCapital(_trade);

        // check free margin
        if (requiredCapital > freeMargin()) {
            // need more funds
            revert InsufficientFreeMargin(freeMargin(), requiredCapital);
        } else {
            committedMargin += requiredCapital; // $1500 - $400 = $1100
        }

        bytes32 taskId = IOps(ops).createTaskNoPrepayment(
            address(this), // execution function address
            this.executeOrder.selector, // execution function selector
            address(this), // checker (resolver) address
            abi.encodeWithSelector(this.checker.selector, orderId), // checker (resolver) calldata
            ETH // payment token
        );

        orders[orderId] = StrikeTradeOrder({
            strikeTrade: _trade,
            gelatoTaskId: taskId,
            committedMargin: committedMargin
        });

        emit StrikeOrderPlaced(address(msg.sender), orderId, orders[orderId]);

        return orderId++;
    }

    /**
     * @notice calculate required capital for short/long trades
     * @param _trade trade details
     * @return requiredCapital to be committed
     */
    function _getRequiredCapital(
        StrikeTrade memory _trade
    ) internal view returns (uint requiredCapital) {
        ILyraBase.Strike memory strike = lyraBase(_trade.market).getStrikes(
            _toDynamic(_trade.strikeId)
        )[0];
        bool isLong = _isLong(_trade.optionType);

        if (isLong) {
            // targetprice replaces premium for buy
            requiredCapital = _trade.size.multiplyDecimal(_trade.targetPrice);
        } else {
            // getRequiredCollateral for both of these is best
            (uint collateralToAdd, uint setCollateralTo) = _getRequiredCollateral(
                _trade,
                strike.strikePrice,
                strike.expiry
            );
            requiredCapital = collateralToAdd;
        }
    }

    /************************************************
     *  GELATO KEEPER METHODS
     ***********************************************/

    /**
     * @notice check if limit order is valid and execute
     * @param _orderId trade order id
     * @return canExec
     * @return execPayload
     */
    function checker(
        uint256 _orderId
    ) external view returns (bool canExec, bytes memory execPayload) {
        (canExec, ) = validOrder(_orderId);
        execPayload = abi.encodeWithSelector(this.executeOrder.selector, _orderId);
    }

    /**
     * @notice check validity of orderid
     * @param _orderId trade order id
     * @return valid
     * @return premium
     */
    function validOrder(uint256 _orderId) public view returns (bool, uint) {
        StrikeTradeOrder memory order = orders[_orderId];
        if (order.strikeTrade.orderType == OrderTypes.LIMIT_PRICE) {
            return validLimitOrder(order.strikeTrade);
        } else if (order.strikeTrade.orderType == OrderTypes.LIMIT_VOL) {
            return validLimitVolOrder(order.strikeTrade);
        } else if (order.strikeTrade.orderType == OrderTypes.TAKE_PROFIT) {
            return validTakeProfitOrder(order.strikeTrade);
        } else if (order.strikeTrade.orderType == OrderTypes.STOP_LOSS) {
            return validStopLossOrder(order.strikeTrade);
        }

        // unknown order type
        // @notice execution should never reach here
        // @dev needed to satisfy types
        return (false, 0);
    }

    /**
     * @notice check validity of limit orderid
     * @param _trade trade details
     * @return valid
     * @return premium
     */
    function validLimitOrder(StrikeTrade memory _trade) internal view returns (bool, uint) {
        (uint256 totalPremium, ) = getQuote(_trade.strikeId, _trade);
        bool isLong = _isLong(_trade.optionType);

        if (isLong) {
            if (_trade.targetPrice < totalPremium) {
                return (false, 0);
            } else {
                return (true, totalPremium);
            }
        } else {
            if (_trade.targetPrice < totalPremium) {
                return (true, totalPremium);
            } else {
                return (false, 0);
            }
        }
    }

    /**
     * @notice check validity of limit vol orderid
     * @param _trade trade details
     * @return valid
     * @return premium
     */
    function validLimitVolOrder(StrikeTrade memory _trade) internal view returns (bool, uint) {
        uint[] memory strikeId = _toDynamic(_trade.strikeId);
        uint vol = lyraBase(_trade.market).getVols(strikeId)[0];
        bool isLong = _isLong(_trade.optionType);

        if (isLong) {
            if (_trade.targetVolatility < vol) {
                (uint256 totalPremium, ) = getQuote(_trade.strikeId, _trade);
                return (true, totalPremium);
            } else {
                return (false, 0);
            }
        } else {
            if (_trade.targetVolatility > vol) {
                (uint256 totalPremium, ) = getQuote(_trade.strikeId, _trade);
                return (true, totalPremium);
            } else {
                return (false, 0);
            }
        }
    }

    /**
     * @notice check validity of take profit
     * @param _trade trade details
     * @return valid
     * @return premium
     */
    function validTakeProfitOrder(StrikeTrade memory _trade) internal view returns (bool, uint) {
        (uint256 totalPremiumClose, ) = getQuote(_trade.strikeId, _trade);

        /**
         *
         * @dev
         * targetPrice close at $12 and totalPremium is $10
         * ui shows at $12 close still profit at $1
         */
        if (_trade.targetPrice > totalPremiumClose) {
            return (true, totalPremiumClose);
        } else {
            return (false, 0);
        }
    }

    /**
     * @notice check validity of stop loss order
     * @param _trade trade details
     * @return valid
     * @return premium
     */
    function validStopLossOrder(StrikeTrade memory _trade) internal view returns (bool, uint) {
        (uint256 totalPremiumClose, ) = getQuote(_trade.strikeId, _trade);

        /**
         * @dev if original position is long we need a short to close
         * targetPrice will usually the max the user wants to pay to close the
         * position
         * example for a long
         * Buy $1800 ETH Call for $18 / contract
         * Trade is going against me
         * As price to close increases i lose more
         * $20 to close
         * $21 to close
         * if it's $21.50 stop loss and close it and my target was $21.40
         * if 21.40 and price 21.50 // close it
         * @dev if original position is short we need to buy/long position to close
         * targetprice will usually (in ui we can show)
         * $12 targetPrice and total premium close is $13
         * shouldve closed a while ago
         * $12 targetPrice and totalpremium is $11
         */

        if (_trade.targetPrice < totalPremiumClose) {
            return (true, totalPremiumClose);
        } else {
            return (false, 0);
        }
    }

    /**
     * @notice execute order if valid
     * @param _orderId trade order id
     */
    function executeOrder(uint256 _orderId) external onlyOps {
        (bool isValidOrder, uint256 premiumLimit) = validOrder(_orderId);
        if (!isValidOrder) {
            revert OrderInvalid(_orderId); /// @dev add premium limit and order id
        }
        StrikeTradeOrder memory order = orders[_orderId];
        StrikeTrade memory strikeTrade = order.strikeTrade;
        ILyraBase.Strike memory strike = lyraBase(strikeTrade.market).getStrikes(
            _toDynamic(strikeTrade.strikeId)
        )[0];

        bool isLong = _isLong(strikeTrade.optionType);
        uint positionId;
        uint premium;

        if (isLong) {
            (positionId, premium) = buyStrike(strikeTrade, premiumLimit);
        } else {
            (uint collateralToAdd, uint setCollateralTo) = _getRequiredCollateral(
                strikeTrade,
                strike.strikePrice,
                strike.expiry
            );

            (positionId, premium) = sellStrike(strikeTrade, setCollateralTo, premiumLimit);
        }

        committedMargin -= order.committedMargin;

        // delete order from orders
        IOps(ops).cancelTask(order.gelatoTaskId);

        delete orders[_orderId];

        emit OrderFilled(address(this), _orderId);
    }

    function _getRequiredCollateral(
        StrikeTrade memory _trade,
        uint _strikePrice,
        uint _expiry
    ) internal view returns (uint collateralToAdd, uint setCollateralTo) {
        (collateralToAdd, setCollateralTo) = lyraBase(_trade.market).getRequiredCollateral(
            _trade.size,
            _trade.optionType,
            _trade.positionId,
            _strikePrice,
            _expiry,
            COLLATERAL_BUFFER,
            _trade.collatPercent
        );
    }

    /**
     * @notice cancels order
     * @param _orderId order id
     */
    function cancelOrder(uint256 _orderId) external onlyOwner {
        StrikeTradeOrder memory order = orders[_orderId];
        IOps(ops).cancelTask(order.gelatoTaskId);
        // remove from committed margin
        committedMargin -= order.committedMargin;

        // delete order from orders
        delete orders[_orderId];
        emit OrderCancelled(address(this), _orderId);
    }

    /************************************************
     *  BUY / SELL STRIKE ON LYRA
     ***********************************************/

    /**
     * @notice perform the buy
     * @param _trade strike trade info
     * @param _maxPremium max price acceptable
     * @return positionId
     * @return totalCost
     */
    function buyStrike(StrikeTrade memory _trade, uint _maxPremium) internal returns (uint, uint) {
        uint __maxPremium = _maxPremium + (_maxPremium.multiplyDecimal(1000000000000000));
        // perform trade to long
        TradeResult memory result = openPosition(
            _trade.market,
            TradeInputParameters({
                strikeId: _trade.strikeId,
                // send existing positionid or 0 if new
                positionId: _trade.positionId,
                iterations: _trade.iterations,
                optionType: _trade.optionType,
                amount: _trade.size,
                setCollateralTo: 0,
                minTotalCost: 0,
                maxTotalCost: __maxPremium, // add slippage for testing
                // set to zero address if don't want to wait for whitelist
                rewardRecipient: address(owner())
            })
        );

        if (result.totalCost > __maxPremium) {
            revert PremiumAboveExpected(result.totalCost, _maxPremium);
        }

        return (result.positionId, result.totalCost);
    }

    /**
     * @notice perform the sell
     * @param _trade strike trade info
     * @param _setCollateralTo target collateral amount
     * @param _minExpectedPremium min premium acceptable
     * @return positionId lyra position id
     * @return totalCost the premium received from selling
     */
    function sellStrike(
        StrikeTrade memory _trade,
        uint _setCollateralTo,
        uint _minExpectedPremium
    ) internal returns (uint, uint) {
        // perform trade
        TradeResult memory result = openPosition(
            _trade.market,
            TradeInputParameters({
                strikeId: _trade.strikeId,
                // send existing positionid or 0 if new
                positionId: _trade.positionId,
                iterations: _trade.iterations,
                optionType: _trade.optionType,
                amount: _trade.size,
                setCollateralTo: _setCollateralTo,
                minTotalCost: _minExpectedPremium,
                maxTotalCost: type(uint).max,
                // set to zero address if don't want to wait for whitelist
                rewardRecipient: address(owner())
            })
        );
        if (result.totalCost < _minExpectedPremium) {
            revert PremiumBelowExpected(result.totalCost, _minExpectedPremium);
        }

        return (result.positionId, result.totalCost);
    }

    /**
     * @notice open a position in lyra mm
     * @param params params to open trade on lyra
     * @return result of opening trade
     */
    function openPosition(
        bytes32 market,
        TradeInputParameters memory params
    ) internal returns (TradeResult memory) {
        address optionMarket = lyraBase(market).getOptionMarket();

        IOptionMarket.TradeInputParameters memory convertedParams = _convertParams(params);
        IOptionMarket.Result memory result = IOptionMarket(optionMarket).openPosition(
            convertedParams
        );

        return
            TradeResult({
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee
            });
    }

    /**
     * @notice close a position in lyra mm
     * @param params params to close trade on lyra
     * @return result of trade
     */
    function closePosition(
        bytes32 market,
        TradeInputParameters memory params
    ) internal returns (TradeResult memory) {
        address optionMarket = lyraBase(market).getOptionMarket();

        IOptionMarket.Result memory result = IOptionMarket(optionMarket).closePosition(
            _convertParams(params)
        );

        return
            TradeResult({
                positionId: result.positionId,
                totalCost: result.totalCost,
                totalFee: result.totalFee
            });
    }

    function _convertParams(
        TradeInputParameters memory _params
    ) internal pure returns (IOptionMarket.TradeInputParameters memory) {
        return
            IOptionMarket.TradeInputParameters({
                strikeId: _params.strikeId,
                positionId: _params.positionId,
                iterations: _params.iterations,
                optionType: IOptionMarket.OptionType(_params.optionType),
                amount: _params.amount,
                setCollateralTo: _params.setCollateralTo,
                minTotalCost: _params.minTotalCost, // can used this for stop loss take profit
                maxTotalCost: _params.maxTotalCost // can used this for stop loss take profit
            });
    }

    /************************************************
     *  BALANCE / COMMITTED BALANCE
     ***********************************************/
    /**
     * @notice check balance after committed margin
     * @return free margin
     */
    function freeMargin() public view returns (uint) {
        return quoteAsset.balanceOf(address(this)) - committedMargin;
    }

    /************************************************
     *  DEPOSIT / WITHDRAW
     ***********************************************/

    /**
     * @notice deposit funds
     * @param _amount amount of quote funds
     */
    function deposit(uint256 _amount) public onlyOwner {
        _deposit(_amount);
    }

    /**
     * @notice deposit
     * @param _amount  amount of quote funds
     */
    function _deposit(uint _amount) internal {
        require(
            quoteAsset.transferFrom(address(msg.sender), address(this), _amount),
            "deposit from user failed"
        );

        emit Deposit(msg.sender, _amount);
    }

    /**
     * @notice  amount of marginAsset to withdraw
     * @param _amount withdrawal amount
     */
    function withdraw(uint256 _amount) external onlyOwner {
        // make sure committed margin isn't withdrawn
        if (_amount > freeMargin()) {
            revert InsufficientFreeMargin(freeMargin(), _amount);
        }

        // transfer out margin asset to user
        // (will revert if account does not have amount specified)
        require(quoteAsset.transfer(owner(), _amount), "AccountOrder: withdraw failed");

        emit Withdraw(msg.sender, _amount);
    }

    /**
     * @notice allow users to withdraw ETH deposited for keeper fees
     * @param _amount amount to withdraw
     */
    function withdrawEth(uint256 _amount) external onlyOwner {
        // solhint-disable-next-line
        (bool success, ) = payable(owner()).call{value: _amount}("");
        if (!success) {
            revert EthWithdrawalFailed();
        }
    }

    /************************************************
     *  Internal Lyra Base Getter
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

    /************************************************
     *  UTIL FUNCTIONS
     ***********************************************/
    /**
     * @notice check if long/buy
     * @param _optionType lyra option type
     * @return isLong
     */
    function _isLong(uint _optionType) public pure returns (bool isLong) {
        if (
            OptionType(_optionType) == OptionType.LONG_CALL ||
            OptionType(_optionType) == OptionType.LONG_PUT
        ) {
            isLong = true;
        }
    }

    // temporary fix - eth core devs promised Q2 2022 fix
    function _toDynamic(uint val) internal pure returns (uint[] memory dynamicArray) {
        dynamicArray = new uint[](1);
        dynamicArray[0] = val;
    }

    /************************************************
     *  lyra quoter
     ***********************************************/
    function getQuote(
        uint strikeId,
        StrikeTrade memory _trade
    ) public view returns (uint totalPremium, uint totalFees) {
        (totalPremium, totalFees) = lyraBase(_trade.market).getQuote(
            strikeId,
            _trade.iterations,
            _trade.optionType,
            _trade.size,
            _trade.tradeDirection, // 0 open 1 close 2 liquidate
            false
        );
    }

    /************************************************
     *  EVENTS
     ***********************************************/

    /// @notice emitted after a successful deposit
    /// @param user: the address that deposited into account
    /// @param amount: amount of marginAsset to deposit into marginBase account
    event Deposit(address indexed user, uint256 amount);

    /// @notice emitted after a successful withdrawal
    /// @param user: the address that withdrew from account
    /// @param amount: amount of marginAsset to withdraw from marginBase account
    event Withdraw(address indexed user, uint256 amount);

    /// @notice emitted when an advanced order is cancelled
    event OrderCancelled(address indexed account, uint256 orderId);

    /// @notice emitted when an order is executed
    /// @param account user
    /// @param _orderId orderId
    event OrderFilled(address indexed account, uint _orderId);

    /// @notice emitted after order is placed with keeper
    /// @param account: user
    /// @param _orderId: _orderId
    /// @param _tradeOrder: order details
    event StrikeOrderPlaced(address indexed account, uint _orderId, StrikeTradeOrder _tradeOrder);

    /************************************************
     *  ERRORS
     ***********************************************/
    /// @notice cannot execute invalid order
    error OrderInvalid(uint _orderId);

    /// @notice call to transfer ETH on withdrawal fails
    error EthWithdrawalFailed();

    /// @notice Must have a minimum eth balance before placing an order
    /// @param balance: current ETH balance
    /// @param minimum: min required ETH balance
    error InsufficientEthBalance(uint256 balance, uint256 minimum);

    /// @notice exceeds useable margin
    /// @param available: amount of useable margin asset
    /// @param required: amount of margin asset required
    error InsufficientFreeMargin(uint256 available, uint256 required);

    /// @notice premium below expected
    /// @param actual actual premium
    /// @param expected expected premium
    error PremiumBelowExpected(uint actual, uint expected);

    /// @notice price above expected
    /// @param actual actual premium
    /// @param expected expected premium
    error PremiumAboveExpected(uint actual, uint expected);

    /// @notice strike has to be valid
    /// @param strikeId lyra strikeid
    /// @param market name of the market
    error InvalidStrike(uint strikeId, bytes32 market);

    /// @notice order combo not valid
    error InvalidOrderType();
}
