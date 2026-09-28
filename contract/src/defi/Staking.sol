// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Staking
 * @notice Staking contract for FROZ tokens with multiple pool types
 * @dev Supports flexible staking, locked staking, and LP token staking
 */
contract Staking is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");
    
    /// @notice Pool types
    enum PoolType { Flexible, Locked, LP }
    
    /// @notice Pool configuration
    struct Pool {
        address stakeToken;         // Token to stake (FROZ or LP token)
        uint256 rewardRate;         // Rewards per second (in wei)
        uint256 lockDuration;       // Lock period in seconds (0 for flexible)
        uint256 totalStaked;        // Total tokens staked in pool
        uint256 rewardPerTokenStored;
        uint256 lastUpdateTime;
        bool active;
        PoolType poolType;
    }
    
    /// @notice User stake info
    struct UserStake {
        uint256 amount;
        uint256 rewardPerTokenPaid;
        uint256 rewards;            // Pending rewards
        uint256 lockEndTime;        // 0 for flexible pools
        uint256 lastStakeTime;
    }
    
    /// @notice FROZ token (for rewards)
    IERC20 public immutable frozToken;
    
    /// @notice Total rewards distributed
    uint256 public totalRewardsDistributed;
    
    /// @notice Next pool ID
    uint256 public nextPoolId = 1;
    
    /// @notice Mapping from pool ID to Pool
    mapping(uint256 => Pool) public pools;
    
    /// @notice Mapping from pool ID => user => stake info
    mapping(uint256 => mapping(address => UserStake)) public userStakes;
    
    /// @notice Total FROZ staked across all pools (for voting power)
    mapping(address => uint256) public totalUserStake;
    
    /// @notice Events
    event PoolCreated(
        uint256 indexed poolId,
        address stakeToken,
        PoolType poolType,
        uint256 rewardRate,
        uint256 lockDuration
    );
    
    event Staked(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount,
        uint256 lockEndTime
    );
    
    event Unstaked(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount
    );
    
    event RewardsClaimed(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount
    );
    
    event RewardsAdded(
        uint256 indexed poolId,
        uint256 amount
    );
    
    event EmergencyWithdraw(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount
    );
    
    constructor(
        address _frozToken,
        address _admin
    ) {
        require(_frozToken != address(0), "Invalid FROZ");
        require(_admin != address(0), "Invalid admin");
        
        frozToken = IERC20(_frozToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(REWARD_DISTRIBUTOR_ROLE, _admin);
        
        // Create default pools
        _createDefaultPools();
    }
    
    // ============ Pool Management ============
    
    /**
     * @notice Create a new staking pool (only admin)
     * @param stakeToken Token to stake
     * @param rewardRate Rewards per second
     * @param lockDuration Lock period (0 for flexible)
     * @param poolType Pool type
     */
    function createPool(
        address stakeToken,
        uint256 rewardRate,
        uint256 lockDuration,
        PoolType poolType
    ) external onlyRole(OPERATOR_ROLE) returns (uint256) {
        require(stakeToken != address(0), "Invalid token");
        
        uint256 poolId = nextPoolId++;
        
        pools[poolId] = Pool({
            stakeToken: stakeToken,
            rewardRate: rewardRate,
            lockDuration: lockDuration,
            totalStaked: 0,
            rewardPerTokenStored: 0,
            lastUpdateTime: block.timestamp,
            active: true,
            poolType: poolType
        });
        
        emit PoolCreated(poolId, stakeToken, poolType, rewardRate, lockDuration);
        
        return poolId;
    }
    
    /**
     * @notice Update pool reward rate (only admin)
     */
    function updateRewardRate(uint256 poolId, uint256 newRate) external onlyRole(OPERATOR_ROLE) {
        require(pools[poolId].active, "Pool not active");
        _updateReward(poolId, address(0));
        pools[poolId].rewardRate = newRate;
    }
    
    /**
     * @notice Pause/unpause a pool
     */
    function setPoolActive(uint256 poolId, bool active) external onlyRole(OPERATOR_ROLE) {
        pools[poolId].active = active;
    }
    
    // ============ Staking Functions ============
    
    /**
     * @notice Stake tokens in a pool
     * @param poolId Pool ID
     * @param amount Amount to stake
     */
    function stake(uint256 poolId, uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Cannot stake 0");
        
        Pool storage pool = pools[poolId];
        require(pool.active, "Pool not active");
        
        _updateReward(poolId, msg.sender);
        
        // Transfer tokens
        IERC20(pool.stakeToken).safeTransferFrom(msg.sender, address(this), amount);
        
        UserStake storage userStake = userStakes[poolId][msg.sender];
        userStake.amount += amount;
        userStake.lastStakeTime = block.timestamp;
        
        // Set lock end time for locked pools
        if (pool.lockDuration > 0) {
            uint256 newLockEnd = block.timestamp + pool.lockDuration;
            // Extend lock if new stake
            if (newLockEnd > userStake.lockEndTime) {
                userStake.lockEndTime = newLockEnd;
            }
        }
        
        pool.totalStaked += amount;
        
        // Track total FROZ stake for voting
        if (pool.stakeToken == address(frozToken)) {
            totalUserStake[msg.sender] += amount;
        }
        
        emit Staked(poolId, msg.sender, amount, userStake.lockEndTime);
    }
    
    /**
     * @notice Unstake tokens from a pool
     * @param poolId Pool ID
     * @param amount Amount to unstake
     */
    function unstake(uint256 poolId, uint256 amount) external nonReentrant {
        require(amount > 0, "Cannot unstake 0");
        
        Pool storage pool = pools[poolId];
        UserStake storage userStake = userStakes[poolId][msg.sender];
        
        require(userStake.amount >= amount, "Insufficient stake");
        
        // Check lock
        if (pool.lockDuration > 0) {
            require(block.timestamp >= userStake.lockEndTime, "Still locked");
        }
        
        _updateReward(poolId, msg.sender);
        
        userStake.amount -= amount;
        pool.totalStaked -= amount;
        
        // Track total FROZ stake
        if (pool.stakeToken == address(frozToken)) {
            totalUserStake[msg.sender] -= amount;
        }
        
        // Transfer tokens back
        IERC20(pool.stakeToken).safeTransfer(msg.sender, amount);
        
        emit Unstaked(poolId, msg.sender, amount);
    }
    
    /**
     * @notice Claim pending rewards
     * @param poolId Pool ID
     */
    function claimRewards(uint256 poolId) external nonReentrant {
        _updateReward(poolId, msg.sender);
        
        UserStake storage userStake = userStakes[poolId][msg.sender];
        uint256 reward = userStake.rewards;
        
        if (reward > 0) {
            userStake.rewards = 0;
            totalRewardsDistributed += reward;
            frozToken.safeTransfer(msg.sender, reward);
            
            emit RewardsClaimed(poolId, msg.sender, reward);
        }
    }
    
    /**
     * @notice Claim rewards from multiple pools
     * @param poolIds Array of pool IDs
     */
    function claimAllRewards(uint256[] calldata poolIds) external nonReentrant {
        uint256 totalReward;
        
        for (uint256 i = 0; i < poolIds.length; i++) {
            _updateReward(poolIds[i], msg.sender);
            
            UserStake storage userStake = userStakes[poolIds[i]][msg.sender];
            uint256 reward = userStake.rewards;
            
            if (reward > 0) {
                userStake.rewards = 0;
                totalReward += reward;
                emit RewardsClaimed(poolIds[i], msg.sender, reward);
            }
        }
        
        if (totalReward > 0) {
            totalRewardsDistributed += totalReward;
            frozToken.safeTransfer(msg.sender, totalReward);
        }
    }
    
    /**
     * @notice Emergency withdraw without rewards (forfeit rewards)
     * @param poolId Pool ID
     */
    function emergencyWithdraw(uint256 poolId) external nonReentrant {
        Pool storage pool = pools[poolId];
        UserStake storage userStake = userStakes[poolId][msg.sender];
        
        uint256 amount = userStake.amount;
        require(amount > 0, "Nothing to withdraw");
        
        // Clear user stake
        userStake.amount = 0;
        userStake.rewards = 0;
        userStake.rewardPerTokenPaid = 0;
        
        pool.totalStaked -= amount;
        
        if (pool.stakeToken == address(frozToken)) {
            totalUserStake[msg.sender] -= amount;
        }
        
        IERC20(pool.stakeToken).safeTransfer(msg.sender, amount);
        
        emit EmergencyWithdraw(poolId, msg.sender, amount);
    }
    
    /**
     * @notice Add rewards to a pool (from marketplace fees, etc.)
     * @param poolId Pool ID
     * @param amount Amount of FROZ to add
     */
    function addRewards(uint256 poolId, uint256 amount) external onlyRole(REWARD_DISTRIBUTOR_ROLE) {
        require(pools[poolId].active, "Pool not active");
        frozToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsAdded(poolId, amount);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get pending rewards for a user in a pool
     */
    function pendingRewards(uint256 poolId, address user) external view returns (uint256) {
        Pool storage pool = pools[poolId];
        UserStake storage userStake = userStakes[poolId][user];
        
        uint256 rewardPerToken = pool.rewardPerTokenStored;
        
        if (pool.totalStaked > 0) {
            rewardPerToken += (
                (block.timestamp - pool.lastUpdateTime) * pool.rewardRate * 1e18
            ) / pool.totalStaked;
        }
        
        return userStake.rewards + (
            userStake.amount * (rewardPerToken - userStake.rewardPerTokenPaid)
        ) / 1e18;
    }
    
    /**
     * @notice Get user's stake info in a pool
     */
    function getUserStake(uint256 poolId, address user) external view returns (
        uint256 amount,
        uint256 lockEndTime,
        uint256 pendingReward,
        bool isLocked
    ) {
        UserStake storage userStake = userStakes[poolId][user];
        Pool storage pool = pools[poolId];
        
        uint256 rewardPerToken = pool.rewardPerTokenStored;
        if (pool.totalStaked > 0) {
            rewardPerToken += (
                (block.timestamp - pool.lastUpdateTime) * pool.rewardRate * 1e18
            ) / pool.totalStaked;
        }
        
        uint256 pending = userStake.rewards + (
            userStake.amount * (rewardPerToken - userStake.rewardPerTokenPaid)
        ) / 1e18;
        
        return (
            userStake.amount,
            userStake.lockEndTime,
            pending,
            pool.lockDuration > 0 && block.timestamp < userStake.lockEndTime
        );
    }
    
    /**
     * @notice Get pool info
     */
    function getPoolInfo(uint256 poolId) external view returns (
        address stakeToken,
        uint256 rewardRate,
        uint256 totalStaked,
        uint256 lockDuration,
        bool active,
        PoolType poolType
    ) {
        Pool storage pool = pools[poolId];
        return (
            pool.stakeToken,
            pool.rewardRate,
            pool.totalStaked,
            pool.lockDuration,
            pool.active,
            pool.poolType
        );
    }
    
    /**
     * @notice Get voting power (total staked FROZ)
     */
    function getVotingPower(address user) external view returns (uint256) {
        return totalUserStake[user];
    }
    
    /**
     * @notice Calculate APY for a pool (simplified)
     */
    function calculateAPY(uint256 poolId) external view returns (uint256) {
        Pool storage pool = pools[poolId];
        if (pool.totalStaked == 0) return 0;
        
        // Annual rewards = rewardRate * seconds per year
        uint256 annualRewards = pool.rewardRate * 365 days;
        
        // APY = (annualRewards / totalStaked) * 100
        return (annualRewards * 10000) / pool.totalStaked; // Returns basis points
    }
    
    // ============ Internal Functions ============
    
    function _updateReward(uint256 poolId, address account) internal {
        Pool storage pool = pools[poolId];
        
        pool.rewardPerTokenStored = _rewardPerToken(poolId);
        pool.lastUpdateTime = block.timestamp;
        
        if (account != address(0)) {
            UserStake storage userStake = userStakes[poolId][account];
            userStake.rewards = _earned(poolId, account);
            userStake.rewardPerTokenPaid = pool.rewardPerTokenStored;
        }
    }
    
    function _rewardPerToken(uint256 poolId) internal view returns (uint256) {
        Pool storage pool = pools[poolId];
        
        if (pool.totalStaked == 0) {
            return pool.rewardPerTokenStored;
        }
        
        return pool.rewardPerTokenStored + (
            (block.timestamp - pool.lastUpdateTime) * pool.rewardRate * 1e18
        ) / pool.totalStaked;
    }
    
    function _earned(uint256 poolId, address account) internal view returns (uint256) {
        UserStake storage userStake = userStakes[poolId][account];
        
        return (
            userStake.amount * (_rewardPerToken(poolId) - userStake.rewardPerTokenPaid)
        ) / 1e18 + userStake.rewards;
    }
    
    function _createDefaultPools() internal {
        // Pool 1: Flexible FROZ staking (45% APY base)
        // rewardRate calculated: 45% APY on 10M staked = ~142 FROZ/second
        pools[nextPoolId++] = Pool({
            stakeToken: address(frozToken),
            rewardRate: 142 * 1e18,
            lockDuration: 0,
            totalStaked: 0,
            rewardPerTokenStored: 0,
            lastUpdateTime: block.timestamp,
            active: true,
            poolType: PoolType.Flexible
        });
        
        // Pool 2: 90-day locked FROZ (200% APY)
        pools[nextPoolId++] = Pool({
            stakeToken: address(frozToken),
            rewardRate: 634 * 1e18, // Higher rate for locked
            lockDuration: 90 days,
            totalStaked: 0,
            rewardPerTokenStored: 0,
            lastUpdateTime: block.timestamp,
            active: true,
            poolType: PoolType.Locked
        });
    }
    
    // ============ Admin Functions ============
    
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Recover accidentally sent tokens (not stake tokens)
     */
    function recoverTokens(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Prevent recovering stake tokens from active pools
        for (uint256 i = 1; i < nextPoolId; i++) {
            require(token != pools[i].stakeToken, "Cannot recover stake token");
        }
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
