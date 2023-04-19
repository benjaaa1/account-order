// SPDX-License-Identifier: ISC
pragma solidity 0.8.16;

// inherits
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SimpleInitializable} from "@lyrafinance/protocol/contracts/libraries/SimpleInitializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// interfaces
import {ITradeTypes} from "./interfaces/ITradeTypes.sol";

// libraries
import "./utils/AddressSetLib.sol";
import "./utils/MinimalProxyFactory.sol";
import "./synthetix/DecimalMath.sol";

// spread and ranged markets
import "./SpreadOptionMarket.sol";
import "./markets/RangedMarket.sol";
import "./markets/RangedMarketToken.sol";

// clone library
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title OtusAMM
 * @author Otus
 * @dev Handles creating markets/vaults
 * @dev Traders buy RangedMarketTokens through AMM
 * @dev Calculates max and min costs for user
 */
contract OtusAMM is Ownable, SimpleInitializable, ReentrancyGuard, ITradeTypes {
    using AddressSetLib for AddressSetLib.AddressSet;
    using DecimalMath for uint;

    /************************************************
     *  INIT STATE
     ***********************************************/
    SpreadOptionMarket public spreadOptionMarket;

    // position market
    address public positionMarket; // implementation

    // ranged markets
    address public rangedMarket; // implementation

    address public rangedMarketToken; // implementation

    address public quoteAsset;

    AddressSetLib.AddressSet internal _knownMarkets;

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
        address payable _spreadOptionMarket,
        address _quoteAsset,
        address _positionMarket,
        address _rangedMarket,
        address _rangedMarketToken,
        address _ethLyraBase,
        address _btcLyraBase
    ) external onlyOwner initializer {
        spreadOptionMarket = SpreadOptionMarket(_spreadOptionMarket);
        quoteAsset = _quoteAsset;
        // implementations
        positionMarket = _positionMarket;
        rangedMarket = _rangedMarket;
        rangedMarketToken = _rangedMarketToken;

        lyraBases[bytes32("ETH")] = ILyraBase(_ethLyraBase);
        lyraBases[bytes32("BTC")] = ILyraBase(_btcLyraBase);

        emit OtusAMMInit(address(this), _spreadOptionMarket, _ethLyraBase, _btcLyraBase);
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
        PositionMarket(positionMarketInClone).initialize(
            payable(address(spreadOptionMarket)),
            rangedMarketClone,
            quoteAsset,
            _market
        );

        PositionMarket(positionMarketOutClone).initialize(
            payable(address(spreadOptionMarket)),
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
            positionMarketInClone,
            positionMarketOutClone,
            tokenInClone,
            tokenOutClone,
            msg.sender
        );
    }

    /**
     * @notice traders buy in and out tokens
     * @dev to update to whitelist rangedMarket address
     * @param _position in / out bool
     * @param _rangedMarket address
     * @param _amount size
     * @param _price max price also used to transfer quote
     * @param tradesWithPricing trades list
     */
    function buy(
        RangedPosition _position,
        address _rangedMarket,
        uint _amount,
        uint _price,
        TradeInputParameters[] memory tradesWithPricing // will include max cost with slippage
    ) external knownRangedMarket(_rangedMarket) {
        // @dev check if valid ranged market
        if (_position == RangedPosition.IN) {
            RangedMarket(_rangedMarket).buyIn(_amount, msg.sender, _price, tradesWithPricing);
        } else {
            RangedMarket(_rangedMarket).buyOut(_amount, msg.sender, _price, tradesWithPricing);
        }
    }

    /**
     * @notice traders buy in and out tokens
     * @dev to update to whitelist rangedMarket address
     * @param _position in / out bool
     * @param _rangedMarket address
     * @param _price min price expected
     * @param _amount amount of positions
     */
    function sell(
        RangedPosition _position,
        address _rangedMarket,
        uint _amount,
        uint _price,
        uint _slippage,
        TradeInputParameters[] memory tradesWithPricing // will include max cost with slippage
    ) external knownRangedMarket(_rangedMarket) {
        // @dev check if valid ranged market
        if (_position == RangedPosition.IN) {
            RangedMarket(_rangedMarket).sellIn(msg.sender, _amount, _price, _slippage, tradesWithPricing);
        } else {
            RangedMarket(_rangedMarket).sellOut(msg.sender, _amount, _price, _slippage, tradesWithPricing);
        }
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
        address positionMarketInClone,
        address positionMarketOutClone,
        address rangedMarketTokenIn,
        address rangedMarketTokenOut,
        address _owner
    );

    event OtusAMMInit(address otus, address spreadOptionMarket, address lyraBaseETH, address lyraBaseBTC);

    /************************************************
     *  ERRORS
     ***********************************************/

    error NotImplemented();
}
