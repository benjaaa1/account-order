//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

// Libraries
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../synthetix/SafeDecimalMath.sol";
import {Vault} from "../libraries/Vault.sol";

// Interfaces
import {IERC20Decimals} from "../interfaces/IERC20Decimals.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

// Inherited
import {BaseVault} from "./BaseVault.sol";

/*
 * Otus Vault
 * =================
 *
 * Manage manager's vault state (including user deposits and withdrawals)
 * and access to funds for trading based on active strategy (options).
 */

/**
 * @title OtusVault
 * @author Otus
 */
contract OtusVault is BaseVault {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /************************************************
     *  CONSTANTS
     ***********************************************/

    /// @dev quote collateral used
    IERC20Decimals public quoteAsset;

    /************************************************
     *  STATE
     ***********************************************/

    bytes32 public vaultName;

    uint128 public lastQueuedWithdrawAmount;

    // @dev current active strategy for vault
    address public strategy;

    /************************************************
     *  CONSTRUCTOR & INITIALIZATION
     ***********************************************/

    constructor() BaseVault() {}

    /**
     * @notice Initializes contract on clone
     * @dev Should only be called by owner and only once
     * @param _vaultName vault name
     * @param _tokenName vault token name
     * @param _tokenSymbol vault token symbol
     * @param _feeRecipient otus treasury address
     * @param _performanceFee performance fee for vault
     * @param _vaultParams vault parameters
     */
    function initialize(
        bytes32 _vaultName,
        string memory _tokenName,
        string memory _tokenSymbol,
        address _feeRecipient,
        uint _performanceFee,
        Vault.VaultParams memory _vaultParams
    ) external {
        quoteAsset = IERC20Decimals(_vaultParams.asset);
        vaultName = _vaultName;

        baseInitialize(_tokenName, _tokenSymbol, _feeRecipient, _performanceFee, _vaultParams);
    }

    /************************************************
     *  PUBLIC VAULT STRATEGY ACTIONS
     ***********************************************/

    /**
     * @notice  Closes the current round, enable user to deposit for the next round
     * @dev can be closed by anyone as long as round end time is < block timestamp
     */
    function closeRound() external {
        require(vaultState.roundInProgress, "round closed");

        uint104 lockAmount = vaultState.lockedAmount;
        vaultState.lastLockedAmount = lockAmount;
        vaultState.lockedAmountLeft = 0;
        vaultState.lockedAmount = 0;
        vaultState.nextRoundReadyTimestamp = block.timestamp + Vault.ROUND_DELAY;
        vaultState.roundInProgress = false;

        // won't be able to close if positions are not settled
        IStrategy(strategy).close();

        emit RoundClosed(vaultState.round, lockAmount);
    }

    /**
     * @notice Start the next/new round
     */
    function startNextRound() external onlyOwner {
        //can't start next round before outstanding expired positions are settled.
        require(!vaultState.roundInProgress, "round opened");
        require(block.timestamp > vaultState.nextRoundReadyTimestamp, "Delay between rounds not elapsed");

        (uint lockedBalance, uint queuedWithdrawAmount) = _rollToNextRound(uint(lastQueuedWithdrawAmount));

        vaultState.lockedAmount = uint104(lockedBalance);
        vaultState.lockedAmountLeft = lockedBalance;
        vaultState.roundInProgress = true;

        lastQueuedWithdrawAmount = uint128(queuedWithdrawAmount);

        // won't be able to close if positions are not settled
        quoteAsset.approve(strategy, type(uint).min);

        emit RoundStarted(vaultState.round, uint104(lockedBalance));
    }

    /************************************************
     *  Vault  Actions
     ***********************************************/
    /**
     * @notice Used for trade
     * @param tradeInfo the market to trade on and position
     * @param _shortTrades the trades to open short positions
     * @param _longTrades the trades to open long positions
     */
    function open(
        TradeInfo memory tradeInfo,
        TradeInputParameters[] memory _shortTrades,
        TradeInputParameters[] memory _longTrades
    ) external onlyOwner {
        require(vaultState.roundInProgress, "Round closed");

        uint round = vaultState.round;

        uint capitalUsed = IStrategy(strategy).open(tradeInfo, _shortTrades, _longTrades, round);

        vaultState.lockedAmountLeft = vaultState.lockedAmountLeft - capitalUsed;
    }

    /************************************************
     *  Strategy Update and Setters
     ***********************************************/

    /**
     * @notice Sets strategies for vault
     * @param _strategy strategy clone address
     */
    function setStrategy(address _strategy) external onlyOwner {
        require(!vaultState.roundInProgress, "round opened");

        if (address(strategy) != address(0)) {
            quoteAsset.approve(address(strategy), 0);
        }

        strategy = _strategy;
        quoteAsset.approve(_strategy, type(uint).max);
        emit StrategyUpdated(_strategy);
    }

    /************************************************
     *  EVENTS
     ***********************************************/

    event RoundStarted(uint16 roundId, uint104 lockAmount);

    event RoundClosed(uint16 roundId, uint104 lockAmount);

    event StrategyUpdated(address strategy);
}
