// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWaveMaker {
  /// @notice User staking information
  /// @param stakedAmount Amount of tokens staked by the user
  /// @param rewardOffset Accumulated rewards offset for pending amount
  struct User {
      uint256 stakedAmount;
      uint256 rewardOffset;
  }

  /// @notice Pool configuration and state
  /// @param accWavePerShare Accumulated WAVE rewards per share, scaled by WAD
  /// @param token The ERC20 token that can be staked in this pool
  /// @param lastRewardBlock Last block number when rewards were distributed
  /// @param allocation Pool's share of total reward allocation
  /// @param multiplier Reward multiplier in BPS, maximum 65x
  struct Pool {
      uint256 accWavePerShare;
      IERC20 token;
      uint32 lastRewardBlock;
      uint16 allocation;
      uint16 multiplier;
  }

  event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event Stake(address indexed user, uint256 amount);
  event Unstake(address indexed user, uint256 amount);
  event DepositETH(address indexed user, uint256 amount);
  event WithdrawETH(address indexed user, uint256 amount);
  event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
  event SetTreasury(address indexed treasury);
  event SetPAPeriphery(address indexed paPeriphery);
  event SetWavePerBlock(uint256 wavePerBlock);
  event SetStakingAllocationFactor(uint256 stakingAllocationFactor);
  event AddPool(uint256 indexed pid, IERC20 indexed token, uint16 allocation, uint16 multiplier);
  event UpdatePool(uint256 indexed pid, IERC20 indexed token, uint16 allocation, uint16 multiplier);
  event PoolSynced(uint256 indexed pid, uint256 accWavePerShare, uint32 lastRewardBlock);

  error ZeroAddress();
  error ZeroAmount();
  error Unauthorized();
  error InvalidParams();
  error InsufficientBalance();

  /// @notice Protocol information structure for frontend display
  /// @param totalPools Total number of incentivized pools
  /// @param totalAllocations Sum of all pool allocations
  /// @param wavePerBlock WAVE tokens minted per block
  /// @param stakingAllocationFactor Staking pool allocation factor in BPS
  struct ProtocolInfo {
      uint256 totalPools;
      uint256 totalAllocations;
      uint256 wavePerBlock;
      uint256 stakingAllocationFactor;
  }

  /// @notice Pool information structure for frontend display
  /// @param pid Pool ID
  /// @param token Address of the staked token
  /// @param allocation Pool's allocation points
  /// @param multiplier Pool's reward multiplier in BPS
  /// @param totalStaked Total amount of tokens staked in this pool
  /// @param accWavePerShare Accumulated WAVE per share
  /// @param lastRewardBlock Last block when rewards were distributed
  struct PoolInfo {
      uint256 pid;
      address token;
      uint16 allocation;
      uint16 multiplier;
      uint256 totalStaked;
      uint256 accWavePerShare;
      uint32 lastRewardBlock;
  }

  /// @notice User pool information structure for frontend display
  /// @param pid Pool ID
  /// @param stakedAmount Amount staked by user in this pool
  /// @param pendingReward Pending rewards for user in this pool
  struct UserPoolInfo {
      uint256 pid;
      uint256 stakedAmount;
      uint256 pendingReward;
  }

  /// @notice Complete user information structure for frontend display
  /// @param totalStaked Total amount staked across all pools
  /// @param totalPendingRewards Total pending rewards across all pools
  /// @param personalMultiplier User's personal reward multiplier
  /// @param poolsInfo Array of user's pool information
  struct UserInfo {
      uint256 totalStaked;
      uint256 totalPendingRewards;
      uint256 personalMultiplier;
      UserPoolInfo[] poolsInfo;
  }

  function poolsLength() external view returns (uint256);
  function pendingReward(uint256 pid, address account) external view returns (uint256);
  function getUserStakedAmount(uint256 pid, address account) external view returns (uint256);
  function sync(uint256 pid) external;
  function syncAll() external;
  function deposit(uint256 pid, uint256 amount) external;
  function withdraw(uint256 pid, uint256 amount) external;
  function stake(uint256 amount) external;
  function unstake(uint256 amount) external;
  function depositETH() external payable;
  function withdrawETH(uint256 amount) external;
  function initializeETHPool(address weth, uint16 allocation, uint32 startBlock) external;
  function harvestAll() external;
  
  /// @notice Returns protocol information for frontend display
  /// @return Protocol information including total pools, allocations, and parameters
  function getProtocolInfo() external view returns (ProtocolInfo memory);
  
  /// @notice Returns information about all incentivized pools
  /// @return Array of pool information structures
  function getAllPoolsInfo() external view returns (PoolInfo[] memory);
  
  /// @notice Returns comprehensive user information across all pools
  /// @param account User address to query
  /// @return Complete user information including staking and rewards data
  function getUserInfo(address account) external view returns (UserInfo memory);
}