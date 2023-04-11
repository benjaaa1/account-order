// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

// spread market contracts
import {SpreadOptionMarket} from "./SpreadOptionMarket.sol";
import {SpreadLiquidityPool} from "./SpreadLiquidityPool.sol";

// libraries
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./synthetix/SafeDecimalMath.sol";
import "./synthetix/SignedDecimalMath.sol";

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SimpleInitializable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializable.sol";

/**
 * @title SpreadMaxLossCollateral
 * @author Otus
 * @dev Holds quote asset max loss funds posted by trader
 */
contract SpreadMaxLossCollateral is Ownable, SimpleInitializable, ReentrancyGuard {
    using SafeDecimalMath for uint;
    using SignedDecimalMath for int;

    /************************************************
     *  INIT STATE
     ***********************************************/

    IERC20 public quoteAsset;

    SpreadOptionMarket internal spreadOptionMarket;
    SpreadLiquidityPool internal spreadLiquidityPool;

    /************************************************
     *  MODIFIERS
     ***********************************************/

    modifier onlySpreadOptionMarket() {
        if (msg.sender != address(spreadOptionMarket)) {
            revert OnlySpreadOptionMarket(msg.sender, address(spreadOptionMarket));
        }
        _;
    }

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    constructor() Ownable() {}

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize users account
     * @param _quoteAsset address used as margin asset (USDC / SUSD)
     * @param _spreadOptionMarket option market
     * @param _spreadLiquidityPool liquidity pool
     */
    function initialize(
        address _quoteAsset,
        address payable _spreadOptionMarket,
        address _spreadLiquidityPool
    ) external onlyOwner initializer {
        quoteAsset = IERC20(_quoteAsset);
        spreadOptionMarket = SpreadOptionMarket(_spreadOptionMarket);
        spreadLiquidityPool = SpreadLiquidityPool(_spreadLiquidityPool);
    }

    /************************************************
     *  TRANSFER
     ***********************************************/

    // @notice only spread option market
    // @dev routes max loss posted to liquidity pool
    function sendQuoteToLiquidityPool(uint _amount) public onlySpreadOptionMarket {
        _transferQuote(address(spreadLiquidityPool), _amount);
    }

    // @notice only spread option market
    // @dev routes max loss posted back to trader
    function sendQuoteToTrader(address _recipient, uint _amount) public onlySpreadOptionMarket {
        _transferQuote(_recipient, _amount);
    }

    // @dev transfer quote
    function _transferQuote(address _recipient, uint _amount) internal {
        // either sends to user
        // or sends to spreadliquidity pool
        if (_amount == 0) {
            return;
        }
        uint currentBalance = quoteAsset.balanceOf(address(this));
        if (_amount > currentBalance) {
            revert OutOfQuoteCollateralForTransfer(address(this), currentBalance, _amount);
        }
        if (!quoteAsset.transfer(_recipient, _amount)) {
            revert QuoteTransferFailed(address(this), _recipient, _amount);
        }

        emit QuoteSent(_recipient, _amount);
    }

    /// @dev sends quote collateral covering max losses
    /// @dev remove this
    function _sendMaxLossQuoteCollateral(address _recipient, uint _amount) external onlySpreadOptionMarket {
        // either sends to user
        // or sends to spreadliquidity pool
        if (_amount == 0) {
            return;
        }
        uint currentBalance = quoteAsset.balanceOf(address(this));
        if (_amount > currentBalance) {
            revert OutOfQuoteCollateralForTransfer(address(this), currentBalance, _amount);
        }
        if (!quoteAsset.transfer(_recipient, _amount)) {
            revert QuoteTransferFailed(address(this), _recipient, _amount);
        }

        emit QuoteSent(_recipient, _amount);
    }

    /************************************************
     *  EVENTS
     ***********************************************/
    /// @notice Quote sent to recipient
    /// @param _recipient address of recipient
    /// @param _amount amount in quoteasset
    event QuoteSent(address indexed _recipient, uint _amount);

    /************************************************
     *  ERRORS
     ***********************************************/

    /// @notice only spread market
    /// @param caller address
    /// @param optionMarket address
    error OnlySpreadOptionMarket(address caller, address optionMarket);

    /// @notice out of funds
    /// @param thrower address
    /// @param balance of quote asset
    /// @param amount requested quote asset
    error OutOfQuoteCollateralForTransfer(address thrower, uint balance, uint amount);

    /// @notice quote transfer failed
    /// @param thrower address
    /// @param recipient address
    /// @param amount requested quote asset
    error QuoteTransferFailed(address thrower, address recipient, uint amount);
}
