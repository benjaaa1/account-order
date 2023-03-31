// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "hardhat/console.sol";

// libraries
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./synthetix/DecimalMath.sol";

// inherits

// spread option market
import {SpreadOptionMarket} from "./SpreadOptionMarket.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// spread option market
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title SpreadLiquidityPool
 * @author Otus
 * @dev Holds funds from LPs. Used for the following purposes:
 * 1. Collateralizing short options on Lyra.
 * 2. Lends funds to traders through spread option market.
 */
contract SpreadLiquidityPool is Ownable, ReentrancyGuard, ERC20 {
    using DecimalMath for uint;

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
    }

    /************************************************
     *  INIT STATE
     ***********************************************/

    SpreadOptionMarket public spreadOptionMarket;

    ERC20 public quoteAsset;

    /// @dev Parameters relating to depositing and withdrawing from the Otus Spread LP
    LiquidityPoolParameters public lpParams;

    mapping(uint => QueuedWithdrawal) public queuedWithdrawals;
    uint public totalQueuedWithdrawals = 0;

    /// @dev The next queue item that needs to be processed
    uint public queuedWithdrawalHead = 1;
    uint public nextQueuedWithdrawalId = 1;

    /// @dev Amount of collateral locked for outstanding calls and puts sold for users
    uint public lockedLiquidity;

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
    function initialize(
        address payable _spreadOptionMarket,
        address _quoteAsset
    ) external onlyOwner {
        spreadOptionMarket = SpreadOptionMarket(_spreadOptionMarket);
        quoteAsset = ERC20(_quoteAsset);
    }

    /************************************************
     * ADMIN - SETTINGS
     ***********************************************/
    // MINIMUM DEPOSIT
    // LOCK PERIOD
    // QUEUE PERIOD - WITHDRAW
    // QUEUE PERIOD - DEPOSIT

    /**
     * @notice set `LiquidityPoolParameteres`
     * @ param _lpParams liquidity parameters
     */
    function setLiquidityPoolParameters(
        LiquidityPoolParameters memory _lpParams
    ) external onlyOwner {
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

    /************************************************
     *  DEPOSIT AND WITHDRAW
     ***********************************************/

    /**
     * @notice LP will send USD for LiquidityPool Token (represents their share of entire pool)
     * @param _beneficiary Will receive LiquidityPool Token instantly
     * @param _amountQuote Amount of Quote Asset
     */
    function initiateDeposit(address _beneficiary, uint _amountQuote) external nonReentrant {
        if (_beneficiary == address(0)) {
            revert InvalidBeneficiaryAddress(address(this), _beneficiary);
        }
        if (_amountQuote < lpParams.minDepositWithdraw) {
            revert MinimumDepositNotMet(address(this), _amountQuote, lpParams.minDepositWithdraw);
        }

        uint tokenPrice = getTokenPrice();
        uint amountTokens = _amountQuote.divideDecimal(tokenPrice);
        _mint(_beneficiary, amountTokens);
        emit DepositProcessed(
            msg.sender,
            _beneficiary,
            0,
            _amountQuote,
            tokenPrice,
            amountTokens,
            block.timestamp
        );

        if (!quoteAsset.transferFrom(msg.sender, address(this), _amountQuote)) {
            revert QuoteTransferFailed(address(this), msg.sender, address(this), _amountQuote);
        }
    }

    function initiateWithdraw(
        address _beneficiary,
        uint _amountLiquidityToken
    ) public nonReentrant {
        if (_beneficiary == address(0)) {
            revert InvalidBeneficiaryAddress(address(this), _beneficiary);
        }
        if (_amountLiquidityToken < lpParams.minDepositWithdraw) {
            revert MinimumWithdrawNotMet(
                address(this),
                _amountLiquidityToken,
                lpParams.minDepositWithdraw
            );
        }
        // if no spreadOptionMarket trades are using collateral
        // if enough free collateral to withdrwa
        if (lockedLiquidity == 0) {
            uint tokenPrice = getTokenPrice();
            uint quoteReceived = _amountLiquidityToken.multiplyDecimal(tokenPrice);

            if (!quoteAsset.transfer(_beneficiary, quoteReceived)) {
                revert QuoteTransferFailed(
                    address(this),
                    address(this),
                    _beneficiary,
                    quoteReceived
                );
            }
            emit WithdrawProcessed(
                msg.sender,
                _beneficiary,
                0,
                _amountLiquidityToken,
                tokenPrice,
                quoteReceived,
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
            (uint totalTokensBurnable, uint tokenPriceWithFee) = _getBurnableTokensAndAddFee();

            QueuedWithdrawal storage current = queuedWithdrawals[queuedWithdrawalHead];

            if (
                !_canProcess(
                    current.withdrawInitiatedTime,
                    lpParams.withdrawalDelay,
                    queuedWithdrawalHead
                )
            ) {
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
    function _canProcess(
        uint initiatedTime,
        uint minimumDelay,
        uint entryId
    ) internal view returns (bool) {
        bool validEntry = initiatedTime != 0;
        // bypass circuit breaker and stale checks if the guardian is calling and their delay has passed
        bool guardianBypass = msg.sender == lpParams.guardianMultisig &&
            initiatedTime + lpParams.guardianDelay < block.timestamp;
        // if minimum delay or circuit breaker timeout hasn't passed, we can't process
        //        bool delaysExpired = initiatedTime + minimumDelay < block.timestamp && CBTimestamp < block.timestamp;

        bool delaysExpired = initiatedTime + minimumDelay < block.timestamp;

        // emit CheckingCanProcess(entryId, !isStale, validEntry, guardianBypass, delaysExpired);

        return validEntry && (delaysExpired || guardianBypass);
    }

    function _getBurnableTokensAndAddFee()
        internal
        view
        returns (uint burnableTokens, uint tokenPriceWithFee)
    {
        (uint tokenPrice, uint burnableLiquidity) = _getTokenPriceAndBurnableLiquidity();

        tokenPriceWithFee = (lockedLiquidity != 0)
            ? tokenPrice.multiplyDecimal(DecimalMath.UNIT - lpParams.withdrawalFee)
            : tokenPrice;
        return (burnableLiquidity.divideDecimal(tokenPriceWithFee), tokenPriceWithFee);
    }

    function _getTokenPriceAndBurnableLiquidity()
        internal
        view
        returns (uint tokenPrice, uint burnableLiquidity)
    {
        uint _freeLiquidity = freeLiquidity();
        tokenPrice = getTokenPrice();

        return (tokenPrice, _freeLiquidity);
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
        if (_amount > 0) {
            if (!quoteAsset.transfer(address(spreadOptionMarket), _amount)) {
                revert CollateralTransferToMarketFail(_amount);
            }
        }

        emit ShortCollateralSent(_amount, quoteAsset.balanceOf(address(this)));
    }

    // @dev lock liquidity
    function _lockLiquidity(uint _amount) internal {
        uint _freeLiquidity = freeLiquidity();

        if (_amount > _freeLiquidity) {
            revert LockingMoreQuoteThanIsFree(
                address(this),
                _amount,
                _freeLiquidity,
                lockedLiquidity
            );
        }

        lockedLiquidity = lockedLiquidity + _amount;
    }

    // @dev free previously locked liquidity
    // @dev only spread option market
    function freeLockedLiquidity(uint _amount) public onlySpreadOptionMarket {
        lockedLiquidity = lockedLiquidity - _amount;
        // emit ShortCollateralFreed(_amount)
    }

    /************************************************
     *  GET POOL LIQUIDITY
     ***********************************************/

    function freeLiquidity() public view returns (uint liquidity) {
        // free liquidity excludes queued withdrawals
        liquidity = quoteAsset.balanceOf(address(this));
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
    }

    /************************************************
     *  POOL TOKEN VALUE
     ***********************************************/

    /// @dev Get current pool token price without market condition check
    function getTokenPrice() public view returns (uint) {
        return _getTokenPrice(getTotalPoolValueQuote(), getTotalTokenSupply());
    }

    function _getTokenPrice(
        uint totalPoolValue,
        uint totalTokenSupply
    ) internal pure returns (uint) {
        if (totalTokenSupply == 0) {
            return 1e18;
        }

        return totalPoolValue.divideDecimal(totalTokenSupply);
    }

    function getTotalPoolValueQuote() internal view returns (uint) {
        int totalAssetValue = SafeCast.toInt256(
            quoteAsset.balanceOf(address(this)) + lockedLiquidity
        );

        return uint(totalAssetValue);
    }

    /// @dev Get total number of oustanding LiquidityPool Token
    function getTotalTokenSupply() public view returns (uint) {
        return totalSupply() + totalQueuedWithdrawals;
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

    error LockingMoreQuoteThanIsFree(
        address thrower,
        uint quoteToLock,
        uint freeLiquidity,
        uint lockedLiquidity
    );
    /************************************************
     *  EVENTS
     ***********************************************/
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
}
