// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "./utils/MinimalProxyFactory.sol";

import "./AccountOrder.sol";

// Interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AccountFactory is MinimalProxyFactory {
    /// @notice LyraAccountOrder contract address
    address public immutable implementation;

    /// @notice ERC20 token used to interact with markets
    IERC20 public immutable quoteAsset;

    address public immutable ethLyraBase;

    address public immutable btcLyraBase;

    /// @notice gelato ops
    address payable public immutable ops;

    /************************************************
     *  EVENTS
     ***********************************************/
    event NewAccount(address indexed owner, address account);

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/

    /**
     * @notice
     * @param _implementation account order implementation
     * @param _quoteAsset margin asset
     * @param _ethLyraBase lyra eth mm adapter / quoter to
     * @param _btcLyraBase lyra btc mm adapter / quoter to
     * @param _ops gelato ops address
     */
    constructor(
        address _implementation,
        address _quoteAsset,
        address _ethLyraBase,
        address _btcLyraBase,
        address payable _ops
    ) {
        implementation = _implementation;
        quoteAsset = IERC20(_quoteAsset);
        ethLyraBase = _ethLyraBase;
        btcLyraBase = _btcLyraBase;
        ops = _ops;
    }

    /**
     * @notice creates accountorder for user
     * @return accountAddress account order contract proxy address
     */
    function newAccount() external returns (address payable accountAddress) {
        accountAddress = payable(_cloneAsMinimalProxy(address(implementation), "Creation failure"));
        AccountOrder account = AccountOrder(accountAddress);
        account.initialize(address(quoteAsset), ethLyraBase, btcLyraBase, ops);
        account.transferOwnership(msg.sender);

        emit NewAccount(msg.sender, accountAddress);
    }
}
