// SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// inherits
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// spread option market
import {RangedMarket} from "./RangedMarket.sol";

contract RangedMarketToken is IERC20 {
    /************************************************
     *  CONSTANTS
     ***********************************************/
    uint8 public decimals;

    /************************************************
     *  INIT STATE
     ***********************************************/
    string public name;
    string public symbol;

    RangedMarket public rangedMarket;

    address public otusAMM;

    bool public initialized = false;

    /************************************************
     *  STATE
     ***********************************************/
    mapping(address => uint) public override balanceOf;
    uint public override totalSupply;

    // The argument order is allowance[owner][spender]
    mapping(address => mapping(address => uint)) private allowances;

    /************************************************
     *  MODIFIERS
     ***********************************************/

    modifier onlyRangedMarket() {
        if (msg.sender != address(rangedMarket)) {
            revert OnlyRangedMarket(address(this), msg.sender, address(rangedMarket));
        }
        _;
    }

    /************************************************
     *  CONSTRUCTOR
     ***********************************************/
    constructor(uint8 _decimals) {
        decimals = _decimals; // 18 susd 6 usdc
    }

    /************************************************
     *  INIT
     ***********************************************/
    /**
     * @notice initialize ranged market token
     * @param _rangedMarket RangedMarket
     */
    function initialize(
        address _rangedMarket,
        string calldata _name,
        string calldata _symbol
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        rangedMarket = RangedMarket(_rangedMarket);
        name = _name;
        symbol = _symbol;
        initialized = true;
    }

    /************************************************
     *  MINT AND BURN
     ***********************************************/
    function allowance(address owner, address spender) external view override returns (uint256) {
        if (spender == address(rangedMarket)) {
            return type(uint256).max;
        } else {
            return allowances[owner][spender];
        }
    }

    function burn(address claimant, uint amount) external onlyRangedMarket {
        balanceOf[claimant] = balanceOf[claimant] - amount;
        totalSupply = totalSupply - amount;
        emit Burned(claimant, amount);
        emit Transfer(claimant, address(0), amount);
    }

    function mint(address minter, uint amount) external onlyRangedMarket {
        totalSupply = totalSupply + amount;
        balanceOf[minter] = balanceOf[minter] + amount;
        emit Mint(minter, amount);
        emit Transfer(address(0), minter, amount);
    }

    /************************************************
     *  ERC20 Functions
     ***********************************************/
    function _transfer(address _from, address _to, uint _value) internal returns (bool success) {
        require(_to != address(0) && _to != address(this), "Invalid address");

        uint fromBalance = balanceOf[_from];
        require(_value <= fromBalance, "Insufficient balance");

        balanceOf[_from] = fromBalance - _value;
        balanceOf[_to] = balanceOf[_to] + _value;

        emit Transfer(_from, _to, _value);
        return true;
    }

    function transfer(address _to, uint _value) external override returns (bool success) {
        return _transfer(msg.sender, _to, _value);
    }

    function transferFrom(
        address _from,
        address _to,
        uint _value
    ) external override returns (bool success) {
        if (msg.sender != address(rangedMarket)) {
            uint fromAllowance = allowances[_from][msg.sender];
            require(_value <= fromAllowance, "Insufficient allowance");
            if (_value > fromAllowance) {
                revert InsufficientAllowance();
            }
            allowances[_from][msg.sender] = fromAllowance - _value;
        }
        return _transfer(_from, _to, _value);
    }

    function approve(address _spender, uint _value) external override returns (bool success) {
        require(_spender != address(0));
        allowances[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
        return true;
    }

    function getBalanceOf(address account) external view returns (uint) {
        return balanceOf[account];
    }

    function getTotalSupply() external view returns (uint) {
        return totalSupply;
    }

    /************************************************
     *  EVENTS
     ***********************************************/
    event Mint(address minter, uint amount);
    event Burned(address burner, uint amount);

    /************************************************
     *  ERRORS
     ***********************************************/

    error OnlyRangedMarket(address thrower, address caller, address rangedMarket);

    error AlreadyInitialized();

    error InsufficientAllowance();
}
