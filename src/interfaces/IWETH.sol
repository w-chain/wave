// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWETH - Wrapped Ether Interface
/// @notice Interface for WETH9 contract
interface IWETH is IERC20 {
    /// @notice Deposit ETH to get WETH
    function deposit() external payable;
    
    /// @notice Withdraw WETH to get ETH
    /// @param amount Amount of WETH to withdraw
    function withdraw(uint256 amount) external;
}