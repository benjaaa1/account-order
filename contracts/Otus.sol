// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SimpleInitializeable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// interfaces
import {ITradeTypes} from "./interfaces/ITradeTypes.sol";

// libraries
import "./utils/AddressSetLib.sol";
import "./utils/MinimalProxyFactory.sol";
import "./synthetix/DecimalMath.sol";

// spread and ranged markets
import "./markets/RangedMarket.sol";
import "./positions/RangedMarketToken.sol";

// clone library
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title Otus
 * @author Otus
 * @dev Handles creating markets/vaults
 */
contract Otus is Ownable, SimpleInitializeable, ReentrancyGuard, ITradeTypes {
    using AddressSetLib for AddressSetLib.AddressSet;
    using DecimalMath for uint;

    /************************************************
     *  INIT STATE
     ***********************************************/
    // otus options market
    address public otusOptionMarket;

    // spread option market
    address public spreadMarket;

    // position market
    address public positionMarket; // implementation

    // ranged markets
    address public rangedMarket; // implementation

    address public rangedMarketToken; // implementation

    address public quoteAsset;

    AddressSetLib.AddressSet internal _knownMarkets;

    AddressSetLib.AddressSet internal _knownVaults;

    mapping(bytes32 => ILyraBase) public lyraBases;

    /************************************************
     *  MODIFIERS
     ***********************************************/

    modifier knownRangedMarket(address market) {
        require(_knownMarkets.contains(market), "Not a known ranged market");
        _;
    }

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/
    constructor() Ownable() {}

    function initialize(
        address _otusOptionMarket,
        address payable _spreadMarket,
        address _quoteAsset,
        address _positionMarket,
        address _rangedMarket,
        address _rangedMarketToken,
        address _ethLyraBase,
        address _btcLyraBase
    ) external onlyOwner initializer {
        otusOptionMarket = _otusOptionMarket;
        spreadMarket = _spreadMarket;
        quoteAsset = _quoteAsset;

        // market & vault implementations
        positionMarket = _positionMarket;
        rangedMarket = _rangedMarket;
        rangedMarketToken = _rangedMarketToken;

        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);
    }

    /**
     * @notice creates ranged market with position tokens
     * @param _market btc / eth
     * @param _expiry strikes expiry
     * @param _inTrades params of in trade
     * @param _outTrades params of out trade
     * @return rangedMarketClone address
     * @return positionMarketInClone address
     * @return positionMarketOutClone address
     * @return tokenInClone address
     * @return tokenOutClone address
     */
    function createRangedMarket(
        bytes32 _market,
        uint _expiry,
        TradeInputParameters[] memory _inTrades,
        TradeInputParameters[] memory _outTrades
    )
        external
        returns (
            address rangedMarketClone,
            address positionMarketInClone,
            address positionMarketOutClone,
            address tokenInClone,
            address tokenOutClone
        )
    {
        // validate valid ranged market
        rangedMarketClone = Clones.clone(rangedMarket);
        positionMarketInClone = Clones.clone(positionMarket);
        positionMarketOutClone = Clones.clone(positionMarket);
        tokenInClone = Clones.clone(rangedMarketToken);
        tokenOutClone = Clones.clone(rangedMarketToken);

        // init & set ranged market
        RangedMarket(rangedMarketClone).initialize(
            quoteAsset,
            positionMarketInClone,
            positionMarketOutClone,
            tokenInClone,
            tokenOutClone,
            _market,
            _expiry,
            _inTrades,
            _outTrades
        );

        // init position markets
        PositionMarket(positionMarketInClone).initialize(payable(spreadMarket), rangedMarketClone, quoteAsset, _market);

        PositionMarket(positionMarketOutClone).initialize(
            payable(otusOptionMarket),
            rangedMarketClone,
            quoteAsset,
            _market
        );

        // init range market tokens
        RangedMarketToken(tokenInClone).initialize(rangedMarketClone, "Otus In", "IN");

        RangedMarketToken(tokenOutClone).initialize(rangedMarketClone, "Otus Out", "OUT");

        _knownMarkets.add(rangedMarketClone);

        emit NewRangedMarket(
            rangedMarketClone,
            _expiry,
            _market,
            _inTrades,
            _outTrades,
            positionMarketInClone,
            positionMarketOutClone,
            tokenInClone,
            tokenOutClone,
            msg.sender
        );
    }

    /************************************************
     *  MORE VAULTS
     ***********************************************/

    /************************************************
     * UTILS
     ***********************************************/
    /**
     * @notice get lyrabase methods
     * @param market market (btc / eth bytes32)
     * @return ILyraBase interface
     */
    function lyraBase(bytes32 market) public view returns (ILyraBase) {
        require(address(lyraBases[market]) != address(0), "LyraBase: Not available");
        return lyraBases[market];
    }

    /************************************************
     *  EVENTS
     ***********************************************/

    event NewRangedMarket(
        address clone,
        uint expiry,
        bytes32 market,
        TradeInputParameters[] inTrades,
        TradeInputParameters[] outTrades,
        address positionMarketInClone,
        address positionMarketOutClone,
        address rangedMarketTokenIn,
        address rangedMarketTokenOut,
        address _owner
    );

    /************************************************
     *  ERRORS
     ***********************************************/

    error NotImplemented();
}
