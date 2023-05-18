//SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;
pragma experimental ABIEncoderV2;

// Interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/gelato/IOps.sol";
import {ITradeTypes} from "../interfaces/ITradeTypes.sol";

// Libraries
import {SignedDecimalMath} from "@lyrafinance/protocol/contracts/synthetix/SignedDecimalMath.sol";
import {DecimalMath} from "@lyrafinance/protocol/contracts/synthetix/DecimalMath.sol";

import {IFuturesMarketManager} from "@synthetix/IFuturesMarketManager.sol";
import {IPerpsV2MarketConsolidated} from "@synthetix/IPerpsV2MarketConsolidated.sol";
import {ISystemStatus} from "@synthetix/ISystemStatus.sol"
// Vault
import {OtusVault} from "./OtusVault.sol";

// Markets
import {OtusOptionMarket} from "../markets/OtusOptionMarket.sol";
import {SpreadMarket} from "../markets/SpreadMarket.sol";
import {SimpleInitializable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializable.sol";
import {OpsReady} from "../utils/OpsReady.sol";

/**
 * @title Strategy - Options
 * @author Otus
 * @dev Executes strategy for vault based on settings with hedge support
 */
contract StrategyHeder is OpsReady {
    using SafeDecimalMath for uint;
    using SignedDecimalMath for int;

    /************************************************
     *  STRUCTS
     ***********************************************/

    struct StrategyHedgeDetail {
        uint hedgeIntervalDelay; // after closing order able to reopen time 
        uint hedgeFundsBuffer; // amount of 
	    uint maxLeverage; // max leverage to use while hedging 1 - 3x
	    uint deltaHedgePercentage; // full 100% 90%
    }

    struct ConditionalHedgeOrder {
        bytes32 marketKey;
        int256 marginDelta;
        int256 sizeDelta;
        uint256 targetPrice;
        bytes32 gelatoTaskId;
        uint256 desiredFillPrice;
        bool reduceOnly;
        bool activePosition; 
        uint256 lastExecuted; 
    }

    /************************************************
     *  CONSTANTS
     ***********************************************/

    /// @notice tracking code used when modifying positions
    bytes32 internal constant TRACKING_CODE = "OTUS";

    /************************************************
     *  IMMUTABLES
     ***********************************************/

    /// @notice address of the Synthetix ProxyERC20sUSD contract used as the margin asset
    /// @dev can be immutable due to the fact the sUSD contract is a proxy address
    IERC20 internal immutable MARGIN_ASSET;

    /// @notice address of the Synthetix FuturesMarketManager
    /// @dev the manager keeps track of which markets exist, and is the main window between
    /// perpsV2 markets and the rest of the synthetix system. It accumulates the total debt
    /// over all markets, and issues and burns sUSD on each market's behalf
    IFuturesMarketManager internal immutable FUTURES_MARKET_MANAGER;

    /// @notice address of the Synthetix SystemStatus
    /// @dev the system status contract is used to check if the system is operational
    ISystemStatus internal immutable SYSTEM_STATUS;

    /************************************************
     *  INIT STATE
     ***********************************************/

    OtusVault public otusVault;

    /************************************************
     *  STATE
     ***********************************************/

    StrategyHedgeDetail public strategyHedgeDetail; 

    uint256 public committedMargin;

    /// @inheritdoc IAccount
    uint256 public hedgeOrderId;

    /// @notice track hedge orders by id
    mapping(uint256 => ConditionalHedgeOrder) internal conditionalHedgeOrders;

    /************************************************
     *  ADMIN
     ***********************************************/

    modifier onlyVault() virtual {
        require(msg.sender == address(vault), "only Vault");
        _;
    }

    constructor(address _marginAsset, address _futuresMarketManager, address _systemStatus) {
        MARGIN_ASSET = IERC20(_marginAsset);
        FUTURES_MARKET_MANAGER = IFuturesMarketManager(_futuresMarketManager);
        SYSTEM_STATUS = ISystemStatus(_systemStatus);
    }

    
    /************************************************
     *  HEDGE STRATEGY SETTERS
     ***********************************************/

    /**
     * @notice Update the hedge strategy for the new round
     * @param _strategyHedgeDetail vault strategy settings
     */
    function setHedgeStrategy(StrategyHedgeDetail memory _strategyHedgeDetail) external onlyOwner {
        (, , , , , , , bool roundInProgress) = otusVault.vaultState();

        if (roundInProgress) {
            revert RoundInProgress();
        }

        strategyHedgeDetail = _strategyHedgeDetail;

        emit StrategyHedgeUpdated(msg.sender, _strategyHedgeDetail);
    }


    /******************************************************
     * HEDGE STRATEGY
     *****************************************************/

    /**
     * @notice place a hedge order
     * @param tradeInfo the market to trade on and position
     * @param _shortTrades trades
     */
    function placeHedgeOrder(TradeInfo memory tradeInfo, TradeInputParameters memory _trade, uint premium) internal {
        /// @todo place hedge order
        ILyraBase _lyraBase = lyraBase(tradeInfo.market);
        ILyraBase.Strike memory strike = _lyraBase.getStrike(trade.strikeId);
        // uint strikePrice, uint optionType, uint size, uint premium
        uint targetPrice = _getTargetPrice({
            strikePrice: strike.strikePrice,
            optionType: _trade.optionType,
            size: _trade.size,
            premium: premium
        });

        int _sizeDelta = _getSizeDelta(strike.strikePrice, _trade); // should be divided by target price and leverage
        int _marginDelta = _sizeDelta.divideDecimal(strategyHedgeDetail.maxLeverage);
        uint desiredFillPrice;

        _placeOrder({
            _marketKey = tradeInfo.market,
            _marginDelta = _marginDelta,
            _sizeDelta = _sizeDelta,
            _targetPrice = targetPrice,
            _desiredFillPrice = targetPrice,
            _reduceOnly = false
        });

    }

    /**
     * @notice place orders 
     */
    function _placeOrder(
        bytes32 _marketKey,
        int _marginDelta,
        int _sizeDelta,
        uint _targetPrice,
        uint _desiredFillPrice,
        bool _reduceOnly
    ) internal {
        /// @todo place hedge order
        if (_sizeDelta == 0) revert ZeroSizeDelta();

        if (_marginDelta > 0) {
            _sufficientMargin(_marginDelta);
            committedMargin += _abs(_marginDelta);
        }

        bytes32 taskId = _createGelatoTask();

        hedgeOrders[hedgeOrderId] = ConditionalHedgeOrder({
            marketKey: _marketKey,
            marginDelta: _marginDelta,
            sizeDelta: _sizeDelta,
            targetPrice: _targetPrice,
            gelatoTaskId: taskId,
            desiredFillPrice: _desiredFillPrice,
            reduceOnly: _reduceOnly
        });

        // emit event

        hedgeOrderId++;
    }

    /// @notice create a new Gelato task for a conditional order
    /// @return taskId of the new Gelato task
    function _createGelatoTask() internal returns (bytes32 taskId) {
        IOps.ModuleData memory moduleData = _createGelatoModuleData();

        taskId = IOps(OPS).createTask({
            execAddress: address(this),
            execData: abi.encodeCall(this.executeConditionalOrder, conditionalOrderId),
            moduleData: moduleData,
            feeToken: ETH
        });
    }

    /// @notice create the Gelato ModuleData for a conditional order
    /// @dev see IOps for details on the task creation and the ModuleData struct
    function _createGelatoModuleData() internal view returns (IOps.ModuleData memory moduleData) {
        moduleData = IOps.ModuleData({modules: new IOps.Module[](1), args: new bytes[](1)});

        moduleData.modules[0] = IOps.Module.RESOLVER;
        moduleData.args[0] = abi.encode(address(this), abi.encodeCall(this.checker, conditionalOrderId));
    }

    /******************************************************
     *  VIEWS
     *****************************************************/

    function _getSizeDelta(uint strikePrice, TradeInputParameters memory trade) internal view returns (int) {
        int _sizeDelta = 0;
        int exposure = SafceCast.toInt256(strikePrice.multiplyDecimal(trade.size));

        if (_isCall(trade.optionType)) {
            _sizeDelta += exposure;
        } else {
            _sizeDelta -= exposure;
        }

        return _sizeDelta;
    }

    function checker(uint256 _hedgeOrderId) external view returns (bool canExec, bytes memory execPayload) {
        (canExec, ) = validOrder(_hedgeOrderId);
        execPayload = abi.encodeWithSelector(this.executeOrder.selector, _orderId);
    }

    function validOrder(uint _hedgeOrderId) internal view returns (bool) {
        /// @todo check if order is valid
        ConditionalHedgeOrder memory order = conditionalHedgeOrders[_hedgeOrderId];

        // hedge position is not active 
        if(order.activePosition) {
            return false; 
        }

        bool timeDelayValid = block.timestamp - order.lastExecuted > strategyHedgeDetail.hedgeIntervalDelay;

        if(!timeDelayValid) {
            return false;
        }

        // return false if market is paused
        try SYSTEM_STATUS.requireFuturesMarketActive(order.marketKey) {} catch {
            return false;
        }

        uint256 price = _sUSDRate(_getPerpsV2Market(order.marketKey));

        if (order.sizeDelta > 0) {
            return price <= order.targetPrice;
        } else {
            return price >= order.targetPrice;
        }
    }

    /******************************************************
     *  EXECUTE
     *****************************************************/

    function executeOrder(uint256 _hedgeOrderId) external onlyOps {
        ConditionalHedgeOrder storage order = conditionalHedgeOrders[_hedgeOrderId];

        // do not delete conditional hedge order
        // but flag that it is active 
        order.activePosition = true;
        order.lastExecuted = block.timestamp;


        // remove gelato task from their accounting
        /// @dev will revert if task id does not exist {Automate.cancelTask: Task not found}
        // IOps(OPS).cancelTask({taskId: conditionalOrder.gelatoTaskId});

        // define Synthetix PerpsV2 market
        IPerpsV2MarketConsolidated market = _getPerpsV2Market(conditionalOrder.marketKey);

        /// @dev conditional order is valid given checker() returns true; define fill price
        uint256 fillPrice = _sUSDRate(market);

        // if conditional order is reduce only, ensure position size is only reduced
        if (order.reduceOnly) {
            int256 currentSize = market.positions({account: address(this)}).size;

            // ensure position exists and incoming size delta is NOT the same sign
            /// @dev if incoming size delta is the same sign, then the conditional order is not reduce only
            if (currentSize == 0 || _isSameSign(currentSize, conditionalOrder.sizeDelta)) {
                HedgeOrderCancelled({
                    conditionalOrderId: _conditionalOrderId,
                    gelatoTaskId: conditionalOrder.gelatoTaskId,
                    reason: ConditionalOrderCancelledReason.CONDITIONAL_ORDER_CANCELLED_NOT_REDUCE_ONLY
                });

                return;
            }

            // ensure incoming size delta is not larger than current position size
            /// @dev reduce only conditional orders can only reduce position size (i.e. approach size of zero) and
            /// cannot cross that boundary (i.e. short -> long or long -> short)
            if (_abs(order.sizeDelta) > _abs(currentSize)) {
                // bound conditional order size delta to current position size
                order.sizeDelta = -currentSize;
            }
        }

        // if margin was committed, free it
        if (order.marginDelta > 0) {
            committedMargin -= _abs(order.marginDelta);
        }

        // execute trade
        _perpsV2ModifyMargin({_market: address(market), _amount: order.marginDelta});
        _perpsV2SubmitOffchainDelayedOrder({
            _market: address(market),
            _sizeDelta: order.sizeDelta,
            _desiredFillPrice: order.desiredFillPrice
        });

        // pay Gelato imposed fee for conditional order execution
        (uint256 fee, address feeToken) = IOps(OPS).getFeeDetails();
        _transfer({_amount: fee, _paymentToken: feeToken});

        emit HedgeOrderFilled({
            conditionalOrderId: _hedgeOrderId,
            gelatoTaskId: order.gelatoTaskId,
            fillPrice: fillPrice,
            keeperFee: fee
        });

        // place order to close hedge position 
    }

    /******************************************************
     *  MODIFY MARKET MARGIN
     *****************************************************/

    /// @notice deposit/withdraw margin to/from a Synthetix PerpsV2 Market
    /// @param _market: address of market
    /// @param _amount: amount of margin to deposit/withdraw
    function _perpsV2ModifyMargin(address _market, int256 _amount) internal {
        if (_amount > 0) {
            _sufficientMargin(_amount);
        }
        IPerpsV2MarketConsolidated(_market).transferMargin(_amount);
    }

    /// @notice withdraw margin from market back to this account
    /// @dev this will *not* fail if market has zero margin
    function _perpsV2WithdrawAllMargin(address _market) internal {
        IPerpsV2MarketConsolidated(_market).withdrawAllMargin();
    }

    /******************************************************
     *  DELAYED OFFCHAIN ORDERS
     *****************************************************/

    /// @notice submit an off-chain delayed order to a Synthetix PerpsV2 Market
    /// @param _market: address of market
    /// @param _sizeDelta: size delta of order
    /// @param _desiredFillPrice: desired fill price of order
    function _perpsV2SubmitOffchainDelayedOrder(
        address _market,
        int256 _sizeDelta,
        uint256 _desiredFillPrice
    ) internal {
        IPerpsV2MarketConsolidated(_market).submitOffchainDelayedOrderWithTracking({
            sizeDelta: _sizeDelta,
            desiredFillPrice: _desiredFillPrice,
            trackingCode: TRACKING_CODE
        });
    }

    /******************************************************
     *  MARGIN UTILITIES
     *****************************************************/

    function freeMargin() public view override returns (uint256) {
        return MARGIN_ASSET.balanceOf(address(this)) - committedMargin;
    }

    /// @notice check that margin attempted to be moved/locked is within free margin bounds
    /// @param _marginOut: amount of margin to be moved/locked
    function _sufficientMargin(int256 _marginOut) internal view {
        if (_abs(_marginOut) > freeMargin()) {
            revert InsufficientFreeMargin(freeMargin(), _abs(_marginOut));
        }
    }

    /******************************************************
     *  UTILITIES
     *****************************************************/
    /**
     * @notice getth
     */
    function _getTargetPrice(uint strikePrice, uint optionType, uint size, uint premium) public view returns (uint256) {
        premium = premium.divideDecimal(size);

        if (_isCall(optionType)) {
            return strikePrice + premium;
        } else {
            return strikePrice - premium;
        }
    }

    /// @notice get exchange rate of underlying market asset in terms of sUSD
    /// @param _market: Synthetix PerpsV2 Market
    /// @return price in sUSD
    function _sUSDRate(IPerpsV2MarketConsolidated _market) internal view returns (uint256) {
        (uint256 price, bool invalid) = _market.assetPrice();
        if (invalid) {
            revert InvalidPrice();
        }
        return price;
    }

    function _isCall(uint _optionType) public pure returns (bool isCall) {
        if (OptionType(_optionType) == OptionType.LONG_CALL || OptionType(_optionType) == OptionType.SHORT_CALL_QUOTE) {
            isCall = true;
        }
    }

    function _isLong(uint _optionType) internal pure returns (bool isLong) {
        if (OptionType(_optionType) == OptionType.LONG_CALL || OptionType(_optionType) == OptionType.LONG_PUT) {
            isLong = true;
        }
    }


    /******************************************************
     *  EVENTS
     *****************************************************/

    event HedgeOrderFilled(
        address indexed account,
        uint256 indexed conditionalOrderId,
        bytes32 indexed gelatoTaskId,
        uint256 fillPrice,
        uint256 keeperFee
    );

    event HedgeOrderCancelled(
        address indexed account,
        uint256 indexed conditionalOrderId,
        bytes32 indexed gelatoTaskId,
        IAccount.ConditionalOrderCancelledReason reason
    );

}
