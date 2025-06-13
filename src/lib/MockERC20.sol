// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
  uint8 public immutable _decimals;
  constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
    _mint(_msgSender(), 1e15 * 1e18);
    _decimals = decimals_;
  }

  function decimals() public view override returns (uint8) {
      return _decimals;
  }
}