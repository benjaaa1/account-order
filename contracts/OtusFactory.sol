// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

// libraries
import {Vault} from "./libraries/Vault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OtusManager} from "./OtusManager.sol";
import {OtusVault} from "./vault/OtusVault.sol";
import {Strategy} from "./vault/Strategy.sol";

import "./utils/MinimalProxyFactory.sol";

/**
 * @title OtusFactory
 * @author Otus
 * @dev - Handles cloning the different vault and strategy contracts available
 */
contract OtusFactory is Ownable, MinimalProxyFactory {
    /************************************************
     *  INIT STATE
     ***********************************************/

    /// @dev Stores the Otus vault contract implementation address
    address public vaultImplementation;

    /// @dev Stores the Strategy contract implementation address
    address public strategyImplementation;

    /// @dev  address of manager
    OtusManager public otusManager;

    /************************************************
     * STATE
     ***********************************************/

    /// @dev mapping of vault to owner
    mapping(address => address) public vaults;

    /// @notice mapping of owner to vaults owned by owner
    mapping(address => address[]) internal ownerVaults;

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    /**
     * @notice Initializes the contract with immutable variables
     * @param _otusVault implementation vault contract address
     * @param _otusManager manager contract address
     */
    constructor(address _otusVault, address _strategy, address _otusManager) Ownable() {
        vaultImplementation = _otusVault;
        strategyImplementation = _strategy;
        otusManager = OtusManager(_otusManager);
    }

    /**
     * @notice Creates new vault
     * @return vaultAddress proxy vault contract address
     */
    function newVault(
        bytes32 _vaultName,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams
    ) public returns (address payable vaultAddress, address strategyAddress) {
        /// @dev only allow otus manager to create vault
        address vaultManager = otusManager.owner();
        require(msg.sender == vaultManager, "Not allowed to create");

        address feeRecipient = otusManager.treasury(); // fee recipient
        uint performanceFee = otusManager.maxPerformanceFee(); // max performance fee

        vaultAddress = payable(_cloneAsMinimalProxy(address(vaultImplementation), "Vault Creation failure"));
        strategyAddress = _cloneAsMinimalProxy(address(strategyImplementation), "Strategy Creation failure");

        OtusVault vault = OtusVault(vaultAddress);
        vault.initialize(
            strategyAddress,
            msg.sender,
            _vaultName,
            _tokenName,
            _tokenSymbol,
            feeRecipient,
            performanceFee,
            _vaultParams
        );

        /// @dev create initial strategy for vault
        Strategy strategy = Strategy(strategyAddress);
        strategy.initialize(vaultAddress, _vaultParams.asset);

        /// @dev add vault to mapping
        vaults[vaultAddress] = msg.sender;

        // add account to ownerAccounts mapping
        ownerVaults[msg.sender].push(vaultAddress);

        emit NewVault(msg.sender, vaultAddress);
    }

    /************************************************
     *  UPGRADEABILITY
     ***********************************************/

    /**
     * @notice Upgrade vault implemntation
     * @param _implementation new vault contract address
     */
    function upgradeVaultImplementation(address _implementation) external onlyOwner {
        vaultImplementation = _implementation;
        emit VaultImplementationUpgraded({implementation: _implementation});
    }

    /**
     * @notice Upgrade vault implemntation
     * @param _strategyImplementation new strategy contract address
     */
    function upgradeStrategyImplementation(address _strategyImplementation) external onlyOwner {
        strategyImplementation = _strategyImplementation;
        emit StrategyImplementationUpgraded({implementation: _strategyImplementation});
    }

    /************************************************
     *  EVENTS
     ***********************************************/

    /// @dev new vault clone
    event NewVault(address _owner, address _clone);

    /// @notice emitted when implementation is upgraded
    /// @param implementation: address of new implementation
    event VaultImplementationUpgraded(address implementation);

    /// @notice emitted when implementation is upgraded
    /// @param implementation: address of new implementation
    event StrategyImplementationUpgraded(address implementation);
}
