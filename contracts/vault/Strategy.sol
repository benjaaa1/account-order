// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// Interfaces
import {IERC20Decimals} from "../interfaces/IERC20Decimals.sol";
import "../interfaces/gelato/IOps.sol";
import {ITradeTypes} from "../interfaces/ITradeTypes.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

// Libraries
import {SignedDecimalMath} from "@lyrafinance/protocol/contracts/synthetix/SignedDecimalMath.sol";
import "../synthetix/SafeDecimalMath.sol";

// Vault
import {OtusVault} from "./OtusVault.sol";
// import {StrategyHedger} from "./StrategyHedger.sol"; StrategyHedger

// Markets
import {OtusOptionMarket} from "../markets/OtusOptionMarket.sol";
import {SpreadMarket} from "../markets/SpreadMarket.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title Strategy - Options
 * @author Otus
 * @dev Hedges delta of an vault options strategy
 */
contract Strategy is OwnableUpgradeable, ITradeTypes {
    using SafeDecimalMath for uint;
    using SignedDecimalMath for int;

    /************************************************
     *  STRUCTS
     ***********************************************/
    struct StrategyDetail {
        // minimum board expiry
        uint minTimeToExpiry;
        // maximum board expiry
        uint maxTimeToExpiry;
        // ideal option delta to trade
        int targetDelta;
        // max diff between targetDelta and option delta
        uint maxDeltaGap;
        // amount of options to sell per OtusVault.trade()
        uint size;
        // min seconds between OtusVault.trade() calls
        uint minTradeInterval;
        // partial collateral: 0.9 -> 90% * fullCollat
        uint collatPercent;
        // reserved for hedging
        uint hedgeReserve;
    }

    /************************************************
     *  IMMUTABLES
     ***********************************************/
    OtusOptionMarket public immutable otusOptionMarket;

    /************************************************
     *  CONSTANTS
     ***********************************************/
    /// @dev quote collateral used
    IERC20Decimals public quoteAsset;

    bytes32 public referralCode = bytes32("OTUS");

    OtusVault public otusVault;

    /************************************************
     *  STATE
     ***********************************************/

    StrategyDetail public strategyDetail;

    mapping(uint => uint) public lastTradeTimestamp;

    uint[] public activeStrikeIds;

    mapping(uint => uint) public strikeToPositionId;

    /************************************************
     *  ADMIN
     ***********************************************/

    modifier onlyVault() virtual {
        require(msg.sender == address(otusVault), "only Vault");
        _;
    }

    constructor(address _otusOptionMarket) {
        otusOptionMarket = OtusOptionMarket(_otusOptionMarket);
    }

    /**
     * @notice Initializer strategy
     * @param _vault vault that owns strategy
     */
    function initialize(address _vault, address _quoteAsset) external initializer {
        otusVault = OtusVault(_vault);
        quoteAsset = IERC20Decimals(_quoteAsset);

        __Ownable_init();
    }

    /************************************************
     *  STRATEGY SETTERS
     ***********************************************/

    /**
     * @notice Update the strategy for the new round
     * @param _strategyDetail vault strategy settings
     */
    function setStrategyDetail(StrategyDetail memory _strategyDetail) external onlyOwner {
        (, , , , , , , bool roundInProgress) = otusVault.vaultState();

        if (roundInProgress) {
            revert RoundInProgress();
        }

        strategyDetail = _strategyDetail;

        emit StrategyUpdated(msg.sender, _strategyDetail);
    }

    /******************************************************
     * VAULT ACTIONS
     *****************************************************/
    /**
     * @notice opens a position
     * @param tradeInfo the market to trade on and position
     * @param _shortTrades the trades to open short positions
     * @param _longTrades the trades to open long positions
     * @param _round vault round
     */
    function open(
        TradeInfo memory tradeInfo,
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades,
        uint _round
    ) external onlyVault returns (uint allCapitalUsed) {
        uint positionId;
        uint lyraPositionId;
        uint premium;
        uint capitalUsed;

        // @todo collateral to add

        (positionId, lyraPositionId) = OtusOptionMarket(otusOptionMarket).openPosition(
            tradeInfo,
            _shortTrades,
            _longTrades
        );

        /// @todo add support for spread markets

        /// @todo sum premium

        /// @todo sum capital used

        emit VaultStrategyTrade(msg.sender, premium, capitalUsed, positionId, lyraPositionId, _round);
    }

    /******************************************************
     * VAULT TRANSFERS
     *****************************************************/
    /**
     * @notice transfer from vault - round start
     * @param _amount quote amount to transfer
     */
    function _trasferFromVault(uint _amount) internal {
        if (!quoteAsset.transferFrom(address(otusVault), address(this), _amount)) {
            revert QuoteTransferFailed(address(otusVault), address(this), _amount);
        }
    }

    /**
     * @notice transfer to vault - round end
     * @param _quoteBal quote amount to transfer
     */
    function _trasferFundsToVault(uint _quoteBal) internal {
        if (_quoteBal > 0 && !quoteAsset.transfer(address(otusVault), _quoteBal)) {
            revert QuoteTransferFailed(address(this), address(otusVault), _quoteBal);
        }
        emit QuoteReturnedToLP(_quoteBal);
    }

    /************************************************
     *  EVENTS
     ***********************************************/

    event StrategyUpdated(address vault, StrategyDetail updatedStrategy);

    event VaultStrategyTrade(
        address indexed _vault,
        uint premium,
        uint capitalUsed,
        uint positionId,
        uint lyraPositionId,
        uint round
    );

    event QuoteReturnedToLP(uint amount);

    /************************************************
     *  ERRORS
     ***********************************************/
    /// @notice quote transfer failed from/to vault
    error QuoteTransferFailed(address from, address to, uint amount);

    /// @notice round in progress
    error RoundInProgress();
}
