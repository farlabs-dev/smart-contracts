// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title FARStakingEmission
 * @author Farcana Team
 * @notice Emission-based staking contract for FAR token with dynamic lock multipliers
 * @dev Supports multiple staking positions per user with customizable lock periods and multipliers
 */
contract FARStakingEmission is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @dev Structure representing a single staking position
     * @param amount Amount of tokens staked in this position
     * @param unlockTime Timestamp when tokens can be withdrawn
     * @param lockMultiplier Multiplier based on lock duration (stored as 1e18 = 1.0x)
     * @param lastRewardTime Last time rewards were calculated for this position
     * @param rewardDebt Accumulated reward debt for accurate reward calculation
     * @param accRewardPerWeightPaid Checkpoint of global accumulator at last update
     */
    struct StakingPosition {
        uint256 amount;
        uint256 unlockTime;
        uint256 lockMultiplier;
        uint256 lastRewardTime;
        uint256 rewardDebt;
        uint256 accRewardPerWeightPaid;
    }

    /**
     * @dev Structure for lock configuration parameters
     * @param minLockDays Minimum lock period in days
     * @param maxLockDays Maximum lock period in days
     * @param minMultiplier Minimum multiplier for min lock period (1e18 = 1.0x)
     * @param maxMultiplier Maximum multiplier for max lock period (1e18 = 1.0x)
     */
    struct LockConfig {
        uint256 minLockDays;
        uint256 maxLockDays;
        uint256 minMultiplier;
        uint256 maxMultiplier;
    }

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice FAR token contract address
    IERC20 public immutable farToken;

    /// @notice Emission rate in FAR tokens per second (scaled by 1e18)
    uint256 public emissionPerSecond;

    /// @notice Lock configuration parameters
    LockConfig public lockConfig;

    /// @notice Mapping from user address to their staking positions array
    mapping(address => StakingPosition[]) public userPositions;

    /// @notice Personal multiplier for each user (1e18 = 1.0x, default 1e18)
    mapping(address => uint256) public personalMultiplier;

    /// @notice Total staking weight across all positions
    uint256 public totalStakingWeight;

    /// @notice Total tokens staked in the contract
    uint256 public totalStaked;

    /// @notice Total rewards claimed by all users
    uint256 public totalRewardsClaimed;

    /// @notice Rewards claimed per user
    mapping(address => uint256) public userClaimedRewards;

    /// @notice List of all stakers
    address[] private stakers;

    /// @notice Mapping to check if address is already a staker
    mapping(address => bool) private isStaker;

    /// @notice Accumulated rewards per weight unit (scaled by 1e18)
    uint256 public accRewardPerWeight;

    /// @notice Last time global rewards were updated
    uint256 public lastGlobalUpdateTime;

    /// @notice Precision multiplier for calculations
    uint256 private constant PRECISION = 1e18;

    /// @notice Seconds in a day
    uint256 private constant SECONDS_PER_DAY = 86400;

    /// @notice Minimum deposit amount in FAR tokens (with 18 decimals)
    uint256 public minDepositAmount;

    // ============================================
    // EVENTS
    // ============================================

    event PositionCreated(
        address indexed user,
        uint256 indexed positionId,
        uint256 amount,
        uint256 unlockTime,
        uint256 lockMultiplier
    );

    event Withdrawn(
        address indexed user,
        uint256 indexed positionId,
        uint256 amount
    );

    event LockExtended(
        address indexed user,
        uint256 indexed positionId,
        uint256 newUnlockTime,
        uint256 newLockMultiplier
    );

    event RewardsClaimed(
        address indexed user,
        uint256 indexed positionId,
        uint256 amount
    );

    event EmissionRateUpdated(uint256 oldRate, uint256 newRate);

    event LockParametersUpdated(
        uint256 minLockDays,
        uint256 maxLockDays,
        uint256 minMultiplier,
        uint256 maxMultiplier
    );

    event PersonalMultiplierSet(address indexed user, uint256 multiplier);

    event RewardTokensDeposited(uint256 amount);

    event MinDepositAmountUpdated(uint256 oldAmount, uint256 newAmount);

    // ============================================
    // ERRORS
    // ============================================

    error ZeroAmount();
    error InvalidUnlockTime();
    error LockDurationTooShort();
    error LockDurationTooLong();
    error InvalidPositionId();
    error TokensStillLocked();
    error InsufficientStakedAmount();
    error InvalidLockExtension();
    error InvalidMultiplier();
    error InvalidLockParameters();
    error NoRewardsToClaim();
    error InsufficientRewardBalance();
    error DepositBelowMinimum();

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(
        address _farToken,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_farToken != address(0), "Invalid token address");
        
        farToken = IERC20(_farToken);
        
        // Set default lock configuration
        // 5 days min = 1.0x, 180 days max = 2.0x
        lockConfig = LockConfig({
            minLockDays: 5,
            maxLockDays: 180,
            minMultiplier: 1e18,  // 1.0x
            maxMultiplier: 2e18   // 2.0x
        });
        
        // Set default emission rate (50,000 FAR per day)
        emissionPerSecond = (50000 * PRECISION) / SECONDS_PER_DAY;

        // Set default minimum deposit (1000 FAR tokens)
        minDepositAmount = 1000 * PRECISION;

        lastGlobalUpdateTime = block.timestamp;
    }

    // ============================================
    // USER FUNCTIONS
    // ============================================

    /**
     * @notice Creates a new staking position
     * @param amount Amount of tokens to stake
     * @param unlockTime Timestamp when tokens can be withdrawn
     */
    function createPosition(
        uint256 amount,
        uint256 unlockTime
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount < minDepositAmount) revert DepositBelowMinimum();
        if (unlockTime <= block.timestamp) revert InvalidUnlockTime();

        // Calculate lock duration
        uint256 lockDuration = unlockTime - block.timestamp;

        // Validate lock duration in SECONDS to avoid rounding issues
        uint256 minLockSeconds = lockConfig.minLockDays * SECONDS_PER_DAY;
        uint256 maxLockSeconds = lockConfig.maxLockDays * SECONDS_PER_DAY;

        if (lockDuration < minLockSeconds) revert LockDurationTooShort();
        if (lockDuration > maxLockSeconds) revert LockDurationTooLong();

        // Calculate lock days for multiplier calculation
        uint256 lockDays = lockDuration / SECONDS_PER_DAY;

        // Calculate lock multiplier
        uint256 lockMultiplier;
        if (lockDays >= lockConfig.maxLockDays) {
            lockMultiplier = lockConfig.maxMultiplier;
        } else {
            lockMultiplier = _calculateLockMultiplier(lockDays);
        }

        // Update global rewards before creating position
        _updateGlobalRewards();

        // Track new staker if first position
        if (!isStaker[msg.sender]) {
            stakers.push(msg.sender);
            isStaker[msg.sender] = true;
        }

        // Create new position with checkpoint initialized
        StakingPosition memory newPosition = StakingPosition({
            amount: amount,
            unlockTime: unlockTime,
            lockMultiplier: lockMultiplier,
            lastRewardTime: block.timestamp,
            rewardDebt: 0,
            accRewardPerWeightPaid: accRewardPerWeight
        });

        // Get position ID
        uint256 positionId = userPositions[msg.sender].length;
        userPositions[msg.sender].push(newPosition);

        // Calculate position weight
        uint256 positionWeight = _calculatePositionWeight(msg.sender, amount, lockMultiplier);

        // Update global state
        totalStakingWeight += positionWeight;
        totalStaked += amount;

        // Transfer tokens from user
        farToken.safeTransferFrom(msg.sender, address(this), amount);

        emit PositionCreated(
            msg.sender,
            positionId,
            amount,
            unlockTime,
            lockMultiplier
        );
    }

    /**
     * @notice Extends the lock period of an existing position
     * @param positionId ID of the position to extend
     * @param newUnlockTime New unlock timestamp (must be greater than current)
     */
    function extendLock(
        uint256 positionId,
        uint256 newUnlockTime
    ) external nonReentrant whenNotPaused {
        StakingPosition storage position = _getPosition(msg.sender, positionId);

        if (newUnlockTime <= position.unlockTime) revert InvalidLockExtension();

        // Calculate new lock duration
        uint256 newLockDuration = newUnlockTime - block.timestamp;

        // Validate lock duration in SECONDS to avoid rounding issues
        uint256 minLockSeconds = lockConfig.minLockDays * SECONDS_PER_DAY;
        uint256 maxLockSeconds = lockConfig.maxLockDays * SECONDS_PER_DAY;

        if (newLockDuration < minLockSeconds) revert LockDurationTooShort();
        if (newLockDuration > maxLockSeconds) revert LockDurationTooLong();

        // Calculate lock days for multiplier calculation
        uint256 newLockDays = newLockDuration / SECONDS_PER_DAY;

        // Calculate lock multiplier
        uint256 newLockMultiplier;
        if (newLockDays >= lockConfig.maxLockDays) {
            newLockMultiplier = lockConfig.maxMultiplier;
        } else {
            newLockMultiplier = _calculateLockMultiplier(newLockDays);
        }

        // Update global and position rewards before changing weight
        _updateGlobalRewards();
        _updatePositionRewards(msg.sender, positionId);

        // Calculate old and new weights
        uint256 oldWeight = _calculatePositionWeight(
            msg.sender,
            position.amount,
            position.lockMultiplier
        );

        uint256 newWeight = _calculatePositionWeight(
            msg.sender,
            position.amount,
            newLockMultiplier
        );

        // Update position
        position.unlockTime = newUnlockTime;
        position.lockMultiplier = newLockMultiplier;

        // Update global weight
        totalStakingWeight = totalStakingWeight - oldWeight + newWeight;

        emit LockExtended(
            msg.sender,
            positionId,
            newUnlockTime,
            newLockMultiplier
        );
    }

    /**
     * @notice Withdraws tokens from a position (partial or full)
     * @param positionId ID of the position to withdraw from
     * @param amount Amount of tokens to withdraw
     */
    function withdraw(
        uint256 positionId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        StakingPosition storage position = _getPosition(msg.sender, positionId);

        if (block.timestamp < position.unlockTime) revert TokensStillLocked();
        if (amount > position.amount) revert InsufficientStakedAmount();

        // Update global and position rewards
        _updateGlobalRewards();
        _updatePositionRewards(msg.sender, positionId);

        // Try to claim pending rewards if available, but don't block principal withdrawal
        uint256 pendingRewards = position.rewardDebt;
        if (pendingRewards > 0) {
            // Check if sufficient rewards are available
            uint256 contractBalance = farToken.balanceOf(address(this));
            uint256 availableRewards = contractBalance > totalStaked
                ? contractBalance - totalStaked
                : 0;

            // Only claim if sufficient rewards available
            if (availableRewards >= pendingRewards) {
                _claimRewards(msg.sender, positionId, pendingRewards);
            }
            // If insufficient rewards, keep rewardDebt for later claim
        }

        // Calculate weight to remove
        uint256 weightToRemove = _calculatePositionWeight(
            msg.sender,
            amount,
            position.lockMultiplier
        );

        // Update position
        position.amount -= amount;

        // Update global state
        totalStakingWeight -= weightToRemove;
        totalStaked -= amount;

        // Transfer tokens to user
        farToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, positionId, amount);
    }

    /**
     * @notice Claims accumulated rewards from a specific position
     * @param positionId ID of the position to claim rewards from
     */
    function claimRewards(uint256 positionId) external nonReentrant whenNotPaused {
        _getPosition(msg.sender, positionId);

        // Update global and position rewards
        _updateGlobalRewards();
        _updatePositionRewards(msg.sender, positionId);

        StakingPosition storage position = userPositions[msg.sender][positionId];
        uint256 pendingRewards = position.rewardDebt;

        if (pendingRewards == 0) revert NoRewardsToClaim();

        _claimRewards(msg.sender, positionId, pendingRewards);
    }

    /**
     * @notice Claims accumulated rewards from all positions
     */
    function claimAllRewards() external nonReentrant whenNotPaused {
        uint256 positionCount = userPositions[msg.sender].length;
        if (positionCount == 0) revert NoRewardsToClaim();

        // Update global rewards once
        _updateGlobalRewards();

        uint256 totalPendingRewards = 0;

        // Track individual position rewards for event emission
        uint256[] memory positionRewards = new uint256[](positionCount);

        // Update all positions and accumulate rewards
        for (uint256 i = 0; i < positionCount; i++) {
            _updatePositionRewards(msg.sender, i);
            uint256 pendingRewards = userPositions[msg.sender][i].rewardDebt;

            if (pendingRewards > 0) {
                totalPendingRewards += pendingRewards;
                positionRewards[i] = pendingRewards;
                userPositions[msg.sender][i].rewardDebt = 0;
            }
        }

        if (totalPendingRewards == 0) revert NoRewardsToClaim();

        // Check contract balance
        uint256 contractBalance = farToken.balanceOf(address(this));
        uint256 availableRewards = contractBalance > totalStaked
            ? contractBalance - totalStaked
            : 0;

        if (availableRewards < totalPendingRewards) revert InsufficientRewardBalance();

        // Update total claimed
        totalRewardsClaimed += totalPendingRewards;
        userClaimedRewards[msg.sender] += totalPendingRewards;

        // Transfer rewards
        farToken.safeTransfer(msg.sender, totalPendingRewards);

        // Emit events only for positions that had non-zero rewards
        for (uint256 i = 0; i < positionCount; i++) {
            if (positionRewards[i] > 0) {
                emit RewardsClaimed(msg.sender, i, positionRewards[i]);
            }
        }
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Sets the emission rate for rewards distribution
     * @param _emissionPerSecond New emission rate in tokens per second (scaled by 1e18)
     */
    function setEmissionRate(uint256 _emissionPerSecond) external onlyOwner {
        _updateGlobalRewards();

        uint256 oldRate = emissionPerSecond;
        emissionPerSecond = _emissionPerSecond;

        emit EmissionRateUpdated(oldRate, _emissionPerSecond);
    }

    /**
     * @notice Sets the lock parameters for multiplier calculation
     * @param _minLockDays Minimum lock period in days
     * @param _maxLockDays Maximum lock period in days
     * @param _minMultiplier Minimum multiplier (1e18 = 1.0x)
     * @param _maxMultiplier Maximum multiplier (1e18 = 1.0x)
     */
    function setLockParameters(
        uint256 _minLockDays,
        uint256 _maxLockDays,
        uint256 _minMultiplier,
        uint256 _maxMultiplier
    ) external onlyOwner {
        if (_minLockDays >= _maxLockDays) revert InvalidLockParameters();
        if (_minMultiplier >= _maxMultiplier) revert InvalidLockParameters();
        if (_minMultiplier < PRECISION) revert InvalidMultiplier();

        lockConfig = LockConfig({
            minLockDays: _minLockDays,
            maxLockDays: _maxLockDays,
            minMultiplier: _minMultiplier,
            maxMultiplier: _maxMultiplier
        });

        emit LockParametersUpdated(
            _minLockDays,
            _maxLockDays,
            _minMultiplier,
            _maxMultiplier
        );
    }

    /**
     * @notice Sets personal multiplier for a specific user
     * @param user Address of the user
     * @param multiplier Personal multiplier value (1e18 = 1.0x)
     */
    function setPersonalMultiplier(
        address user,
        uint256 multiplier
    ) external onlyOwner {
        if (multiplier < PRECISION) revert InvalidMultiplier();

        // Update all user positions before changing multiplier
        _updateGlobalRewards();
        uint256 positionCount = userPositions[user].length;
        
        for (uint256 i = 0; i < positionCount; i++) {
            _updatePositionRewards(user, i);
            
            // Recalculate weight with new personal multiplier
            StakingPosition storage position = userPositions[user][i];
            uint256 oldWeight = _calculatePositionWeight(
                user,
                position.amount,
                position.lockMultiplier
            );

            // Temporarily set new multiplier for calculation
            uint256 oldPersonalMultiplier = personalMultiplier[user];
            personalMultiplier[user] = multiplier;

            uint256 newWeight = _calculatePositionWeight(
                user,
                position.amount,
                position.lockMultiplier
            );

            // Restore old multiplier temporarily
            personalMultiplier[user] = oldPersonalMultiplier;

            // Update global weight
            totalStakingWeight = totalStakingWeight - oldWeight + newWeight;
        }

        // Now set the new multiplier
        personalMultiplier[user] = multiplier;

        emit PersonalMultiplierSet(user, multiplier);
    }

    /**
     * @notice Deposits reward tokens into the contract
     * @param amount Amount of reward tokens to deposit
     */
    function depositRewardTokens(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();

        farToken.safeTransferFrom(msg.sender, address(this), amount);

        emit RewardTokensDeposited(amount);
    }

    /**
     * @notice Sets the minimum deposit amount for new positions
     * @param _minDepositAmount New minimum deposit amount (with 18 decimals)
     */
    function setMinDepositAmount(uint256 _minDepositAmount) external onlyOwner {
        uint256 oldAmount = minDepositAmount;
        minDepositAmount = _minDepositAmount;

        emit MinDepositAmountUpdated(oldAmount, _minDepositAmount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @dev Updates global reward accumulator
     */
    function _updateGlobalRewards() internal {
        if (totalStakingWeight == 0) {
            lastGlobalUpdateTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - lastGlobalUpdateTime;
        if (timeElapsed == 0) return;

        uint256 rewards = (timeElapsed * emissionPerSecond * PRECISION) / PRECISION;
        accRewardPerWeight += (rewards * PRECISION) / totalStakingWeight;
        lastGlobalUpdateTime = block.timestamp;
    }

    /**
     * @dev Updates rewards for a specific position using delta calculation
     * @param user Address of the user
     * @param positionId ID of the position
     */
    function _updatePositionRewards(address user, uint256 positionId) internal {
        StakingPosition storage position = userPositions[user][positionId];
        
        uint256 positionWeight = _calculatePositionWeight(
            user,
            position.amount,
            position.lockMultiplier
        );

        // Calculate delta rewards since last checkpoint
        uint256 deltaAccRewardPerWeight = accRewardPerWeight - position.accRewardPerWeightPaid;
        uint256 pending = (positionWeight * deltaAccRewardPerWeight) / PRECISION;
        
        position.rewardDebt += pending;
        position.accRewardPerWeightPaid = accRewardPerWeight;
        position.lastRewardTime = block.timestamp;
    }

    /**
     * @dev Claims rewards for a position
     * @param user Address of the user
     * @param positionId ID of the position
     * @param amount Amount of rewards to claim
     */
    function _claimRewards(
        address user,
        uint256 positionId,
        uint256 amount
    ) internal {
        // Check contract balance
        uint256 contractBalance = farToken.balanceOf(address(this));
        uint256 availableRewards = contractBalance > totalStaked
            ? contractBalance - totalStaked
            : 0;

        if (availableRewards < amount) revert InsufficientRewardBalance();

        // Reset reward debt
        userPositions[user][positionId].rewardDebt = 0;

        // Update total claimed
        totalRewardsClaimed += amount;
        userClaimedRewards[user] += amount;

        // Transfer rewards
        farToken.safeTransfer(user, amount);

        emit RewardsClaimed(user, positionId, amount);
    }

    /**
     * @dev Calculates lock multiplier based on lock duration
     * @param lockDays Lock duration in days
     * @return multiplier Lock multiplier (scaled by 1e18)
     */
    function _calculateLockMultiplier(uint256 lockDays) internal view returns (uint256) {
        if (lockDays < lockConfig.minLockDays) {
            return PRECISION;
        }

        if (lockDays >= lockConfig.maxLockDays) {
            return lockConfig.maxMultiplier;
        }

        // Linear interpolation
        uint256 lockRange = lockConfig.maxLockDays - lockConfig.minLockDays;
        uint256 multiplierRange = lockConfig.maxMultiplier - lockConfig.minMultiplier;
        uint256 lockProgress = lockDays - lockConfig.minLockDays;

        return lockConfig.minMultiplier + (lockProgress * multiplierRange) / lockRange;
    }

    /**
     * @dev Calculates total weight for a position including personal multiplier
     * @param user Address of the user
     * @param amount Amount of tokens staked
     * @param lockMultiplier Lock-based multiplier
     * @return weight Total staking weight
     */
    function _calculatePositionWeight(
        address user,
        uint256 amount,
        uint256 lockMultiplier
    ) internal view returns (uint256) {
        uint256 userPersonalMultiplier = personalMultiplier[user];
        if (userPersonalMultiplier == 0) {
            userPersonalMultiplier = PRECISION;
        }

        // totalMultiplier = lockMultiplier + (personalMultiplier - 1.0)
        uint256 totalMultiplier = lockMultiplier + userPersonalMultiplier - PRECISION;

        return (amount * totalMultiplier) / PRECISION;
    }

    /**
     * @dev Gets a position and validates it exists
     * @param user Address of the user
     * @param positionId ID of the position
     * @return position The staking position
     */
    function _getPosition(
        address user,
        uint256 positionId
    ) internal view returns (StakingPosition storage) {
        if (positionId >= userPositions[user].length) revert InvalidPositionId();
        return userPositions[user][positionId];
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function getPositionInfo(
        address user,
        uint256 positionId
    ) external view returns (
        uint256 amount,
        uint256 unlockTime,
        uint256 lockMultiplier,
        uint256 pendingRewards
    ) {
        if (positionId >= userPositions[user].length) revert InvalidPositionId();
        
        StakingPosition memory position = userPositions[user][positionId];
        
        return (
            position.amount,
            position.unlockTime,
            position.lockMultiplier,
            _calculatePendingRewards(user, positionId)
        );
    }

    function getPendingRewards(
        address user,
        uint256 positionId
    ) external view returns (uint256) {
        return _calculatePendingRewards(user, positionId);
    }

    /**
     * @dev Calculates pending rewards for a position using delta approach
     */
    function _calculatePendingRewards(
        address user,
        uint256 positionId
    ) internal view returns (uint256) {
        if (positionId >= userPositions[user].length) return 0;

        StakingPosition memory position = userPositions[user][positionId];
        
        // Calculate current accumulated reward per weight
        uint256 currentAccRewardPerWeight = accRewardPerWeight;
        
        if (totalStakingWeight > 0 && block.timestamp > lastGlobalUpdateTime) {
            uint256 timeElapsed = block.timestamp - lastGlobalUpdateTime;
            uint256 rewards = (timeElapsed * emissionPerSecond * PRECISION) / PRECISION;
            currentAccRewardPerWeight += (rewards * PRECISION) / totalStakingWeight;
        }

        // Calculate position weight
        uint256 positionWeight = _calculatePositionWeight(
            user,
            position.amount,
            position.lockMultiplier
        );

        // Calculate delta rewards since last checkpoint
        uint256 deltaAccRewardPerWeight = currentAccRewardPerWeight - position.accRewardPerWeightPaid;
        uint256 pending = (positionWeight * deltaAccRewardPerWeight) / PRECISION;
        
        return position.rewardDebt + pending;
    }

    function getPositionCount(address user) external view returns (uint256) {
        return userPositions[user].length;
    }

    function getUserPositions(
        address user
    ) external view returns (StakingPosition[] memory) {
        return userPositions[user];
    }

    function getTotalPendingRewards(address user) external view returns (uint256) {
        uint256 totalPending = 0;
        uint256 positionCount = userPositions[user].length;

        for (uint256 i = 0; i < positionCount; i++) {
            totalPending += _calculatePendingRewards(user, i);
        }

        return totalPending;
    }

    function getContractStats() external view returns (
        uint256 totalStakedAmount,
        uint256 totalWeight,
        uint256 currentEmissionRate,
        uint256 totalRewards,
        uint256 availableRewardBalance
    ) {
        uint256 contractBalance = farToken.balanceOf(address(this));
        uint256 availableRewards = contractBalance > totalStaked 
            ? contractBalance - totalStaked 
            : 0;

        return (
            totalStaked,
            totalStakingWeight,
            emissionPerSecond,
            totalRewardsClaimed,
            availableRewards
        );
    }

    function getLockConfig() external view returns (
        uint256 minLockDays,
        uint256 maxLockDays,
        uint256 minMultiplier,
        uint256 maxMultiplier
    ) {
        return (
            lockConfig.minLockDays,
            lockConfig.maxLockDays,
            lockConfig.minMultiplier,
            lockConfig.maxMultiplier
        );
    }

    function calculateLockMultiplier(uint256 lockDays) external view returns (uint256) {
        return _calculateLockMultiplier(lockDays);
    }

    function calculatePositionWeight(
        address user,
        uint256 amount,
        uint256 lockDays
    ) external view returns (uint256) {
        uint256 lockMultiplier = _calculateLockMultiplier(lockDays);
        return _calculatePositionWeight(user, amount, lockMultiplier);
    }

    // ============================================
    // UI HELPER FUNCTIONS
    // ============================================

    function getUserPositionsPaginated(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (
        StakingPosition[] memory positions,
        uint256 totalCount
    ) {
        totalCount = userPositions[user].length;
        
        if (offset >= totalCount) {
            return (new StakingPosition[](0), totalCount);
        }
        
        if (limit > 100) limit = 100;
        
        uint256 end = offset + limit;
        if (end > totalCount) end = totalCount;
        uint256 size = end - offset;
        
        positions = new StakingPosition[](size);
        
        for (uint256 i = 0; i < size; i++) {
            positions[i] = userPositions[user][offset + i];
        }
        
        return (positions, totalCount);
    }

    function getPositionsWithRewards(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (
        StakingPosition[] memory positions,
        uint256[] memory pendingRewards,
        uint256 totalCount
    ) {
        totalCount = userPositions[user].length;
        
        if (offset >= totalCount) {
            return (
                new StakingPosition[](0),
                new uint256[](0),
                totalCount
            );
        }
        
        if (limit > 50) limit = 50;
        
        uint256 end = offset + limit;
        if (end > totalCount) end = totalCount;
        uint256 size = end - offset;
        
        positions = new StakingPosition[](size);
        pendingRewards = new uint256[](size);
        
        for (uint256 i = 0; i < size; i++) {
            uint256 positionId = offset + i;
            positions[i] = userPositions[user][positionId];
            pendingRewards[i] = _calculatePendingRewards(user, positionId);
        }
        
        return (positions, pendingRewards, totalCount);
    }

    function getUserTotalStaked(address user) external view returns (uint256) {
        uint256 totalStakedAmount = 0;
        uint256 positionCount = userPositions[user].length;
        
        for (uint256 i = 0; i < positionCount; i++) {
            totalStakedAmount += userPositions[user][i].amount;
        }
        
        return totalStakedAmount;
    }

    function getUserTotalWeight(address user) external view returns (uint256) {
        uint256 totalWeight = 0;
        uint256 positionCount = userPositions[user].length;
        
        for (uint256 i = 0; i < positionCount; i++) {
            StakingPosition memory position = userPositions[user][i];
            totalWeight += _calculatePositionWeight(
                user,
                position.amount,
                position.lockMultiplier
            );
        }
        
        return totalWeight;
    }

    function getUserDashboard(address user) external view returns (
        uint256 userTotalStaked,
        uint256 userTotalWeight,
        uint256 userTotalPending,
        uint256 userPositionCount,
        uint256 userMultiplier,
        uint256 userShareOfPool
    ) {
        userPositionCount = userPositions[user].length;
        
        for (uint256 i = 0; i < userPositionCount; i++) {
            StakingPosition memory position = userPositions[user][i];
            
            userTotalStaked += position.amount;
            userTotalWeight += _calculatePositionWeight(user, position.amount, position.lockMultiplier);
            userTotalPending += _calculatePendingRewards(user, i);
        }
        
        userMultiplier = personalMultiplier[user];
        if (userMultiplier == 0) {
            userMultiplier = PRECISION;
        }
        
        if (totalStakingWeight > 0) {
            userShareOfPool = (userTotalWeight * PRECISION) / totalStakingWeight;
        } else {
            userShareOfPool = 0;
        }
        
        return (
            userTotalStaked,
            userTotalWeight,
            userTotalPending,
            userPositionCount,
            userMultiplier,
            userShareOfPool
        );
    }

    function getPositionDetails(
        address user,
        uint256 positionId
    ) external view returns (
        uint256 posAmount,
        uint256 posUnlockTime,
        uint256 posLockMultiplier,
        uint256 posPersonalMultiplier,
        uint256 posTotalMultiplier,
        uint256 posWeight,
        uint256 posPendingRewards,
        bool posIsUnlocked,
        uint256 posDaysUntilUnlock
    ) {
        if (positionId >= userPositions[user].length) revert InvalidPositionId();
        
        StakingPosition memory position = userPositions[user][positionId];
        
        posAmount = position.amount;
        posUnlockTime = position.unlockTime;
        posLockMultiplier = position.lockMultiplier;
        
        posPersonalMultiplier = personalMultiplier[user];
        if (posPersonalMultiplier == 0) {
            posPersonalMultiplier = PRECISION;
        }
        
        posTotalMultiplier = posLockMultiplier + posPersonalMultiplier - PRECISION;
        posWeight = _calculatePositionWeight(user, posAmount, posLockMultiplier);
        posPendingRewards = _calculatePendingRewards(user, positionId);
        posIsUnlocked = block.timestamp >= posUnlockTime;
        
        if (posIsUnlocked) {
            posDaysUntilUnlock = 0;
        } else {
            posDaysUntilUnlock = (posUnlockTime - block.timestamp) / SECONDS_PER_DAY;
        }
        
        return (
            posAmount,
            posUnlockTime,
            posLockMultiplier,
            posPersonalMultiplier,
            posTotalMultiplier,
            posWeight,
            posPendingRewards,
            posIsUnlocked,
            posDaysUntilUnlock
        );
    }

    function getUserActivePositions(address user) external view returns (
        uint256[] memory activePositions,
        uint256 activeCount
    ) {
        uint256 totalCount = userPositions[user].length;
        
        activeCount = 0;
        for (uint256 i = 0; i < totalCount; i++) {
            if (block.timestamp >= userPositions[user][i].unlockTime) {
                activeCount++;
            }
        }
        
        activePositions = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < totalCount; i++) {
            if (block.timestamp >= userPositions[user][i].unlockTime) {
                activePositions[index] = i;
                index++;
            }
        }
        
        return (activePositions, activeCount);
    }

    function getUserLockedPositions(address user) external view returns (
        uint256[] memory lockedPositions,
        uint256 lockedCount
    ) {
        uint256 totalCount = userPositions[user].length;
        
        lockedCount = 0;
        for (uint256 i = 0; i < totalCount; i++) {
            if (block.timestamp < userPositions[user][i].unlockTime) {
                lockedCount++;
            }
        }
        
        lockedPositions = new uint256[](lockedCount);
        uint256 index = 0;
        for (uint256 i = 0; i < totalCount; i++) {
            if (block.timestamp < userPositions[user][i].unlockTime) {
                lockedPositions[index] = i;
                index++;
            }
        }
        
        return (lockedPositions, lockedCount);
    }

    function getUserEstimatedAPY(address user) external view returns (uint256 userEstimatedAPY) {
        uint256 userWeight = 0;
        uint256 userStaked = 0;
        uint256 positionCount = userPositions[user].length;
        
        if (positionCount == 0 || totalStakingWeight == 0) return 0;
        
        for (uint256 i = 0; i < positionCount; i++) {
            StakingPosition memory position = userPositions[user][i];
            userStaked += position.amount;
            userWeight += _calculatePositionWeight(user, position.amount, position.lockMultiplier);
        }
        
        if (userStaked == 0) return 0;
        
        uint256 annualRewards = (userWeight * emissionPerSecond * 365 days) / totalStakingWeight;
        userEstimatedAPY = (annualRewards * PRECISION) / userStaked;
        
        return userEstimatedAPY;
    }

    function getEnhancedContractStats() external view returns (
        uint256 contractTotalStaked,
        uint256 contractTotalWeight,
        uint256 contractEmissionRate,
        uint256 contractDailyEmission,
        uint256 contractTotalClaimed,
        uint256 contractAvailableRewards,
        uint256 contractAvgMultiplier,
        uint256 contractEstimatedDaily
    ) {
        uint256 contractBalance = farToken.balanceOf(address(this));
        contractAvailableRewards = contractBalance > totalStaked 
            ? contractBalance - totalStaked 
            : 0;
        
        contractTotalStaked = totalStaked;
        contractTotalWeight = totalStakingWeight;
        contractEmissionRate = emissionPerSecond;
        contractTotalClaimed = totalRewardsClaimed;
        contractDailyEmission = emissionPerSecond * SECONDS_PER_DAY;
        
        if (totalStaked > 0 && totalStakingWeight > 0) {
            contractAvgMultiplier = (totalStakingWeight * PRECISION) / totalStaked;
        } else {
            contractAvgMultiplier = PRECISION;
        }
        
        contractEstimatedDaily = contractDailyEmission;
        
        return (
            contractTotalStaked,
            contractTotalWeight,
            contractEmissionRate,
            contractDailyEmission,
            contractTotalClaimed,
            contractAvailableRewards,
            contractAvgMultiplier,
            contractEstimatedDaily
        );
    }

    function previewPosition(
        address user,
        uint256 amount,
        uint256 lockDays
    ) external view returns (
        uint256 previewLockMultiplier,
        uint256 previewTotalMultiplier,
        uint256 previewWeight,
        uint256 previewDailyRewards,
        uint256 previewAPY
    ) {
        previewLockMultiplier = _calculateLockMultiplier(lockDays);
        
        uint256 userPersonalMultiplier = personalMultiplier[user];
        if (userPersonalMultiplier == 0) {
            userPersonalMultiplier = PRECISION;
        }
        
        previewTotalMultiplier = previewLockMultiplier + userPersonalMultiplier - PRECISION;
        previewWeight = (amount * previewTotalMultiplier) / PRECISION;
        
        uint256 futureWeight = totalStakingWeight + previewWeight;
        if (futureWeight > 0) {
            previewDailyRewards = (previewWeight * emissionPerSecond * SECONDS_PER_DAY) / futureWeight;
            
            uint256 annualRewards = previewDailyRewards * 365;
            if (amount > 0) {
                previewAPY = (annualRewards * PRECISION) / amount;
            }
        }
        
        return (
            previewLockMultiplier,
            previewTotalMultiplier,
            previewWeight,
            previewDailyRewards,
            previewAPY
        );
    }

    // ============================================
    // STAKER TRACKING FUNCTIONS
    // ============================================

    /**
     * @notice Returns total claimed rewards for a user
     * @param user Address of the user
     * @return Total rewards claimed by the user
     */
    function getUserClaimedRewards(address user) external view returns (uint256) {
        return userClaimedRewards[user];
    }

    /**
     * @notice Returns total number of stakers (addresses that have created positions)
     * @return Total count of stakers
     */
    function getTotalStakersCount() external view returns (uint256) {
        return stakers.length;
    }

    /**
     * @notice Returns count of active stakers (those with staked amount > 0)
     * @return Count of active stakers
     */
    function getActiveStakersCount() external view returns (uint256) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            uint256 positionCount = userPositions[staker].length;

            // Check if user has any positions with amount > 0
            for (uint256 j = 0; j < positionCount; j++) {
                if (userPositions[staker][j].amount > 0) {
                    activeCount++;
                    break; // Count user only once
                }
            }
        }
        return activeCount;
    }

    /**
     * @notice Returns paginated list of staker addresses
     * @param offset Starting index
     * @param limit Maximum number of addresses to return
     * @return addresses Array of staker addresses
     * @return totalCount Total number of stakers
     */
    function getStakersPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (
        address[] memory addresses,
        uint256 totalCount
    ) {
        totalCount = stakers.length;

        if (offset >= totalCount) {
            return (new address[](0), totalCount);
        }

        if (limit > 100) limit = 100; // Cap at 100 to prevent gas issues

        uint256 end = offset + limit;
        if (end > totalCount) end = totalCount;
        uint256 size = end - offset;

        addresses = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            addresses[i] = stakers[offset + i];
        }

        return (addresses, totalCount);
    }

    /**
     * @notice Returns paginated list of active stakers (those with amount > 0)
     * @param offset Starting index in filtered results
     * @param limit Maximum number of addresses to return
     * @return addresses Array of active staker addresses
     * @return totalActiveCount Total number of active stakers
     */
    function getActiveStakersPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (
        address[] memory addresses,
        uint256 totalActiveCount
    ) {
        // First, collect all active stakers
        address[] memory allActiveStakers = new address[](stakers.length);
        uint256 activeIndex = 0;

        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            uint256 positionCount = userPositions[staker].length;

            // Check if user has any positions with amount > 0
            bool hasActivePosition = false;
            for (uint256 j = 0; j < positionCount; j++) {
                if (userPositions[staker][j].amount > 0) {
                    hasActivePosition = true;
                    break;
                }
            }

            if (hasActivePosition) {
                allActiveStakers[activeIndex] = staker;
                activeIndex++;
            }
        }

        totalActiveCount = activeIndex;

        if (offset >= totalActiveCount) {
            return (new address[](0), totalActiveCount);
        }

        if (limit > 100) limit = 100; // Cap at 100

        uint256 end = offset + limit;
        if (end > totalActiveCount) end = totalActiveCount;
        uint256 size = end - offset;

        addresses = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            addresses[i] = allActiveStakers[offset + i];
        }

        return (addresses, totalActiveCount);
    }
}
