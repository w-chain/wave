// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import { IACM } from "./interfaces/IACM.sol";
import { IWAVE } from "./interfaces/IWAVE.sol";
import { IWaveMaker } from "./interfaces/IWaveMaker.sol";
import { IPAPeriphery } from "./interfaces/IPAPeriphery.sol";
import { IWETH } from "./interfaces/IWETH.sol";
import { WadRayMath } from "./lib/WadRayMath.sol";

/// @title WaveMaker - A staking and reward distribution contract
/// @notice This contract manages staking pools and WAVE token rewards distribution inspired by SushiSwap
/// @dev Implements staking mechanism with multiple pools and reward calculation using WAD RAY math
contract WaveMaker is IWaveMaker, Initializable, ReentrancyGuardUpgradeable {
    using WadRayMath for uint256;
    uint256 public constant BPS = 10000;

    IACM public ACM;
    IWAVE public WAVE;

    IPAPeriphery public paPeriphery;

    address public treasury;
    uint256 public wavePerBlock;
    uint256 public totalAllocations;
    uint256 public stakingAllocationFactor;

    Pool[] public pools;
    mapping(uint256 pid => mapping(address account => User)) public users;

    /// @dev Implementation v2 update
    /// @notice ETH pool ID - fixed at index 3
    uint256 public constant ETH_POOL_ID = 3;
    IWETH public WETH;

    modifier onlyAdmin() {
        if (!ACM.isAdmin(msg.sender)) revert Unauthorized();
        _;
    }

    /// @notice Receive function to handle ETH transfers 
    receive() external payable {}

    /// @notice Initializes the WaveMaker contract
    /// @param acm Address of the Access Control Manager contract
    /// @param wave Address of the WAVE token contract
    /// @param waveLp Address of the WAVE/WCO LP token contract
    /// @param _treasury Address where treasury rewards will be sent
    /// @param _wavePerBlock Number of WAVE tokens minted per block
    /// @param startBlock Block number from which reward distribution starts
    function initialize(address acm, address wave, address waveLp, address _treasury, uint256 _wavePerBlock, uint256 startBlock) external initializer {
        if (acm == address(0)) revert ZeroAddress();
        if (wave == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_wavePerBlock == 0) revert ZeroAmount();
        ACM = IACM(acm);
        WAVE = IWAVE(wave);
        treasury = _treasury;
        wavePerBlock = _wavePerBlock;

        pools.push(Pool({
            token: IERC20(waveLp),
            accWavePerShare: 0,
            lastRewardBlock: uint32(startBlock),
            allocation: 1000,
            multiplier: 10000
        }));

        totalAllocations = 1000;
        stakingAllocationFactor = 6667; // To get remainder as 40% of the total allocation
    }

    function version() external pure returns (uint256) {
        return 2;
    }


    /// @notice Initializes the ETH pool at index 3
    /// @param allocation Pool's share of reward distribution
    /// @param startBlock Block number from which rewards start accumulating
    /// @dev This function should only be called once to set up the ETH pool
    function initializeETHPool(address weth, uint16 allocation, uint32 startBlock) external reinitializer(2) {
        if (pools.length != ETH_POOL_ID) revert InvalidParams();
        if (allocation == 0) revert ZeroAmount();

        WETH = IWETH(weth);
        _syncAll();
        totalAllocations += allocation;
        pools.push(Pool({
            token: IERC20(weth),
            accWavePerShare: 0,
            lastRewardBlock: startBlock,
            allocation: allocation,
            multiplier: 10000
        }));    
        emit AddPool(ETH_POOL_ID, IERC20(weth), allocation, 10000);
        _syncStakingAllocation();
    }


    /// @notice Returns protocol information for frontend display
    /// @return Protocol information including total pools, allocations, and parameters
    function getProtocolInfo() external view returns (ProtocolInfo memory) {
        return ProtocolInfo({
            totalPools: pools.length,
            totalAllocations: totalAllocations,
            wavePerBlock: wavePerBlock,
            stakingAllocationFactor: stakingAllocationFactor
        });
    }

    /// @notice Returns information about all incentivized pools
    /// @return Array of pool information structures
    function getAllPoolsInfo() external view returns (PoolInfo[] memory) {
        uint256 length = pools.length;
        PoolInfo[] memory poolsInfo = new PoolInfo[](length);
        
        for (uint256 i = 0; i < length; i++) {
            Pool storage pool = pools[i];
            poolsInfo[i] = PoolInfo({
                pid: i,
                token: address(pool.token),
                allocation: pool.allocation,
                multiplier: pool.multiplier,
                totalStaked: pool.token.balanceOf(address(this)),
                accWavePerShare: pool.accWavePerShare,
                lastRewardBlock: pool.lastRewardBlock
            });
        }
        
        return poolsInfo;
    }

    /// @notice Returns comprehensive user information across all pools
    /// @param account User address to query
    /// @return Complete user information including staking and rewards data
    function getUserInfo(address account) external view returns (UserInfo memory) {
        uint256 length = pools.length;
        UserPoolInfo[] memory userPoolsInfo = new UserPoolInfo[](length);
        uint256 totalStaked = 0;
        uint256 totalPendingRewards = 0;
        uint256 activePoolsCount = 0;
        
        // First pass: collect data for pools where user has stake
        for (uint256 i = 0; i < length; i++) {
            User storage user = users[i][account];
            if (user.stakedAmount > 0) {
                uint256 pending = _calculatePendingReward(i, account);
                userPoolsInfo[activePoolsCount] = UserPoolInfo({
                    pid: i,
                    stakedAmount: user.stakedAmount,
                    pendingReward: pending
                });
                totalStaked += user.stakedAmount;
                totalPendingRewards += pending;
                activePoolsCount++;
            }
        }
        
        // Create properly sized array with only active pools
        UserPoolInfo[] memory activeUserPoolsInfo = new UserPoolInfo[](activePoolsCount);
        for (uint256 i = 0; i < activePoolsCount; i++) {
            activeUserPoolsInfo[i] = userPoolsInfo[i];
        }
        
        return UserInfo({
            totalStaked: totalStaked,
            totalPendingRewards: totalPendingRewards,
            personalMultiplier: _getPersonalMultiplier(account),
            poolsInfo: activeUserPoolsInfo
        });
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
        return _calculatePendingReward(pid, account);
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
        if (pid == 0 || pid == ETH_POOL_ID) revert InvalidParams();
        return _deposit(pid, amount);
    }

    /// @notice Withdraws tokens from a specific pool
    /// @param pid Pool ID
    /// @param amount Token amount to withdraw
    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        if (pid == 0 || pid == ETH_POOL_ID) revert InvalidParams();
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

    /// @notice Deposits ETH to the ETH pool (pool 3)
    /// @dev ETH is automatically wrapped to WETH
    function depositETH() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        return _depositETH(msg.value);
    }

    /// @notice Withdraws ETH from the ETH pool (pool 3)
    /// @param amount Amount of ETH to withdraw
    /// @dev WETH is automatically unwrapped to ETH
    function withdrawETH(uint256 amount) external nonReentrant {
        return _withdrawETH(amount);
    }

    /// @notice Harvests rewards for all staked pools
    function harvestAll() external nonReentrant {
        address account = msg.sender;
        uint256 length = pools.length;
        for (uint256 i = 0; i < length; i++) {
            User storage user = users[i][account];
            if (user.stakedAmount > 0) {
                uint256 pending = _calculatePendingReward(i, account);
                if (pending > 0) {
                    _deposit(i, 0);
                }
            }
        }
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
        if (pid >= pools.length) revert InvalidParams();
        if (multiplier == 0) revert InvalidParams();
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

    function setPAPeriphery(address _paPeriphery) external onlyAdmin {
        paPeriphery = IPAPeriphery(_paPeriphery);
        emit SetPAPeriphery(_paPeriphery);
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
        
        if (pid == ETH_POOL_ID) {
            // For ETH pool, unwrap WETH and send ETH
            WETH.withdraw(amount);
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) revert InvalidParams();
        } else {
            // For other pools, transfer tokens directly
            pool.token.transfer(msg.sender, amount);
        }
        
        emit EmergencyWithdraw(msg.sender, pid, amount);
    }

    /// @notice Allows admin to retrieve accidentally sent tokens
    /// @param token Address of the token to retrieve
    function retrieveTokens(address token) external onlyAdmin {
        // Check if token is in pools
        for (uint256 i = 0; i < pools.length; i++) {
            if (address(pools[i].token) == token) revert InvalidParams();
        }
        IERC20(token).transfer(treasury, IERC20(token).balanceOf(address(this)));
    }

    function retrieveETH() external onlyAdmin {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(treasury).transfer(balance);
        }
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
                uint256 harvest = pending.wadMul(_getPersonalMultiplier(msg.sender));
                WAVE.mint(msg.sender, harvest);
                emit Harvest(msg.sender, pid, harvest);
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
            uint256 harvest = pending.wadMul(_getPersonalMultiplier(msg.sender));
            WAVE.mint(msg.sender, harvest);
            emit Harvest(msg.sender, pid, harvest);
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

    function _getPersonalMultiplier(address account) internal view returns (uint256) {
        if (address(paPeriphery) == address(0)) return WadRayMath.WAD;
        return paPeriphery.getWAVEMultiplier(account);
    }

    /// @notice Internal function to handle ETH deposits
    /// @param amount Amount of ETH to deposit
    function _depositETH(uint256 amount) internal {
        // Wrap ETH to WETH
        WETH.deposit{value: amount}();
        
        // Use the standard deposit logic for the ETH pool
        _sync(ETH_POOL_ID);
        Pool storage pool = pools[ETH_POOL_ID];
        User storage user = users[ETH_POOL_ID][msg.sender];
        
        if (user.stakedAmount > 0) {
            uint256 pending = user.stakedAmount.wadMul(pool.accWavePerShare) - user.rewardOffset;
            if (pending > 0) {
                uint256 harvest = pending.wadMul(_getPersonalMultiplier(msg.sender));
                WAVE.mint(msg.sender, harvest);
                emit Harvest(msg.sender, ETH_POOL_ID, harvest);
            }
        }
        
        user.stakedAmount += amount;
        user.rewardOffset = user.stakedAmount.wadMul(pool.accWavePerShare);
        
        emit DepositETH(msg.sender, amount);
    }

    /// @notice Internal function to handle ETH withdrawals
    /// @param amount Amount of ETH to withdraw
    function _withdrawETH(uint256 amount) internal {
        Pool storage pool = pools[ETH_POOL_ID];
        User storage user = users[ETH_POOL_ID][msg.sender];
        if (user.stakedAmount < amount) revert InsufficientBalance();

        _sync(ETH_POOL_ID);
        uint256 pending = (user.stakedAmount.wadMul(pool.accWavePerShare)) - user.rewardOffset;
        if (pending > 0) {
            uint256 harvest = pending.wadMul(_getPersonalMultiplier(msg.sender));
            WAVE.mint(msg.sender, harvest);
            emit Harvest(msg.sender, ETH_POOL_ID, harvest);
        }
        
        if (amount > 0) {
            user.stakedAmount -= amount;
            // Unwrap WETH to ETH and send to user
            WETH.withdraw(amount);
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            if (!success) revert InvalidParams();
            emit WithdrawETH(msg.sender, amount);
        }
        
        user.rewardOffset = user.stakedAmount.wadMul(pool.accWavePerShare);
    }

    /// @notice Internal function to calculate pending rewards for a user in a specific pool
    /// @param pid Pool ID
    /// @param account User address
    /// @return Pending reward amount
    function _calculatePendingReward(uint256 pid, address account) internal view returns (uint256) {
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
        
        uint256 baseReward = user.stakedAmount.wadMul(accWavePerShare) - user.rewardOffset;
        uint256 personalMultiplier = _getPersonalMultiplier(account);
        return baseReward.wadMul(personalMultiplier);
    }
}