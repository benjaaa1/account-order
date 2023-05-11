// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SimpleInitializeable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializeable.sol";

// interfaces
import "./interfaces/ILyraBase.sol";

/**
 * @title OtusManager
 * @author Otus
 * @dev Handles settings for otus contracts
 */
contract OtusManager is Ownable, SimpleInitializeable {
    /************************************************
     *  CONSTANTS - SETTINGS
     ***********************************************/
    uint public constant MAX_SPREAD_COLLATERAL_FEE = 1e17; // 10%

    uint public constant MAX_STKD_OTUS_PLATFORM_SHARE = 3e17; // 35%

    uint public constant MAX_VAULT_PLATFORM_FEE = 1e17; // 10%

    uint public constant MIN_COLLATERAL_REQUIREMENT = 5e17; // 50%

    /************************************************
     *  STATE - SETTINGS
     ***********************************************/

    address public treasury; // treasury address

    /// @dev max trades per tx for spread market
    uint public maxTrades = 4; // 4 trades

    /// @dev used to calculate the liquidity pool collateral borrow fee
    uint public spreadCollateralFee = 1e16; // 1%

    /// @dev otus platform fee share
    uint public stkdOtusPlatformShare = 0; // 0%

    /// @dev used for build your own vaults
    uint public vaultPlatformFee = 0; // 0%

    /// @dev may be used for vaults
    uint public minStkdOtus = 0; // 0 OTUS

    /// @dev used for build your own vaults
    uint public maxManagerFee = 1e17; // 10%

    /// @dev used for build your own vaults
    uint public maxPerformanceFee = 1e17; // 10%

    /// @dev collateralRequirement used for vaults and spread market
    uint public collateralRequirement = 1e18; // 100%

    /// @dev collateralBuffer used for vaults and spread market
    uint public collateralBuffer = 0; // 0%

    /// @dev lyra base helper methods
    mapping(bytes32 => ILyraBase) public lyraBases;

    /// @dev stores otus contract addresses by name
    mapping(bytes32 => address) internal addresses;

    ///
    mapping(bytes32 => mapping(bytes32 => address)) internal addressStorage;

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/
    constructor() Ownable() {}

    function initialize(address _ethLyraBase, address _btcLyraBase) external onlyOwner initializer {
        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);
        treasury = msg.sender;
    }

    /************************************************
     *  TRADE SETTINGS
     ***********************************************/

    /**
     * @notice sets treasury address
     * @param _treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /**
     * @notice controls max trades allowed
     * @param _maxTrades max trades per tx for spread market and multi leg market
     */
    function setMaxTrades(uint _maxTrades) external onlyOwner {
        maxTrades = _maxTrades;
    }

    /************************************************
     *  FEE SETTINGS
     ***********************************************/

    /**
     * @notice Sets spread collateral fee
     * @param _spreadCollateralFee fee for spread collateral
     */
    function setSpreadCollateralFee(uint _spreadCollateralFee) external onlyOwner {
        if (_spreadCollateralFee > MAX_SPREAD_COLLATERAL_FEE) {
            revert("OtusSettings: fee too high");
        }
        spreadCollateralFee = _spreadCollateralFee;
        emit SpreadCollateralFeeUpdated(spreadCollateralFee);
    }

    /**
     * @notice Sets otus stakers platform share
     * @param _stkdOtusShare otus stakers platform share
     */
    function setStkdOtusPlatformShare(uint _stkdOtusShare) external onlyOwner {
        if (_stkdOtusShare > MAX_STKD_OTUS_PLATFORM_SHARE) {
            revert("OtusSettings: share too high");
        }
        stkdOtusPlatformShare = _stkdOtusShare;
        emit StkdOtusPlatformShareUpdated(stkdOtusPlatformShare);
    }

    /**
     * @notice Sets vault platform fee
     * @param _vaultPlatformFee platform fees for user created vaults
     */
    function setVaultPlatformFee(uint _vaultPlatformFee) external onlyOwner {
        if (_vaultPlatformFee > MAX_VAULT_PLATFORM_FEE) {
            revert("OtusSettings: fee too high");
        }
        vaultPlatformFee = _vaultPlatformFee;
        emit VaultPlatformFeeUpdated(vaultPlatformFee);
    }

    /**
     * @notice Used for user created structured vaults
     * @param _maxManagerFee max manager fee
     */
    function setMaxManagerFee(uint _maxManagerFee) external onlyOwner {
        maxManagerFee = _maxManagerFee;
        emit MaxManagerFeeUpdated(maxManagerFee);
    }

    /**
     * @notice Used for user created structured vaults
     * @param _maxPerformanceFee max performance fee
     */
    function setMaxPerformanceFee(uint _maxPerformanceFee) external onlyOwner {
        maxPerformanceFee = _maxPerformanceFee;
        emit MaxPerformanceFeeUpdated(maxPerformanceFee);
    }

    /************************************************
     *  PLATFORM
     ***********************************************/

    /**
     * @notice Sets min collateral for spread collateral market
     * @param _collateralRequirement min collateral requirement
     */
    function setMinCollateral(uint _collateralRequirement) external onlyOwner {
        if (_collateralRequirement < MIN_COLLATERAL_REQUIREMENT) {
            revert("OtusSettings: requirement too low");
        }
        collateralRequirement = _collateralRequirement;
    }

    /**
     * @notice Add market
     * @param _market market to add
     * @param _lyraBase lyra base for market
     */
    function addMarket(bytes32 _market, address _lyraBase) external onlyOwner {
        lyraBases[_market] = ILyraBase(_lyraBase);
        emit LyraMarketUpdated(_market, _lyraBase);
    }

    /************************************************
     *  RESOLVERS
     ***********************************************/

    /************************************************
     *  EVENTS
     ***********************************************/
    event SpreadCollateralFeeUpdated(uint spreadCollateralFee);

    event StkdOtusPlatformShareUpdated(uint stkdOtusPlatformShare);

    event VaultPlatformFeeUpdated(uint vaultPlatformFee);

    event MaxManagerFeeUpdated(uint maxManagerFee);

    event MaxPerformanceFeeUpdated(uint maxPerformanceFee);

    event LyraMarketUpdated(bytes32 _market, address _lyraBase);
}
