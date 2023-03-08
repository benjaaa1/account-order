// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
  constructor(
    string memory _name,
    string memory _symbol,
    uint totalSupply
  ) ERC20(_name, _symbol) {
    _mint(msg.sender, totalSupply);
  }

  function decimals() public view virtual override returns (uint8) {
    return 18;
  }

  function mint(address account, uint amount) public {
    _mint(account, amount);
  }

  function approve(address spender, uint amount) public virtual override returns (bool) {
    address owner = _msgSender();
    _approve(owner, spender, amount);
    return true;
  }
}
