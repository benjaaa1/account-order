// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "../synthetix/SafeDecimalMath.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

import {IOptionToken} from "@lyrafinance/protocol/contracts/interfaces/IOptionToken.sol";
import {SimpleInitializeable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializeable.sol";

import {ITradeTypes} from "../interfaces/ITradeTypes.sol";

import {ILyraBase} from "../interfaces/ILyraBase.sol";

/**
 * @title OtusOptionToken
 * @author Otus
 * @notice Holds info on different types of options
 * @dev Can be used to mint multi leg options on different assets and platforms.
 * @dev Has information on collateral, strike, expiration, etc.
 * @dev Used in multi leg as non fungible and ranged market tokens as fungible
 */
contract OtusOptionTokenV2 is Ownable, SimpleInitializeable, ReentrancyGuard, ERC721Enumerable, ITradeTypes {
    using SafeDecimalMath for uint;

    struct OptionPostion {
        uint positionId;
        uint strikeId;
        uint optionType;
        uint amount;
        uint setCollateralTo;
    }

    struct OtusOptionPosition {
        uint size;
        address trader;
        bytes32 market;
        uint positionId;
        uint collateralBorrowed;
        uint maxLossPosted;
        PositionState state;
        uint[] allPositions;
    }

    mapping(uint => OtusOptionPosition) public positions;

    uint public nextId = 1;

    /************************************************
     *  INIT STATE
     ***********************************************/

    address public otus;

    mapping(bytes32 => ILyraBase) public lyraBases;

    /************************************************
     *  MODIFIERS
     ***********************************************/

    modifier onlySpreadOptionMarket() {
        if (msg.sender != otus) {
            revert OnlySpreadOptionMarket(address(this), msg.sender, otus);
        }
        _;
    }

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) Ownable() {}

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize spread option market/trader
     * @param _otus otus spread option market/trader
     */
    function initialize(address _otus, address _ethLyraBase, address _btcLyraBase) external onlyOwner initializer {
        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);
        otus = _otus;
    }

    /************************************************
     *  Internal Lyra Base Getter
     ***********************************************/

    /// @dev get lyrabase instance for market
    function lyraBase(bytes32 market) internal view returns (ILyraBase) {
        require(address(lyraBases[market]) != address(0), "LyraBase: Not available");
        return lyraBases[market];
    }

    /************************************************
     * ERRORS
     ***********************************************/

    /// @dev only spread market
    error OnlySpreadOptionMarket(address thrower, address caller, address optionMarket);
}
