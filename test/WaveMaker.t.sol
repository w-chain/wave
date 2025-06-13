// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Test } from "forge-std/Test.sol";
import { WaveMaker } from "../src/WaveMaker.sol";
import { IWaveMaker } from "../src/interfaces/IWaveMaker.sol";
import { WAVE } from "../src/Wave.sol";
import { ACM } from "../src/ACM.sol";
import { MockERC20 } from "../src/lib/MockERC20.sol";

contract WaveMakerTest is Test {
    WaveMaker public waveMaker;
    WAVE public wave;
    ACM public acm;
    MockERC20 public lpToken;

    address public admin;
    address public treasury;
    address public user1;
    address public user2;

    uint256 public constant WAVE_PER_BLOCK = 1e18;
    uint256 public constant INITIAL_MINT = 1000e18;
    uint32 public constant START_BLOCK = 100;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Stake(address indexed user, uint256 amount);
    event Unstake(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.startPrank(admin);
        
        // Deploy contracts
        acm = new ACM(admin);
        wave = new WAVE(address(acm));
        waveMaker = new WaveMaker(
            address(acm),
            address(wave),
            treasury,
            WAVE_PER_BLOCK,
            START_BLOCK
        );

        // Setup permissions
        acm.grantRole(keccak256("ADMIN_ROLE"), admin);
        acm.grantRole(keccak256("FACTORY_ROLE"), address(waveMaker));

        // Deploy mock LP token
        lpToken = new MockERC20("LP Token", "LP", 18);
        
        // Add LP token pool
        waveMaker.addPool(IERC20(address(lpToken)), 1000, 10000, START_BLOCK);

        vm.stopPrank();

        // Mint initial tokens
        deal(address(wave), user1, INITIAL_MINT);
        deal(address(wave), user2, INITIAL_MINT);
        deal(address(lpToken), user1, INITIAL_MINT);
        deal(address(lpToken), user2, INITIAL_MINT);
    }

    function test_InitialState() public {
        assertEq(waveMaker.wavePerBlock(), WAVE_PER_BLOCK);
        assertEq(waveMaker.treasury(), treasury);
        assertEq(waveMaker.poolsLength(), 2); // WAVE pool + LP pool
        assertEq(waveMaker.totalAllocations(), 1300); // 300 (WAVE) + 1000 (LP)
    }

    function test_StakeAndEarnRewards() public {
        vm.roll(START_BLOCK);
        uint256 stakeAmount = 100e18;
        vm.startPrank(user1);
        wave.approve(address(waveMaker), stakeAmount);
        waveMaker.stake(stakeAmount);

        vm.roll(START_BLOCK + 10);

        // Calculate expected rewards: 10 blocks * reward per block * WAVE pool allocation / total allocation
        uint256 expectedReward = 10 * WAVE_PER_BLOCK * 300 / 1300;
        uint256 pendingReward = waveMaker.pendingReward(0, user1);
        assertApproxEqRel(pendingReward, expectedReward, 0.01e18);

        uint256 balanceBefore = wave.balanceOf(user1);
        waveMaker.stake(0);
        uint256 balanceAfter = wave.balanceOf(user1);
        assertApproxEqRel(balanceAfter - balanceBefore, expectedReward, 0.01e18);
        vm.stopPrank();
    }

    function test_DepositAndEarnRewards() public {
        vm.roll(START_BLOCK);
        uint256 depositAmount = 100e18;
        vm.startPrank(user1);
        lpToken.approve(address(waveMaker), depositAmount);
        waveMaker.deposit(1, depositAmount);

        vm.roll(START_BLOCK + 10);

        // Calculate expected rewards: 10 blocks * reward per block * LP pool allocation / total allocation
        uint256 expectedReward = 10 * WAVE_PER_BLOCK * 1000 / 1300;
        uint256 pendingReward = waveMaker.pendingReward(1, user1);
        assertApproxEqRel(pendingReward, expectedReward, 0.01e18);

        uint256 balanceBefore = wave.balanceOf(user1);
        waveMaker.deposit(1, 0);
        uint256 balanceAfter = wave.balanceOf(user1);
        assertApproxEqRel(balanceAfter - balanceBefore, expectedReward, 0.01e18);
        vm.stopPrank();
    }

    function test_Withdraw() public {
        uint256 depositAmount = 100e18;
        vm.startPrank(user1);
        lpToken.approve(address(waveMaker), depositAmount);
        waveMaker.deposit(1, depositAmount);

        vm.expectEmit(true, true, false, true);
        emit Withdraw(user1, 1, depositAmount);
        waveMaker.withdraw(1, depositAmount);

        assertEq(waveMaker.getUserStakedAmount(1, user1), 0);
        assertEq(lpToken.balanceOf(user1), INITIAL_MINT);
        vm.stopPrank();
    }

    function test_EmergencyWithdraw() public {
        uint256 depositAmount = 100e18;
        vm.startPrank(user1);
        lpToken.approve(address(waveMaker), depositAmount);
        waveMaker.deposit(1, depositAmount);

        // Advance blocks and accumulate rewards
        vm.roll(block.number + 10);

        waveMaker.emergencyWithdraw(1);
        assertEq(waveMaker.getUserStakedAmount(1, user1), 0);
        assertEq(lpToken.balanceOf(user1), INITIAL_MINT);
        // Ensure no rewards were harvested
        assertEq(wave.balanceOf(user1), INITIAL_MINT);
        vm.stopPrank();
    }

    function test_UpdatePoolMultiplier() public {
        vm.startPrank(admin);
        uint16 newMultiplier = 20000;
        waveMaker.updatePoolMultiplier(1, newMultiplier);
        (,,,, uint16 multiplier) = waveMaker.pools(1);
        assertEq(multiplier, newMultiplier);
        vm.stopPrank();
    }

    function test_UpdatePoolAllocation() public {
        vm.startPrank(admin);
        uint16 newAllocation = 2000;
        waveMaker.updatePoolAllocation(1, newAllocation);
        (,,, uint16 allocation,) = waveMaker.pools(1);
        assertEq(allocation, newAllocation);
        vm.stopPrank();
    }

    function test_RevertWhenUnauthorized() public {
        vm.startPrank(user1);
        vm.expectRevert(IWaveMaker.Unauthorized.selector);
        waveMaker.updatePoolMultiplier(1, 20000);

        vm.expectRevert(IWaveMaker.Unauthorized.selector);
        waveMaker.updatePoolAllocation(1, 2000);

        vm.expectRevert(IWaveMaker.Unauthorized.selector);
        waveMaker.setWavePerBlock(2e18);
        vm.stopPrank();
    }

    function test_RevertOnInvalidParams() public {
        vm.startPrank(admin);
        vm.expectRevert(IWaveMaker.InvalidParams.selector);
        waveMaker.updatePoolMultiplier(1, 0);

        vm.expectRevert(IWaveMaker.InvalidParams.selector);
        waveMaker.updatePoolAllocation(1, 0);

        vm.expectRevert(IWaveMaker.ZeroAmount.selector);
        waveMaker.setWavePerBlock(0);
        vm.stopPrank();
    }

    function test_ExtremeStakeAmounts() public {
        vm.roll(START_BLOCK);
        vm.startPrank(user1);
        
        // Test minimum stake
        uint256 minStake = 1;
        wave.approve(address(waveMaker), minStake);
        waveMaker.stake(minStake);
        assertEq(waveMaker.getUserStakedAmount(0, user1), minStake);
        
        // Test maximum stake
        uint256 maxStake = type(uint128).max;
        deal(address(wave), user1, maxStake);
        wave.approve(address(waveMaker), maxStake);
        waveMaker.stake(maxStake);
        assertEq(waveMaker.getUserStakedAmount(0, user1), minStake + maxStake);
        
        vm.stopPrank();
    }

    function test_ExtremeLongStakingPeriod() public {
        vm.roll(START_BLOCK);
        uint256 stakeAmount = 100e18;
        vm.startPrank(user1);
        wave.approve(address(waveMaker), stakeAmount);
        waveMaker.stake(stakeAmount);

        // Advance 1 million blocks
        uint256 blocksPassed = 1_000_000;
        vm.roll(START_BLOCK + blocksPassed);

        uint256 expectedReward = blocksPassed * WAVE_PER_BLOCK * 300 / 1300;
        uint256 pendingReward = waveMaker.pendingReward(0, user1);
        assertApproxEqRel(pendingReward, expectedReward, 0.01e18);
        vm.stopPrank();
    }

    function test_MultipleUsersExtremePools() public {
        vm.roll(START_BLOCK);
        
        // User1 stakes maximum amount
        uint256 maxStake = type(uint128).max;
        deal(address(wave), user1, maxStake);
        vm.startPrank(user1);
        wave.approve(address(waveMaker), maxStake);
        waveMaker.stake(maxStake);
        vm.stopPrank();
        
        // User2 stakes minimum amount
        uint256 minStake = 1;
        vm.startPrank(user2);
        wave.approve(address(waveMaker), minStake);
        waveMaker.stake(minStake);
        vm.stopPrank();
        
        // Advance 1000 blocks
        vm.roll(START_BLOCK + 1000);
        
        // Verify rewards proportion matches stake proportion
        uint256 user1Reward = waveMaker.pendingReward(0, user1);
        uint256 user2Reward = waveMaker.pendingReward(0, user2);
        assertGt(user1Reward, user2Reward);
        
        // Verify user1's reward is significantly larger than user2's
        // due to the extreme difference in stakes
        assertTrue(user1Reward > user2Reward * 1000);
    }

    function test_ExtremeDepositAmounts() public {
        vm.roll(START_BLOCK);
        vm.startPrank(user1);
        
        // Test minimum deposit
        uint256 minDeposit = 1;
        deal(address(lpToken), user1, minDeposit);
        lpToken.approve(address(waveMaker), minDeposit);
        waveMaker.deposit(1, minDeposit);
        assertEq(waveMaker.getUserStakedAmount(1, user1), minDeposit);
        
        // Test maximum deposit
        uint256 maxDeposit = type(uint128).max;
        deal(address(lpToken), user1, maxDeposit);
        lpToken.approve(address(waveMaker), maxDeposit);
        waveMaker.deposit(1, maxDeposit);
        assertEq(waveMaker.getUserStakedAmount(1, user1), minDeposit + maxDeposit);
        
        vm.stopPrank();
    }
}