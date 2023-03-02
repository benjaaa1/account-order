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

    enum OrderTypes {
        MARKET,
        LIMIT,
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
        uint collatPercent;
        uint iterations;
        uint tradeDirection;
        bytes32 market;
        uint optionType;
        uint strikeId;
        uint size;
        uint positionId;
        uint targetPrice;
        OrderTypes orderType;
    }

    struct StrikeTradeOrder {
        StrikeTrade strikeTrade;
        bytes32 gelatoTaskId;
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
        lyraBases[keccak256("eth")] = ILyraBase(_ethLyraBase);
        lyraBases[keccak256("btc")] = ILyraBase(_btcLyraBase);
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
    function placeOrder(StrikeTrade memory _trade) public onlyOwner {
        if (address(this).balance < 1 ether / 100) {
            revert InsufficientEthBalance(address(this).balance, 1 ether / 100);
        }

        // trigger order should have
        if (
            (_trade.orderType == OrderTypes.TAKE_PROFIT ||
                _trade.orderType == OrderTypes.STOP_LOSS) &&
            _trade.positionId == 0
        ) {
            revert InvalidOrderType();
        }

        bool isLong = _isLong(_trade.optionType);

        uint requiredCapital;

        ILyraBase.Strike memory strike = lyraBase(_trade.market).getStrikes(
            _toDynamic(_trade.strikeId)
        )[0];

        if (isLong) {
            // targetprice replaces premium for buy
            requiredCapital = _trade.size.multiplyDecimal(_trade.targetPrice);
        } else {
            // getRequiredCollateral for both of these is best
            uint collateralToAdd = _getRequiredCollateral(
                _trade,
                strike.strikePrice,
                strike.expiry
            );

            requiredCapital = collateralToAdd;
        }

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
            gelatoTaskId: taskId
        });

        emit StrikeOrderPlaced(address(msg.sender), orders[orderId]);

        orderId++;
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
        execPayload = abi.encodeWithSelector(
            this.executeOrder.selector,
            _orderId
        );
    }

    /**
     * @notice check validity of orderid
     * @param _orderId trade order id
     * @return valid
     * @return premium
     */
    function validOrder(uint256 _orderId) public view returns (bool, uint) {
        StrikeTradeOrder memory order = orders[_orderId];

        if (order.strikeTrade.orderType == OrderTypes.LIMIT) {
            return validLimitOrder(order.strikeTrade);
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
    function validLimitOrder(
        StrikeTrade memory _trade
    ) internal view returns (bool, uint) {
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
     * @notice check validity of take profit
     * @param _trade trade details
     * @return valid
     * @return premium
     */
    function validTakeProfitOrder(
        StrikeTrade memory _trade
    ) internal view returns (bool, uint) {
        // (, ILyraBase.Strike memory strike) = _getValidStrike(_trade);
        // bool isLong = _isLong(_trade.optionType);
        // bool isMin = isLong ? false : true;
        // uint premiumLimit = _getPremiumLimit(
        //     _trade,
        //     strike.expiry,
        //     strike.strikePrice,
        //     isMin
        // );
        // uint premium = _getQuote();
        // // take profits is somethign with reversed
        // if (isLong) {
        //     if (_trade.targetPrice < premiumLimit) {
        //         return (false, 0);
        //     } else {
        //         return (true, premiumLimit);
        //     }
        // } else {
        //     if (_trade.targetPrice > premiumLimit) {
        //         return (false, 0);
        //     } else {
        //         return (true, premiumLimit);
        //     }
        // }
    }

    /**
     * @notice check validity of stop loss order
     * @param _trade trade details
     * @return valid
     * @return premium
     */
    function validStopLossOrder(
        StrikeTrade memory _trade
    ) internal view returns (bool, uint) {}

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

        ILyraBase.Strike memory strike = lyraBase(strikeTrade.market)
            .getStrikes(_toDynamic(strikeTrade.strikeId))[0];

        // if (!_isValid) {
        //     revert InvalidStrike(strikeTrade.strikeId, strikeTrade.market);
        // }

        bool isLong = _isLong(strikeTrade.optionType);

        uint positionId;
        uint premium;

        if (isLong) {
            (positionId, premium) = buyStrike(strikeTrade, premiumLimit);
        } else {
            uint setCollateralTo = _getRequiredCollateral(
                strikeTrade,
                strike.strikePrice,
                strike.expiry
            );

            (positionId, premium) = sellStrike(
                strikeTrade,
                setCollateralTo,
                premiumLimit
            );
        }

        emit OrderFilled(address(this), _orderId, premium);
    }

    function _getRequiredCollateral(
        StrikeTrade memory _trade,
        uint _strikePrice,
        uint _expiry
    ) internal view returns (uint etCollateralTo) {}

    /**
     * @notice cancels order
     * @param _orderId order id
     */
    function cancelOrder(uint256 _orderId) external onlyOwner {
        StrikeTradeOrder memory order = orders[_orderId];
        IOps(ops).cancelTask(order.gelatoTaskId);
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
    function buyStrike(
        StrikeTrade memory _trade,
        uint _maxPremium
    ) internal returns (uint, uint) {
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
                maxTotalCost: _maxPremium,
                // set to zero address if don't want to wait for whitelist
                rewardRecipient: address(0)
            })
        );

        if (result.totalCost > _maxPremium) {
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
                rewardRecipient: address(0)
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
        IOptionMarket.TradeInputParameters
            memory convertedParams = _convertParams(params);
        IOptionMarket.Result memory result = IOptionMarket(optionMarket)
            .openPosition(convertedParams);

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

        IOptionMarket.Result memory result = IOptionMarket(optionMarket)
            .closePosition(_convertParams(params));

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
            quoteAsset.transferFrom(
                address(msg.sender),
                address(this),
                _amount
            ),
            "collateral transfer from user failed"
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
        require(
            quoteAsset.transfer(owner(), _amount),
            "AccountOrder: withdraw failed"
        );

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
        require(
            address(lyraBases[market]) != address(0),
            "LyraBase: Not available"
        );
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
    function _toDynamic(
        uint val
    ) internal pure returns (uint[] memory dynamicArray) {
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
        return
            lyraBase(_trade.market).getQuote(
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
    /// @param _premium premium
    event OrderFilled(address indexed account, uint _orderId, uint _premium);

    /// @notice emitted after order is placed with keeper
    /// @param account: user
    /// @param _tradeOrder: order details
    event StrikeOrderPlaced(
        address indexed account,
        StrikeTradeOrder _tradeOrder
    );

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
