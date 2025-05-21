// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IACM } from "./interfaces/IACM.sol";
import { IWAVE } from "./interfaces/IWAVE.sol";
import { WadRayMath } from "./lib/WadRayMath.sol";

/// @title WaveMaker - A staking and reward distribution contract
/// @notice This contract manages staking pools and WAVE token rewards distribution inspired by SushiSwap
/// @dev Implements staking mechanism with multiple pools and reward calculation using WAD RAY math
contract WaveMaker is ReentrancyGuard {
    using WadRayMath for uint256;
    uint256 public constant BPS = 10000;

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

    IACM public immutable ACM;
    IWAVE public immutable WAVE;

    address public treasury;
    uint256 public wavePerBlock;
    uint256 public totalAllocations;
    uint256 public stakingAllocationFactor;

    Pool[] public pools;
    mapping(uint256 pid => mapping(address account => User)) public users;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Stake(address indexed user, uint256 amount);
    event Unstake(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event SetTreasury(address indexed treasury);
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

    modifier onlyAdmin() {
        if (!ACM.isAdmin(msg.sender)) revert Unauthorized();
        _;
    }

    /// @notice Initializes the WaveMaker contract
    /// @param acm Address of the Access Control Manager contract
    /// @param wave Address of the WAVE token contract
    /// @param _treasury Address where treasury rewards will be sent
    /// @param _wavePerBlock Number of WAVE tokens minted per block
    /// @param startBlock Block number from which reward distribution starts
    constructor(address acm, address wave, address _treasury, uint256 _wavePerBlock, uint256 startBlock) {
        if (acm == address(0)) revert ZeroAddress();
        if (wave == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_wavePerBlock == 0) revert ZeroAmount();
        ACM = IACM(acm);
        WAVE = IWAVE(wave);
        treasury = _treasury;
        wavePerBlock = _wavePerBlock;

        pools.push(Pool({
            token: IERC20(wave),
            accWavePerShare: 0,
            lastRewardBlock: uint32(startBlock),
            allocation: 1000,
            multiplier: 10000
        }));

        totalAllocations = 1000;
        stakingAllocationFactor = 3000; // 30% of the total allocation
    }

    /// @notice Returns the total number of incentivized pools
    /// @return Number of pools
    function poolsLength() external view returns (uint256) {
        return pools.length;
    }

    /// @notice Calculates pending reward tokens for a user in a specific pool
    /// @param pid Pool ID
    /// @param account User address
    /// @return Pending reward amount
    function pendingReward(uint256 pid, address account) external view returns (uint256) {
        Pool storage pool = pools[pid];
        User storage user = users[pid][account];
        uint32 currentBlock = uint32(block.number);
        uint256 accWavePerShare = pool.accWavePerShare;
        uint256 supply = pool.token.balanceOf(address(this));
        if (currentBlock > pool.lastRewardBlock && supply != 0) {
            uint256 multiplier = (pool.multiplier * _getDelta(pool.lastRewardBlock, currentBlock) / BPS);
            uint256 waveReward = (multiplier * pool.allocation) / totalAllocations;
            accWavePerShare += waveReward.wadDiv(supply);
        }
        return user.stakedAmount.wadMul(accWavePerShare) - user.rewardOffset;
    }

    /// @notice Returns the amount of tokens staked by a user in a specific pool
    /// @param pid Pool ID
    /// @param account User address
    /// @return Amount of staked tokens
    function getUserStakedAmount(uint256 pid, address account) external view returns (uint256) {
        return users[pid][account].stakedAmount;
    }

    /// @notice Updates reward variables of the given pool
    /// @param pid Pool ID to be synced
    function sync(uint256 pid) external {
        return _sync(pid);
    }

    /// @notice Updates reward variables for all pools
    function syncAll() external {
        return _syncAll();
    }

    /// @notice Deposits tokens to a specific pool for reward allocation
    /// @param pid Pool ID
    /// @param amount Token amount to deposit
    function deposit(uint256 pid, uint256 amount) external nonReentrant {
        if (pid == 0) revert InvalidParams();
        return _deposit(pid, amount);
    }

    /// @notice Withdraws tokens from a specific pool
    /// @param pid Pool ID
    /// @param amount Token amount to withdraw
    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        if (pid == 0) revert InvalidParams();
        return _withdraw(pid, amount);
    }

    /// @notice Stakes WAVE tokens in pool 0
    /// @param amount Amount of WAVE tokens to stake
    function stake(uint256 amount) external nonReentrant {
        return _deposit(0, amount);
    }

    /// @notice Unstakes WAVE tokens from pool 0
    /// @param amount Amount of WAVE tokens to unstake
    function unstake(uint256 amount) external nonReentrant {
        return _withdraw(0, amount);
    }

    /// @notice Updates the staking allocation factor
    /// @param _stakingAllocationFactor New staking allocation factor in BPS
    function setStakingAllocationFactor(uint256 _stakingAllocationFactor) external onlyAdmin {
        if (_stakingAllocationFactor > BPS) revert InvalidParams();
        stakingAllocationFactor = _stakingAllocationFactor;
        emit SetStakingAllocationFactor(_stakingAllocationFactor);
    }

    /// @notice Adds a new staking pool
    /// @param token Token to be staked in the pool
    /// @param allocation Pool's share of reward distribution
    /// @param multiplier Reward multiplier for the pool
    /// @param startBlock Block number from which rewards start accumulating
    /// @dev WARNING: This contract only supports LP Token with standard 18 decimals
    function addPool(IERC20 token, uint16 allocation, uint16 multiplier, uint32 startBlock) external onlyAdmin {
        if (address(token) == address(0)) revert ZeroAddress();
        if (allocation == 0) revert ZeroAmount();
        if (multiplier == 0) revert ZeroAmount();
        _syncAll();
        totalAllocations += allocation;
        pools.push(Pool({
            token: token,
            accWavePerShare: 0,
            lastRewardBlock: startBlock,
            allocation: allocation,
            multiplier: multiplier
        }));
        emit AddPool(pools.length - 1, token, allocation, multiplier);
        _syncStakingAllocation();
    }

    /// @notice Updates pool's reward multiplier
    /// @param pid Pool ID
    /// @param multiplier New reward multiplier
    function updatePoolMultiplier(uint256 pid, uint16 multiplier) external onlyAdmin {
        if (multiplier == 0) revert InvalidParams();
        if (multiplier > type(uint16).max) revert InvalidParams();
        _syncAll();
        Pool storage pool = pools[pid];
        pool.multiplier = multiplier;
        emit UpdatePool(pid, pool.token, pool.allocation, pool.multiplier);
    }

    /// @notice Updates pool's allocation points
    /// @param pid Pool ID
    /// @param allocation New allocation points
    /// @dev This function will update the total allocation points and adjust WAVE staking pool's allocation
    function updatePoolAllocation(uint256 pid, uint16 allocation) external onlyAdmin {
        if (allocation == 0) revert InvalidParams();
        _syncAll();
        Pool storage pool = pools[pid];
        totalAllocations = totalAllocations - pool.allocation + allocation;
        pool.allocation = allocation;
        emit UpdatePool(pid, pool.token, pool.allocation, pool.multiplier);
        _syncStakingAllocation();
    }

    /// @notice Sets the WAVE tokens minted per block
    /// @param _wavePerBlock New WAVE per block value
    function setWavePerBlock(uint256 _wavePerBlock) external onlyAdmin {
        if (_wavePerBlock == 0) revert ZeroAmount();
        wavePerBlock = _wavePerBlock;
        emit SetWavePerBlock(_wavePerBlock);
    }

    /// @notice Updates the treasury address
    /// @param _treasury New treasury address
    function setTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit SetTreasury(_treasury);
    }

    /// @notice Allows emergency withdrawal without caring about rewards
    /// @notice WARNING: Only use this function if you are sure that the contract is not working properly
    /// @param pid Pool ID
    function emergencyWithdraw(uint256 pid) external nonReentrant {
        Pool storage pool = pools[pid];
        User storage user = users[pid][msg.sender];
        uint256 amount = user.stakedAmount;
        user.stakedAmount = 0;
        user.rewardOffset = 0;
        pool.token.transfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount);
    }

    /// @notice Allows admin to retrieve accidentally sent tokens
    /// @param token Address of the token to retrieve
    function retrieveTokens(address token) external onlyAdmin {
        IERC20(token).transfer(treasury, IERC20(token).balanceOf(address(this)));
    }

    /// @notice Calculates the block reward multiplier
    /// @param lastRewardBlock Last block when rewards were distributed
    /// @param currentBlock Current block number
    /// @return Delta between current and last reward block multiplied by wave per block
    function _getDelta(uint32 lastRewardBlock, uint32 currentBlock) internal view returns (uint256) {
        if (currentBlock <= lastRewardBlock) return 0;
        return (currentBlock - lastRewardBlock) * wavePerBlock;
    }

    /// @notice Updates reward variables for a specific pool
    /// @param pid Pool ID to sync
    function _sync(uint256 pid) internal {
        Pool storage pool = pools[pid];
        uint32 lastRewardBlock = pool.lastRewardBlock;
        uint32 currentBlock = uint32(block.number);
        if (currentBlock <= lastRewardBlock) return;
        uint256 supply = pool.token.balanceOf(address(this));
        if (supply == 0) {
            pool.lastRewardBlock = uint32(currentBlock);
            return;
        }
        uint256 multiplier = (pool.multiplier * _getDelta(pool.lastRewardBlock, currentBlock) / BPS);
        uint256 waveReward = (multiplier * pool.allocation) / totalAllocations;
        WAVE.mint(treasury, waveReward / 10);
        pool.accWavePerShare += waveReward.wadDiv(supply);
        pool.lastRewardBlock = uint32(currentBlock);
        emit PoolSynced(pid, pool.accWavePerShare, pool.lastRewardBlock);
    }

    /// @notice Updates reward variables for all pools
    function _syncAll() internal {
        uint256 length = pools.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _sync(pid);
        }
    }

    /// @notice Updates the staking pool allocation based on other pools
    function _syncStakingAllocation() internal {
        uint256 length = pools.length;
        uint256 allocations = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            allocations += pools[pid].allocation;
        }
        if (allocations != 0) {
            allocations = allocations * stakingAllocationFactor / BPS;
            if (allocations > BPS) allocations = BPS;
            totalAllocations = totalAllocations - pools[0].allocation + uint16(allocations);
            pools[0].allocation = uint16(allocations);
            emit UpdatePool(0, pools[0].token, pools[0].allocation, pools[0].multiplier);
        }
    }

    /// @notice Handles the deposit logic for both staking and pool deposits
    /// @param pid Pool ID
    /// @param amount Amount to deposit
    /// @dev Emit events based on the pool ID
    function _deposit(uint256 pid, uint256 amount) internal {
        _sync(pid);
        Pool storage pool = pools[pid];
        User storage user = users[pid][msg.sender];
        if (user.stakedAmount > 0) {
            uint256 pending = user.stakedAmount.wadMul(pool.accWavePerShare) - user.rewardOffset;
            if (pending > 0) {
                WAVE.mint(msg.sender, pending);
                emit Harvest(msg.sender, pid, pending);
            }
        }
        if (amount > 0) {
            pool.token.transferFrom(msg.sender, address(this), amount);
            user.stakedAmount += amount;
            if (pid == 0) {
                emit Stake(msg.sender, amount);
            } else {
                emit Deposit(msg.sender, pid, amount);
            }
        }
        user.rewardOffset = user.stakedAmount.wadMul(pool.accWavePerShare);
    }

    /// @notice Handles the withdrawal logic for both staking and pool withdrawals
    /// @param pid Pool ID
    /// @param amount Amount to withdraw
    /// @dev Emit events based on the pool ID
    function _withdraw(uint256 pid, uint256 amount) internal {
        Pool storage pool = pools[pid];
        User storage user = users[pid][msg.sender];
        if (user.stakedAmount < amount) revert InsufficientBalance();

        _sync(pid);
        uint256 pending = (user.stakedAmount.wadMul(pool.accWavePerShare)) - user.rewardOffset;
        if (pending > 0) {
            WAVE.mint(msg.sender, pending);
            emit Harvest(msg.sender, pid, pending);
        }
        if (amount > 0) {
            user.stakedAmount -= amount;
            pool.token.transfer(msg.sender, amount);
            if (pid == 0) {
                emit Unstake(msg.sender, amount);
            } else {
                emit Withdraw(msg.sender, pid, amount);
            }
        }
        user.rewardOffset = user.stakedAmount.wadMul(pool.accWavePerShare);
    }
}