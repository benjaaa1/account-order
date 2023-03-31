// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

import "hardhat/console.sol";

import "./interfaces/ILyraBase.sol";

import "./synthetix/SafeDecimalMath.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// import {SpreadOptionMarket} from "./SpreadOptionMarket.sol";
import {SimpleInitializeable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializeable.sol";

import {IOptionToken} from "@lyrafinance/protocol/contracts/interfaces/IOptionToken.sol";
import {OptionToken} from "@lyrafinance/protocol/contracts/OptionToken.sol";
import {OptionMarket} from "@lyrafinance/protocol/contracts/OptionMarket.sol";

import {ITradeTypes} from "./interfaces/ITradeTypes.sol";
// inherits
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/**
 * @title SpreadOptionToken
 * @author Otus
 * @dev Provides a tokenized representation of each trade position including amount of options and collateral used from Pool.
 */
contract SpreadOptionToken is
    Ownable,
    SimpleInitializeable,
    ReentrancyGuard,
    ERC721Enumerable,
    ITradeTypes
{
    using SafeDecimalMath for uint;

    enum PositionState {
        EMPTY,
        ACTIVE,
        CLOSED,
        LIQUIDATED,
        SETTLED
    }

    enum PositionUpdatedType {
        OPENED,
        ADJUSTED,
        CLOSED,
        SETTLED,
        LIQUIDATED
    }

    struct SettledPosition {
        OptionMarket.OptionType optionType;
        address trader;
        uint collateral;
        uint amount;
        uint strikePrice;
        uint priceAtExpiry;
    }

    struct OptionPostion {
        uint positionId;
        uint strikeId;
        uint optionType;
        uint amount;
        uint setCollateralTo;
    }

    struct SpreadOptionPosition {
        address trader;
        bytes32 market;
        uint positionId;
        uint collateralBorrowed;
        uint maxLossPosted;
        PositionState state;
        uint[] allPositions;
    }

    mapping(uint => SpreadOptionPosition) public positions;

    uint public nextId = 1;

    /************************************************
     *  INIT STATE
     ***********************************************/

    address public spreadOptionMarket;

    mapping(bytes32 => ILyraBase) public lyraBases;

    /************************************************
     *  MODIFIERS
     ***********************************************/

    modifier onlySpreadOptionMarket() {
        if (msg.sender != spreadOptionMarket) {
            revert OnlySpreadOptionMarket(address(this), msg.sender, spreadOptionMarket);
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
     * @param _spreadOptionMarket otus spread option market/trader
     */
    function initialize(
        address _spreadOptionMarket,
        address _ethLyraBase,
        address _btcLyraBase
    ) external onlyOwner initializer {
        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);
        spreadOptionMarket = _spreadOptionMarket;
    }

    /************************************************
     * POSITION MANAGE
     ***********************************************/

    /**
     * @notice Opens position amount and collateral when spread position is
     * opened/closed/forceclosed/liquidated
     * @param _trader owner
     * @param _sellResults results from trade
     * @param _buyResults results from trade
     * @param _totalSetCollateralTo total collateral borrowed
     * @dev may need to combine the results and trades arrays
     */
    function openPosition(
        TradeInfo memory _tradeInfo,
        address _trader,
        TradeResult[] memory _sellResults,
        TradeResult[] memory _buyResults,
        uint _totalSetCollateralTo,
        uint _maxLossPosted
    ) public onlySpreadOptionMarket returns (uint) {
        return
            _adjustPosition(
                _trader,
                _tradeInfo.market,
                _sellResults,
                _buyResults,
                _tradeInfo.positionId, // position id
                _totalSetCollateralTo,
                _maxLossPosted,
                true
            );
    }

    /**
     * @notice Adjusts position amount and collateral when spread position is
     * opened/closed/forceclosed/liquidated
     * @param _trader owner
     * @param _sellResults results from trade
     * @param _buyResults results from trade
     * @param _positionId refers to SpreadOptionsPosition
     * @param _totalSetCollateralTo total collateral borrowed
     * @param _maxLossPosted max loss posted by user
     * @param _isOpen opening new position
     * @dev may need to combine the results and trades arrays
     */
    function _adjustPosition(
        address _trader,
        bytes32 _market,
        TradeResult[] memory _sellResults,
        TradeResult[] memory _buyResults,
        uint _positionId,
        uint _totalSetCollateralTo,
        uint _maxLossPosted,
        bool _isOpen
    ) internal returns (uint) {
        SpreadOptionPosition storage position;
        bool newPosition = false;
        if (_positionId == 0) {
            if (!_isOpen) {
                revert CannotClosePositionZero(address(this));
            }

            _positionId = nextId++;
            _mint(_trader, _positionId);
            position = positions[_positionId];
            position.trader = _trader;
            position.market = _market;
            position.positionId = _positionId;

            position.state = PositionState.ACTIVE;
            // add detials need to manage position here
            position.collateralBorrowed = _totalSetCollateralTo;
            position.maxLossPosted = _maxLossPosted;

            uint sellLen = _sellResults.length;
            uint buyLen = _buyResults.length;

            position.allPositions = new uint[](sellLen + buyLen);

            for (uint i = 0; i < _sellResults.length; i++) {
                TradeResult memory result = _sellResults[i];
                position.allPositions[i] = result.positionId;
            }

            for (uint i = 0; i < _buyResults.length; i++) {
                TradeResult memory result = _buyResults[i];
                position.allPositions[sellLen + i] = result.positionId;
            }

            newPosition = true;
        } else {
            position = positions[_positionId];
            position.collateralBorrowed += _totalSetCollateralTo;
            position.maxLossPosted += _maxLossPosted;
        }

        // users can adjust positions
        // they can close or add size

        if (_trader != ownerOf(position.positionId)) {
            revert OnlyOwnerCanAdjustPosition(
                address(this),
                _positionId,
                _trader,
                ownerOf(position.positionId)
            );
        }

        if (_isOpen) {
            // multiple positionids from lyra need to keep them in state and update them easily
        } else {
            position.collateralBorrowed = 0;
        }

        emit PositionUpdated(
            position.positionId,
            _trader,
            newPosition ? PositionUpdatedType.OPENED : PositionUpdatedType.ADJUSTED,
            position,
            block.timestamp
        );

        return position.positionId;
    }

    /************************************************
     * UTILS
     ***********************************************/

    function getPosition(
        uint _spreadPositionId
    ) external view returns (SpreadOptionPosition memory position) {
        position = positions[_spreadPositionId];
    }

    /**
     * @notice Returns an array of OptionPosition structs owned by a given address
     * @param target owner address
     * @dev Meant to be used offchain as it can run out of gas
     */
    function getOwnerPositions(
        address target
    ) external view returns (SpreadOptionPosition[] memory) {
        uint balance = balanceOf(target);
        SpreadOptionPosition[] memory result = new SpreadOptionPosition[](balance);
        for (uint i = 0; i < balance; ++i) {
            result[i] = positions[ERC721Enumerable.tokenOfOwnerByIndex(target, i)];
        }
        return result;
    }

    /**
     * @notice returns position ids
     * @return positionIds position ids for spread option position
     */
    function getPositionIds() external view returns (uint[] memory positionIds) {
        positionIds = new uint[](totalSupply());

        for (uint i = 0; i < totalSupply(); i++) {
            positionIds[i] = tokenByIndex(i);
        }
    }

    /**
     * @notice Ensure all positions are settled on lyra
     * @param _spreadPostionId Position Id of Spread Option traded
     * @return trader address of owner
     * @return settledPositions position info
     */
    function checkLyraPositionsSettled(
        uint _spreadPostionId
    ) external view returns (address trader, SettledPosition[] memory settledPositions) {
        SpreadOptionPosition storage position = positions[_spreadPostionId];

        if (position.positionId == 0) {
            revert SpreadOptionPositionNotValid(_spreadPostionId);
        }

        trader = position.trader;
        uint positionsLen = position.allPositions.length;
        settledPositions = new SettledPosition[](positionsLen);

        address _optionToken = lyraBase(position.market).getOptionToken();
        address _optionMarket = lyraBase(position.market).getOptionMarket();

        OptionMarket optionMarket = OptionMarket(_optionMarket);
        OptionToken optionToken = OptionToken(_optionToken);

        // can't use getPositionsWithOwner because option token has been burned on settlement by lyra
        //  use getOptionPositions
        OptionToken.OptionPosition[] memory optionPositions = optionToken.getOptionPositions(
            position.allPositions
        );

        uint strikePrice;
        uint priceAtExpiry;

        // need to be settled
        for (uint i = 0; i < optionPositions.length; i++) {
            OptionToken.OptionPosition memory lyraPosition = optionPositions[i];
            // state closed - collateral routing handled on close
            // state liquidated - handled by keeper for edge case
            if (lyraPosition.state == OptionToken.PositionState.SETTLED) {
                (strikePrice, priceAtExpiry, ) = optionMarket.getSettlementParameters(
                    lyraPosition.strikeId
                );

                settledPositions[i] = SettledPosition({
                    trader: position.trader,
                    optionType: lyraPosition.optionType,
                    collateral: lyraPosition.collateral,
                    amount: lyraPosition.amount,
                    strikePrice: strikePrice,
                    priceAtExpiry: priceAtExpiry
                });
            } else {
                revert LyraPositionNotSettled(lyraPosition);
            }
        }
    }

    /**
     * @notice settles position
     * @param _spreadPositionId id of position
     */
    function settlePosition(uint _spreadPositionId) public onlySpreadOptionMarket {
        positions[_spreadPositionId].state = PositionState.SETTLED;

        emit PositionUpdated(
            _spreadPositionId,
            ownerOf(_spreadPositionId),
            PositionUpdatedType.SETTLED,
            positions[_spreadPositionId],
            block.timestamp
        );

        _burn(_spreadPositionId);
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

    /// @dev attempt to adjust non existent position
    error CannotClosePositionZero(address thrower);

    /// @dev only trader
    error OnlyOwnerCanAdjustPosition(
        address thrower,
        uint positionId,
        address trader,
        address owner
    );

    /// @dev position not settled in lyra
    error LyraPositionNotSettled(OptionToken.OptionPosition lyraPosition);

    /// @dev reverted when position id doesn't exist
    error SpreadOptionPositionNotValid(uint positionId);
    /************************************************
     * EVENTS
     ***********************************************/

    /// @dev Emitted when a position is minted, adjusted, burned, merged or split
    event PositionUpdated(
        uint indexed positionId, // spread position
        address indexed owner,
        PositionUpdatedType indexed updatedType,
        SpreadOptionPosition position,
        uint timestamp
    );
}
