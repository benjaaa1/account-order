// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

import "hardhat/console.sol";

import "../interfaces/ILyraBase.sol";

import "../synthetix/SafeDecimalMath.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// import {SpreadOptionMarket} from "./SpreadOptionMarket.sol";
import {SimpleInitializable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializable.sol";

import {OptionToken} from "@lyrafinance/protocol/contracts/OptionToken.sol";
import {OptionMarket} from "@lyrafinance/protocol/contracts/OptionMarket.sol";

import {ITradeTypes} from "../interfaces/ITradeTypes.sol";
// inherits
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/**
 * @title OtusOptionToken
 * @author Otus
 * @dev Provides a tokenized representation of each trade position including amount of options and collateral used from Pool.
 */
contract OtusOptionToken is Ownable, SimpleInitializable, ReentrancyGuard, ERC721Enumerable, ITradeTypes {
    using SafeDecimalMath for uint;

    enum PositionUpdatedType {
        OPENED,
        ADJUSTED,
        CLOSED,
        SETTLED,
        LIQUIDATED,
        TRANSFER
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

    struct OtusOptionPosition {
        uint size;
        address trader;
        bytes32 market;
        uint positionId;
        uint collateralBorrowed;
        uint maxLossPosted;
        PositionState state;
        uint[] allPositions;
        TradeType tradeType;
    }

    mapping(uint => OtusOptionPosition) public positions;

    uint public nextId = 1;

    /************************************************
     *  INIT STATE
     ***********************************************/

    // otus options market
    address public otusOptionMarket;

    // spread option market
    address public spreadMarket;

    mapping(bytes32 => ILyraBase) public lyraBases;

    /************************************************
     *  MODIFIERS
     ***********************************************/

    modifier onlySpreadMarket() {
        if (msg.sender != spreadMarket) {
            revert OnlySpreadOptionMarket(address(this), msg.sender, spreadMarket);
        }
        _;
    }

    modifier onlyOtusMarket() {
        if (msg.sender != otusOptionMarket) {
            revert OnlyOtusOptionMarket(address(this), msg.sender, otusOptionMarket);
        }
        _;
    }

    modifier onlyOtusMarkets() {
        if (msg.sender != spreadMarket && msg.sender != otusOptionMarket) {
            revert OnlyOtusMarkets(address(this), msg.sender);
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
     * @param _otusOptionMarket otus spread option market/trader
     * @param _spreadMarket otus spread option market/trader
     */
    function initialize(
        address _otusOptionMarket,
        address _spreadMarket,
        address _ethLyraBase,
        address _btcLyraBase
    ) external onlyOwner initializer {
        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);
        otusOptionMarket = _otusOptionMarket;
        spreadMarket = _spreadMarket;
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
    ) public onlySpreadMarket returns (uint) {
        return
            _openPosition(
                _trader,
                _tradeInfo.market,
                _sellResults,
                _buyResults,
                _tradeInfo.positionId, // position id
                _totalSetCollateralTo,
                _maxLossPosted,
                TradeType.SPREAD
            );
    }

    /**
     * @notice Opens position amount and collateral when position is
     * opened/closed/forceclosed/liquidated
     * @param _trader owner
     * @param _sellResults results from trade
     * @param _buyResults results from trade
     * @dev may need to combine the results and trades arrays
     */
    function openPosition(
        TradeInfo memory _tradeInfo,
        address _trader,
        TradeResult[] memory _sellResults,
        TradeResult[] memory _buyResults
    ) public onlyOtusMarket returns (uint) {
        return
            _openPosition(
                _trader,
                _tradeInfo.market,
                _sellResults,
                _buyResults,
                _tradeInfo.positionId, // position id
                0,
                0,
                TradeType.MULTI
            );
    }

    /**
     * @notice Adjusts position amount and collateral when position is
     * opened/closed/forceclosed/liquidated
     * @param _trader owner
     * @param _sellResults results from trade
     * @param _buyResults results from trade
     * @param _positionId refers to SpreadOptionsPosition
     * @param _totalSetCollateralTo total collateral borrowed
     * @param _maxLossPosted max loss posted by user
     */
    function _openPosition(
        address _trader,
        bytes32 _market,
        TradeResult[] memory _sellResults,
        TradeResult[] memory _buyResults,
        uint _positionId,
        uint _totalSetCollateralTo,
        uint _maxLossPosted,
        TradeType _tradeType
    ) internal returns (uint) {
        OtusOptionPosition storage position;
        bool newPosition = false;
        if (_positionId == 0) {
            _positionId = nextId++;
            _mint(_trader, _positionId);
            position = positions[_positionId];
            position.tradeType = _tradeType;
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
                position.size += result.amount;
            }

            for (uint i = 0; i < _buyResults.length; i++) {
                TradeResult memory result = _buyResults[i];
                position.allPositions[sellLen + i] = result.positionId;
                position.size += result.amount;
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
            revert OnlyOwnerCanAdjustPosition(address(this), _positionId, _trader, ownerOf(position.positionId));
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

    /**
     * @notice Closes position amount and decreases maxloss
     * opened/closed/forceclosed/liquidated
     * @param _trader owner
     * @param _partialSum owner
     * @param _positionId owner
     * @param _sellResults results from trade
     * @param _buyResults results from trade
     */
    function closePosition(
        address _trader,
        uint _partialSum, // multiply partial sum to previous maxloss posted and set new maxloss
        uint _positionId,
        TradeResult[] memory _sellResults,
        TradeResult[] memory _buyResults
    ) public onlySpreadMarket {
        OtusOptionPosition storage position;

        if (_positionId == 0) {
            revert CannotClosePositionZero(address(this));
        }

        position = positions[_positionId];

        if (_trader != ownerOf(position.positionId)) {
            revert OnlyOwnerCanAdjustPosition(address(this), _positionId, _trader, ownerOf(position.positionId));
        }

        if (_partialSum > 0) {
            position.maxLossPosted -= position.maxLossPosted.multiplyDecimal(_partialSum.divideDecimal(position.size));
            for (uint i = 0; i < _sellResults.length; i++) {
                TradeResult memory result = _sellResults[i];
                position.size -= result.amount;
            }

            for (uint i = 0; i < _buyResults.length; i++) {
                TradeResult memory result = _buyResults[i];
                position.size -= result.amount;
            }
        } else {
            position.maxLossPosted = 0;
            position.state = PositionState.CLOSED;
        }

        emit PositionUpdated(
            position.positionId,
            _trader,
            _partialSum > 0 ? PositionUpdatedType.ADJUSTED : PositionUpdatedType.CLOSED,
            position,
            block.timestamp
        );
    }

    /************************************************
     * UTILS
     ***********************************************/

    function getPosition(uint _positionId) external view returns (OtusOptionPosition memory position) {
        position = positions[_positionId];
    }

    /**
     * @notice Returns an array of OptionPosition structs owned by a given address
     * @param target owner address
     * @dev Meant to be used offchain as it can run out of gas
     */
    function getOwnerPositions(address target) external view returns (OtusOptionPosition[] memory) {
        uint balance = balanceOf(target);
        OtusOptionPosition[] memory result = new OtusOptionPosition[](balance);
        for (uint i = 0; i < balance; ++i) {
            result[i] = positions[ERC721Enumerable.tokenOfOwnerByIndex(target, i)];
        }
        return result;
    }

    /**
     * @notice returns position ids
     * @return positionIds position ids for otus option position
     */
    function getPositionIds() external view returns (uint[] memory positionIds) {
        positionIds = new uint[](totalSupply());

        for (uint i = 0; i < totalSupply(); i++) {
            positionIds[i] = tokenByIndex(i);
        }
    }

    /**
     * @notice Ensure all positions are settled on lyra
     * @param _otusPositionId Position Id of Spread Option traded
     * @return settledPositions position info
     */
    function checkLyraPositionsSettled(
        uint _otusPositionId
    ) external view returns (SettledPosition[] memory settledPositions) {
        OtusOptionPosition storage position = positions[_otusPositionId];

        if (position.positionId == 0) {
            revert OtusOptionPositionNotValid(_otusPositionId);
        }

        uint positionsLen = position.allPositions.length;
        settledPositions = new SettledPosition[](positionsLen);

        address _optionToken = lyraBase(position.market).getOptionToken();
        address _optionMarket = lyraBase(position.market).getOptionMarket();

        OptionMarket optionMarket = OptionMarket(_optionMarket);
        OptionToken optionToken = OptionToken(_optionToken);

        // can't use getPositionsWithOwner because option token has been burned on settlement by lyra
        // use getOptionPositions
        OptionToken.OptionPosition[] memory optionPositions = optionToken.getOptionPositions(position.allPositions);

        uint strikePrice;
        uint priceAtExpiry;

        // need to be settled
        for (uint i = 0; i < optionPositions.length; i++) {
            OptionToken.OptionPosition memory lyraPosition = optionPositions[i];
            // state closed - collateral routing handled on close
            // @todo state liquidated
            if (lyraPosition.state == OptionToken.PositionState.SETTLED) {
                (strikePrice, priceAtExpiry, , ) = optionMarket.getSettlementParameters(lyraPosition.strikeId);

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
     * @param _positionId id of position
     */
    function settlePosition(uint _positionId) public onlyOtusMarkets {
        positions[_positionId].state = PositionState.SETTLED;

        emit PositionUpdated(
            _positionId,
            ownerOf(_positionId),
            PositionUpdatedType.SETTLED,
            positions[_positionId],
            block.timestamp
        );

        _burn(_positionId);
    }

    /**
     * @notice empties position used by otus market when transferring underlying tokens to trader
     * @param _positionId id of position
     */
    function emptyPosition(uint _positionId) public onlyOtusMarket {
        positions[_positionId].state = PositionState.EMPTY;

        emit PositionUpdated(
            _positionId,
            ownerOf(_positionId),
            PositionUpdatedType.ADJUSTED,
            positions[_positionId],
            block.timestamp
        );
        _burn(_positionId);
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
    /// @dev only otus option market
    error OnlyOtusOptionMarket(address thrower, address caller, address optionMarket);

    /// @dev only spread market
    error OnlySpreadOptionMarket(address thrower, address caller, address optionMarket);

    /// @dev only otus markets
    error OnlyOtusMarkets(address thrower, address caller);

    /// @dev attempt to adjust non existent position
    error CannotClosePositionZero(address thrower);

    /// @dev only trader
    error OnlyOwnerCanAdjustPosition(address thrower, uint positionId, address trader, address owner);

    /// @dev position not settled in lyra
    error LyraPositionNotSettled(OptionToken.OptionPosition lyraPosition);

    /// @dev reverted when position id doesn't exist
    error OtusOptionPositionNotValid(uint positionId);
    /************************************************
     * EVENTS
     ***********************************************/

    /// @dev Emitted when a position is minted, adjusted, burned, merged or split
    event PositionUpdated(
        uint indexed positionId, // spread position
        address indexed owner,
        PositionUpdatedType indexed updatedType,
        OtusOptionPosition position,
        uint timestamp
    );
}
