// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

import "hardhat/console.sol";

// libraries
import {IERC20Decimals} from "./interfaces/IERC20Decimals.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./synthetix/DecimalMath.sol";
import "./libraries/ConvertDecimals.sol";

// inherits

// spread option market
import {SpreadOptionMarket} from "./SpreadOptionMarket.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SimpleInitializable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializable.sol";

// spread option market
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title SpreadLiquidityPool
 * @author Otus
 * @dev Holds funds from LPs. Used for the following purposes:
 * 1. Collateralizing short options on Lyra.
 * 2. Lends funds to traders through spread option market and other token markets.
 */
contract SpreadLiquidityPool is Ownable, SimpleInitializable, ReentrancyGuard, ERC20 {
    using DecimalMath for uint;

    struct Liquidity {
        // Amount of liquidity available for option collateral and premiums
        uint freeLiquidity;
        // Amount of liquidity available for withdrawals - different to freeLiquidity
        uint burnableLiquidity;
        // Net asset value, including everything and netOptionValue
        uint NAV;
    }

    struct LiquidityPoolParameters {
        // Minimum amount accepted as deposit / min withdrawal
        uint minDepositWithdraw;
        // Time between initiating a withdrawal and when it can be processed
        uint withdrawalDelay;
        // Fee charged on withdrawn funds
        uint withdrawalFee;
        // Length of time a deposit/withdrawal since initiation for before a guardian can force process their transaction
        uint guardianDelay;
        /// liquidity pool max cap
        uint cap;
        /// liquidity collateral fee percentage based on 365 days
        uint fee;
        // The address of the "guardian"
        address guardianMultisig;
    }

    struct CircuitBreakerParameters {
        // Percentage of NAV below which the liquidity CB fires
        uint liquidityCBThreshold;
        // Length of time after the liq. CB stops firing during which deposits/withdrawals are still blocked
        uint liquidityCBTimeout;
    }

    struct QueuedWithdrawal {
        uint id;
        // Who will receive the quoteAsset returned after burning the LiquidityToken
        address beneficiary;
        // The amount of LiquidityPoolToken being burnt after the wait time
        uint amountTokens;
        // The amount of quote transferred. Will equal to 0 if process not started
        uint quoteSent;
        // block timestamp withdrawal requested
        uint withdrawInitiatedTime;
        // lp token price at time of withdrawal (includes fees)
        uint tokenPriceAtWithdrawal;
    }

    /************************************************
     *  INIT STATE
     ***********************************************/

    SpreadOptionMarket public spreadOptionMarket;

    // @dev Collateral
    IERC20Decimals public quoteAsset;

    /// @dev Parameters relating to depositing and withdrawing from the Otus Spread LP
    LiquidityPoolParameters public lpParams;

    /// @dev Parameters relating to circuit breakers
    CircuitBreakerParameters public cbParams;

    mapping(uint => QueuedWithdrawal) public queuedWithdrawals;
    uint public totalQueuedWithdrawals = 0;

    /// @dev The next queue item that needs to be processed
    uint public queuedWithdrawalHead = 1;
    uint public nextQueuedWithdrawalId = 1;

    /// @dev Amount of collateral locked for outstanding calls and puts sold for users
    uint public lockedLiquidity;

    // timestamp for when deposits/withdrawals will be available to deposit/withdraw
    // This checks if liquidity is all used - adds 3 days to block.timestamp if it is
    uint public CBTimestamp = 0;

    /************************************************
     *  MODIFIERS
     ***********************************************/

    modifier onlySpreadOptionMarket() {
        if (msg.sender != address(spreadOptionMarket)) {
            revert OnlySpreadOptionMarket(address(this), msg.sender, address(spreadOptionMarket));
        }
        _;
    }

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    constructor(string memory _name, string memory _symbol) Ownable() ERC20(_name, _symbol) {}

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize users account
     * @param _spreadOptionMarket SpreadOptionMarket
     */
    function initialize(address payable _spreadOptionMarket, address _quoteAsset) external onlyOwner initializer {
        spreadOptionMarket = SpreadOptionMarket(_spreadOptionMarket);
        quoteAsset = IERC20Decimals(_quoteAsset);
    }

    /************************************************
     * ADMIN - SETTINGS
     ***********************************************/
    /**
     * @notice set `LiquidityPoolParameteres`
     * @ param _lpParams liquidity parameters
     */
    function setLiquidityPoolParameters(LiquidityPoolParameters memory _lpParams) external onlyOwner {
        if (
            !(_lpParams.withdrawalDelay < 365 days &&
                _lpParams.withdrawalFee < 5e15 && // .5% max
                _lpParams.guardianDelay < 365 days &&
                _lpParams.fee < 5e17) // 50% max
        ) {
            revert InvalidLiquidityPoolParameters(address(this), _lpParams);
        }

        lpParams = _lpParams;

        emit LiquidityPoolParametersUpdated(lpParams);
    }

    function setCircuiteBreakerParemeters(CircuitBreakerParameters memory _cbParams) external onlyOwner {
        if (!(_cbParams.liquidityCBThreshold < DecimalMath.UNIT && _cbParams.liquidityCBTimeout < 60 days)) {
            revert InvalidCircuitBreakerParameters(address(this), _cbParams);
        }

        cbParams = _cbParams;

        emit CircuitBreakerParametersUpdated(cbParams);
    }

    /************************************************
     *  DEPOSIT AND WITHDRAW
     ***********************************************/

    /**
     * @notice LP will send USD for LiquidityPool Token (represents their share of entire pool)
     * @param _beneficiary Will receive LiquidityPool Token instantly
     * @param _amountQuote Amount of Quote Asset
     */
    function initiateDeposit(address _beneficiary, uint _amountQuote) external nonReentrant {
        // USDC
        uint realQuote = _amountQuote;

        // // Convert to 18 dp for LP token minting
        _amountQuote = ConvertDecimals.convertTo18(_amountQuote, quoteAsset.decimals());

        if (_beneficiary == address(0)) {
            revert InvalidBeneficiaryAddress(address(this), _beneficiary);
        }
        if (_amountQuote < lpParams.minDepositWithdraw) {
            revert MinimumDepositNotMet(address(this), _amountQuote, lpParams.minDepositWithdraw);
        }

        Liquidity memory liquidity = getLiquidity();
        uint tokenPrice = _getTokenPrice(liquidity.NAV, getTotalTokenSupply());

        uint amountTokens = _amountQuote.divideDecimal(tokenPrice);

        _mint(_beneficiary, amountTokens);
        emit DepositProcessed(msg.sender, _beneficiary, 0, _amountQuote, tokenPrice, amountTokens, block.timestamp);

        if (!quoteAsset.transferFrom(msg.sender, address(this), realQuote)) {
            revert QuoteTransferFailed(address(this), msg.sender, address(this), _amountQuote);
        }
    }

    /**
     * @notice LP instantly burns LiquidityToken, signalling they wish to withdraw
     *         their share of the pool in exchange for quote, to be processed instantly (if no live boards)
     *         or after the delay period passes (including CBs).
     *         This action is not reversible.
     *
     *
     * @param _beneficiary will receive
     * @param _amountLiquidityToken: is the amount of LiquidityToken the LP is withdrawing
     */
    function initiateWithdraw(address _beneficiary, uint _amountLiquidityToken) public nonReentrant {
        if (_beneficiary == address(0)) {
            revert InvalidBeneficiaryAddress(address(this), _beneficiary);
        }

        Liquidity memory liquidity = getLiquidity();
        uint tokenPrice = _getTokenPrice(liquidity.NAV, getTotalTokenSupply());
        console.log("_amountLiquidityToken");
        console.log(_amountLiquidityToken);
        uint withdrawalValue = _amountLiquidityToken.multiplyDecimal(tokenPrice);
        console.log("withdrawalValue");
        console.log(withdrawalValue);
        console.log("tokenPrice");
        console.log(tokenPrice);

        if (withdrawalValue < lpParams.minDepositWithdraw && _amountLiquidityToken < lpParams.minDepositWithdraw) {
            revert MinimumWithdrawNotMet(address(this), withdrawalValue, lpParams.minDepositWithdraw);
        }
        // if no spreadOptionMarket trades are using collateral
        // if enough free collateral to withdraw
        if (lockedLiquidity == 0) {
            withdrawalValue = ConvertDecimals.convertFrom18(withdrawalValue, quoteAsset.decimals());

            if (!quoteAsset.transfer(_beneficiary, withdrawalValue)) {
                revert QuoteTransferFailed(address(this), address(this), _beneficiary, withdrawalValue);
            }
            emit WithdrawProcessed(
                msg.sender,
                _beneficiary,
                0,
                _amountLiquidityToken,
                tokenPrice,
                withdrawalValue,
                totalQueuedWithdrawals,
                block.timestamp
            );
        } else {
            // queued withdrawals
            QueuedWithdrawal storage newWithdrawal = queuedWithdrawals[nextQueuedWithdrawalId];

            newWithdrawal.id = nextQueuedWithdrawalId++;
            newWithdrawal.beneficiary = _beneficiary;
            newWithdrawal.amountTokens = _amountLiquidityToken;
            newWithdrawal.withdrawInitiatedTime = block.timestamp;
            // only fees increase token price - queued withdrawal wont collect fees
            newWithdrawal.tokenPriceAtWithdrawal = tokenPrice;

            totalQueuedWithdrawals += _amountLiquidityToken;

            emit WithdrawQueued(
                msg.sender,
                _beneficiary,
                newWithdrawal.id,
                _amountLiquidityToken,
                totalQueuedWithdrawals,
                block.timestamp
            );
        }
        _burn(msg.sender, _amountLiquidityToken);
    }

    // can only process once boards are settled
    function processWithdrawalQueue(uint limit) external nonReentrant {
        for (uint i = 0; i < limit; i++) {
            QueuedWithdrawal storage current = queuedWithdrawals[queuedWithdrawalHead];

            (uint totalTokensBurnable, uint tokenPriceWithFee) = _getBurnableTokensAndAddFee(
                current.tokenPriceAtWithdrawal
            );

            if (!_canProcess(current.withdrawInitiatedTime, lpParams.withdrawalDelay, queuedWithdrawalHead)) {
                break;
            }

            if (totalTokensBurnable == 0) {
                break;
            }

            uint burnAmount = current.amountTokens;
            if (burnAmount > totalTokensBurnable) {
                burnAmount = totalTokensBurnable;
            }

            current.amountTokens -= burnAmount;
            totalQueuedWithdrawals -= burnAmount;

            uint quoteAmount = burnAmount.multiplyDecimal(tokenPriceWithFee);

            if (_tryTransferQuote(current.beneficiary, quoteAmount)) {
                // success
                current.quoteSent += quoteAmount;
            } else {
                // On unknown failure reason, return LP tokens and continue
                totalQueuedWithdrawals -= current.amountTokens;
                uint returnAmount = current.amountTokens + burnAmount;
                _mint(current.beneficiary, returnAmount);
                current.amountTokens = 0;
                emit WithdrawReverted(
                    msg.sender,
                    current.beneficiary,
                    queuedWithdrawalHead,
                    tokenPriceWithFee,
                    totalQueuedWithdrawals,
                    block.timestamp,
                    returnAmount
                );
                queuedWithdrawalHead++;
                continue;
            }

            if (current.amountTokens > 0) {
                emit WithdrawPartiallyProcessed(
                    msg.sender,
                    current.beneficiary,
                    queuedWithdrawalHead,
                    burnAmount,
                    tokenPriceWithFee,
                    quoteAmount,
                    totalQueuedWithdrawals,
                    block.timestamp
                );
                break;
            }
            emit WithdrawProcessed(
                msg.sender,
                current.beneficiary,
                queuedWithdrawalHead,
                burnAmount,
                tokenPriceWithFee,
                quoteAmount,
                totalQueuedWithdrawals,
                block.timestamp
            );
            queuedWithdrawalHead++;
        }
    }

    function _tryTransferQuote(address to, uint amount) internal returns (bool success) {
        amount = ConvertDecimals.convertFrom18(amount, quoteAsset.decimals());
        if (amount > 0) {
            try quoteAsset.transfer(to, amount) returns (bool res) {
                return res;
            } catch {
                return false;
            }
        }
        return true;
    }

    /// @dev Checks if deposit/withdrawal ticket can be processed
    function _canProcess(uint initiatedTime, uint minimumDelay, uint entryId) internal returns (bool) {
        bool validEntry = initiatedTime != 0;
        // bypass circuit breaker and stale checks if the guardian is calling and their delay has passed
        bool guardianBypass = msg.sender == lpParams.guardianMultisig &&
            initiatedTime + lpParams.guardianDelay < block.timestamp;
        // if minimum delay or circuit breaker timeout hasn't passed, we can't process
        bool delaysExpired = initiatedTime + minimumDelay < block.timestamp && CBTimestamp < block.timestamp;

        emit CheckingCanProcess(entryId, validEntry, guardianBypass, delaysExpired);

        return validEntry && (delaysExpired || guardianBypass);
    }

    function _getBurnableTokensAndAddFee(
        uint _tokenPriceAtWithdrawal
    ) internal returns (uint burnableTokens, uint tokenPriceWithFee) {
        Liquidity memory liquidity = _getLiquidityAndUpdateCB();
        uint burnableLiquidity = liquidity.burnableLiquidity;

        tokenPriceWithFee = (lockedLiquidity != 0)
            ? _tokenPriceAtWithdrawal.multiplyDecimal(DecimalMath.UNIT - lpParams.withdrawalFee)
            : _tokenPriceAtWithdrawal;

        return (burnableLiquidity.divideDecimal(tokenPriceWithFee), tokenPriceWithFee);
    }

    function _getTokenPriceAndBurnableLiquidity() internal returns (uint tokenPrice, uint burnableLiquidity) {
        Liquidity memory liquidity = _getLiquidityAndUpdateCB();
        uint totalTokenSupply = getTotalTokenSupply();

        tokenPrice = _getTokenPrice(liquidity.NAV, totalTokenSupply);

        return (tokenPrice, liquidity.burnableLiquidity);
    }

    /************************************************
     *  ONLY SPREAD OPTION MARKET TRADER
     ***********************************************/

    // @dev only spread market can "borrow" collateral
    function transferShortCollateral(uint _amount) public onlySpreadOptionMarket {
        // check free liquidity
        // @dev add to locked collateral

        _lockLiquidity(_amount);
        // check active deposits
        // add to traded

        _amount = ConvertDecimals.convertFrom18(_amount, quoteAsset.decimals());

        if (_amount > 0) {
            if (!quoteAsset.transfer(address(spreadOptionMarket), _amount)) {
                revert CollateralTransferToMarketFail(_amount);
            }
        }

        emit ShortCollateralSent(_amount, quoteAsset.balanceOf(address(this)));
    }

    // @dev lock liquidity
    // @dev should locked liquidity be kept in 18 decimal precision ? it makes sense to
    function _lockLiquidity(uint _amount) internal {
        Liquidity memory liquidity = getLiquidity();

        if (_amount > liquidity.freeLiquidity) {
            revert LockingMoreQuoteThanIsFree(address(this), _amount, liquidity.freeLiquidity, lockedLiquidity);
        }

        console.log("lockedLiquidity");
        console.log(lockedLiquidity);
        console.log(_amount);

        lockedLiquidity = lockedLiquidity + _amount;

        console.log(lockedLiquidity);
    }

    // @dev free previously locked liquidity
    // @dev only spread option market
    // @dev should only be freed when collateral is returned
    function freeLockedLiquidity(uint _amount) public onlySpreadOptionMarket {
        Liquidity memory liquidity = getLiquidity(); // calculates total pool value
        console.log("freeLockedLiquidity _amount");
        console.log(_amount);
        lockedLiquidity = lockedLiquidity - _amount;

        emit ShortCollateralFreed(_amount, liquidity);
    }

    /************************************************
     *  CIRCUIT BREAKERS
     ***********************************************/
    /// @notice Checks the liquidity circuit breakers and triggers if necessary
    function updateCBs() external nonReentrant {
        _getLiquidityAndUpdateCB();
    }

    function _getLiquidityAndUpdateCB() internal returns (Liquidity memory liquidity) {
        liquidity = getLiquidity();
        _updateCBs(liquidity);
    }

    function _updateCBs(Liquidity memory liquidity) internal {
        if (lockedLiquidity == 0) {
            return;
        }

        uint timeToAdd = 0;

        uint freeLiquidityPercent = liquidity.freeLiquidity.divideDecimal(liquidity.NAV);

        bool liquidityThresholdCrossed = freeLiquidityPercent < cbParams.liquidityCBThreshold;

        if (liquidityThresholdCrossed && cbParams.liquidityCBTimeout > timeToAdd) {
            timeToAdd = cbParams.liquidityCBTimeout;
        }

        if (timeToAdd > 0 && CBTimestamp < block.timestamp + timeToAdd) {
            CBTimestamp = block.timestamp + timeToAdd;
            emit CircuitBreakerUpdated(CBTimestamp, liquidityThresholdCrossed);
        }
    }

    /************************************************
     *  GET POOL LIQUIDITY
     ***********************************************/

    function getLiquidity() public view returns (Liquidity memory) {
        uint totalPoolValue = _getTotalPoolValueQuote();

        uint tokenPrice = _getTokenPrice(totalPoolValue, getTotalTokenSupply());

        Liquidity memory liquidity = _getLiquidity(totalPoolValue, tokenPrice.multiplyDecimal(totalQueuedWithdrawals));

        return liquidity;
    }

    function _getLiquidity(uint totalPoolValue, uint reservedTokenValue) internal view returns (Liquidity memory) {
        Liquidity memory liquidity = Liquidity(0, 0, 0);

        uint availableQuote = ConvertDecimals.convertTo18(quoteAsset.balanceOf(address(this)), quoteAsset.decimals());

        liquidity.freeLiquidity = availableQuote > reservedTokenValue ? availableQuote - reservedTokenValue : 0;
        liquidity.burnableLiquidity = availableQuote;
        liquidity.NAV = totalPoolValue;

        return liquidity;
    }

    /************************************************
     *  POOL TOKEN VALUE
     ***********************************************/

    /// @dev Get current pool token price without market condition check
    function getTokenPrice() public view returns (uint) {
        Liquidity memory liquidity = getLiquidity();

        return _getTokenPrice(liquidity.NAV, getTotalTokenSupply());
    }

    function _getTokenPrice(uint totalPoolValue, uint totalTokenSupply) internal pure returns (uint) {
        if (totalTokenSupply == 0) {
            return 1e18;
        }

        return totalPoolValue.divideDecimal(totalTokenSupply);
    }

    function _getTotalPoolValueQuote() internal view returns (uint) {
        // int totalAssetValue = SafeCast.toInt256(quoteAsset.balanceOf(address(this)) + lockedLiquidity);

        uint totalAssetValue = ConvertDecimals.convertTo18(quoteAsset.balanceOf(address(this)), quoteAsset.decimals()) +
            lockedLiquidity;
        return totalAssetValue;
    }

    /// @dev Get total number of oustanding LiquidityPool Token
    function getTotalTokenSupply() public view returns (uint) {
        return totalSupply() + totalQueuedWithdrawals;
    }

    /************************************************
     * CALCULATE FEES
     ***********************************************/

    /**
     *
     * @notice collateral will be locked until the latest buy expiry
     */
    function calculateCollateralFee(uint _amount, uint _maxExpiry) public view returns (uint fee) {
        uint durationOfYearPct = (_maxExpiry - block.timestamp).divideDecimal(365 days);

        uint durationFee = lpParams.fee.multiplyDecimal(durationOfYearPct);

        fee = _amount.multiplyDecimal(durationFee);
        console.log("fee");
        console.log(fee);
    }

    /************************************************
     *  MISC
     ***********************************************/
    /**
     * @dev For Trading Rewards
     */
    function distributeLyra() external {}

    /************************************************
     *  ERRORS
     ***********************************************/
    error InvalidBeneficiaryAddress(address thrower, address beneficiary);

    error OnlySpreadOptionMarket(address thrower, address caller, address optionMarket);

    error InvalidLiquidityPoolParameters(address thrower, LiquidityPoolParameters lpParams);

    error QuoteTransferFailed(address thrower, address from, address to, uint amount);

    error MinimumDepositNotMet(address thrower, uint amountQuote, uint minDeposit);

    error MinimumWithdrawNotMet(address thrower, uint amountQuote, uint minWithdraw);

    error CollateralTransferToMarketFail(uint amount);

    error LockingMoreQuoteThanIsFree(address thrower, uint quoteToLock, uint freeLiquidity, uint lockedLiquidity);

    error InvalidCircuitBreakerParameters(address thrower, CircuitBreakerParameters cbParams);

    /************************************************
     *  EVENTS
     ***********************************************/
    /// @dev Emitted whenever the CB timestamp is updated
    event CircuitBreakerUpdated(uint newTimestamp, bool liquidityThresholdCrossed);

    /// @dev Emitted whenever the circuit breaker parameters are updated
    event CircuitBreakerParametersUpdated(CircuitBreakerParameters cbParams);

    event WithdrawPartiallyProcessed(
        address indexed caller,
        address indexed beneficiary,
        uint indexed withdrawalQueueId,
        uint amountWithdrawn,
        uint tokenPrice,
        uint quoteReceived,
        uint totalQueuedWithdrawals,
        uint timestamp
    );
    event LiquidityPoolParametersUpdated(LiquidityPoolParameters lpParams);

    event WithdrawReverted(
        address indexed caller,
        address indexed beneficiary,
        uint indexed withdrawalQueueId,
        uint tokenPrice,
        uint totalQueuedWithdrawals,
        uint timestamp,
        uint tokensReturned
    );
    event WithdrawQueued(
        address indexed withdrawer,
        address indexed beneficiary,
        uint indexed withdrawalQueueId,
        uint amountWithdrawn,
        uint totalQueuedWithdrawals,
        uint timestamp
    );

    ///  QueueId of 0 indicates it was not queued.
    event DepositProcessed(
        address indexed caller,
        address indexed beneficiary,
        uint indexed depositQueueId,
        uint amountDeposited,
        uint tokenPrice,
        uint tokensReceived,
        uint timestamp
    );

    event WithdrawProcessed(
        address indexed caller,
        address indexed beneficiary,
        uint indexed withdrawalQueueId,
        uint amountWithdrawn,
        uint tokenPrice,
        uint quoteReceived,
        uint totalQueuedWithdrawals,
        uint timestamp
    );

    event CollateralReturnFailed(address thrower, uint amount);

    event ShortCollateralSent(uint amount, uint freeBalance);

    event ShortCollateralFreed(uint amount, Liquidity liquidity);

    /// @dev Emitted whenever a queue item is checked for the ability to be processed
    event CheckingCanProcess(uint entryId, bool validEntry, bool guardianBypass, bool delaysExpired);
}
