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
    struct PoolHedgerParameters {
        uint interactionDelay;
        uint hedgeCap;
    }

    struct FuturesPoolHedgerParameters {
        uint acceptableSpotSlippage; // If spot is off by this % revert hedge. Note this is per trade not the full cycle.
        uint deltaThreshold; // Bypass interaction delay if delta is outside of a certain range.
        uint marketDepthBuffer; // delta buffer. 50 -> 50 eth buffer
        uint targetLeverage; // target leverage ratio
        uint maxLeverage; // the max leverage for increasePosition before the hedger will revert
        uint minCancelDelay; // seconds until an order can be cancelled
        uint minCollateralUpdate;
        bool vaultLiquidityCheckEnabled; // if true, block opening trades if the vault is low on liquidity
    }

    struct PositionDetails {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        // int256 realisedPnl;
        int256 unrealisedPnl;
        uint256 lastIncreasedTime;
        bool isLong;
    }

    struct CurrentPositions {
        PositionDetails longPosition;
        PositionDetails shortPosition;
        uint amountOpen;
        bool isLong; // only valid if amountOpen == 1
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

    uint256 public committedMargin;

    /// @inheritdoc IAccount
    uint256 public conditionalOrderId;

    /// @notice track conditional orders by id
    // mapping(uint256 id => ConditionalOrder order) internal conditionalOrders;

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

    /**
     * @notice Initializer strategy
     * @param _vault vault that owns strategy
     */
    function initialize(address _vault) external initializer {
        otusVault = OtusVault(_vault);
    }

    /******************************************************
     * HEDGE STRATEGY
     *****************************************************/

    function placeOrder() external onlyVault {
        /// @todo place hedge order
    }

    function validOrder() public view returns (bool) {
        /// @todo check if order is valid

        return (false, 0);
    }

    function checker(uint256 _orderId) external view returns (bool canExec, bytes memory execPayload) {
        (canExec, ) = validOrder(_orderId);
        execPayload = abi.encodeWithSelector(this.executeOrder.selector, _orderId);
    }

    function executeOrder(uint256 _orderId) external onlyOps {}

    /******************************************************
     * TRANSFERS
     *****************************************************/
    /**
     * @notice transfer from vault
     * @param _amount quote amount to transfer
     */
    function _trasferFromVault(uint _amount) internal override {
        require(
            quoteAsset.transferFrom(address(vault), address(this), _amount),
            "collateral transfer from vault failed"
        );
    }

    /**
     * @notice transfer to vault
     * @param _quoteBal quote amount to transfer
     */
    function _trasferFundsToVault(uint _quoteBal) internal override {
        if (_quoteBal > 0 && !quoteAsset.transfer(address(otusVault), _quoteBal)) {
            revert QuoteTransferFailed(address(this), address(otusVault), _quoteBal);
        }
        emit QuoteReturnedToLP(_quoteBal);
    }
}
