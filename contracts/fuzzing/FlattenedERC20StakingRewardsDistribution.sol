// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.4;

/**
 * Errors codes:
 *
 * SRD01: invalid starting timestamp
 * SRD02: invalid time duration
 * SRD03: inconsistent reward token/amount
 * SRD04: 0 address as reward token
 * SRD05: no reward
 * SRD06: no funding
 * SRD07: 0 address as stakable token
 * SRD08: distribution already started
 * SRD09: tried to stake nothing
 * SRD10: staking cap hit
 * SRD11: tried to withdraw nothing
 * SRD12: funds locked until the distribution ends
 * SRD13: withdrawn amount greater than current stake
 * SRD14: inconsistent claimed amounts
 * SRD15: insufficient claimable amount
 * SRD16: 0 address owner
 * SRD17: caller not owner
 * SRD18: already initialized
 * SRD19: invalid state for cancel to be called
 * SRD20: not started
 * SRD21: already ended
 * SRD22: no rewards are recoverable
 * SRD23: no rewards are claimable while claiming all
 * SRD24: no rewards are claimable while manually claiming an arbitrary amount of rewards
 * SRD25: staking is currently paused
 */
contract ERC20StakingRewardsDistribution {
    using SafeERC20 for IERC20;

    uint256 public constant MULTIPLIER = 2**64;

    struct Reward {
        address token;
        uint256 amount;
        uint256 unassigned;
        uint256 perStakedToken;
    }

    struct StakerRewardInfo {
        uint256 consolidatedPerStakedToken;
        uint256 earned;
        uint256 claimed;
    }

    struct Staker {
        uint256 stake;
        mapping(address => StakerRewardInfo) rewardInfo;
    }

    Reward[] public rewards;
    mapping(address => Staker) public stakers;
    uint64 public startingTimestamp;
    uint64 public endingTimestamp;
    uint64 public secondsDuration;
    uint64 public lastConsolidationTimestamp;
    IERC20 public stakableToken;
    address public owner;
    address public factory;
    bool public locked;
    bool public canceled;
    bool public initialized;
    uint256 public totalStakedTokensAmount;
    uint256 public stakingCap;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event Initialized(
        address[] rewardsTokenAddresses,
        address stakableTokenAddress,
        uint256[] rewardsAmounts,
        uint64 startingTimestamp,
        uint64 endingTimestamp,
        bool locked,
        uint256 stakingCap
    );
    event Canceled();
    event Staked(address indexed staker, uint256 amount);
    event Withdrawn(address indexed withdrawer, uint256 amount);
    event Claimed(address indexed claimer, uint256[] amounts);
    event Recovered(uint256[] amounts);
    event UpdatedRewards(uint256[] amounts);

    function initialize(
        address[] calldata _rewardTokenAddresses,
        address _stakableTokenAddress,
        uint256[] calldata _rewardAmounts,
        uint64 _startingTimestamp,
        uint64 _endingTimestamp,
        bool _locked,
        uint256 _stakingCap
    ) external onlyUninitialized {
        require(_endingTimestamp > _startingTimestamp, "SRD02");
        require(_rewardTokenAddresses.length == _rewardAmounts.length, "SRD03");

        secondsDuration = _endingTimestamp - _startingTimestamp;
        // Initializing reward tokens and amounts
        for (uint32 _i = 0; _i < _rewardTokenAddresses.length; _i++) {
            address _rewardTokenAddress = _rewardTokenAddresses[_i];
            uint256 _rewardAmount = _rewardAmounts[_i];
            require(_rewardTokenAddress != address(0), "SRD04");
            IERC20 _rewardToken = IERC20(_rewardTokenAddress);
            require(
                _rewardToken.balanceOf(address(this)) == _rewardAmount,
                "SRD06"
            );
            rewards.push(
                Reward({
                    token: _rewardTokenAddress,
                    amount: _rewardAmount,
                    unassigned: _rewardAmount * MULTIPLIER,
                    perStakedToken: 0
                })
            );
        }

        require(_stakableTokenAddress != address(0), "SRD07");
        stakableToken = IERC20(_stakableTokenAddress);

        owner = msg.sender;
        factory = msg.sender;
        startingTimestamp = _startingTimestamp;
        endingTimestamp = _endingTimestamp;
        lastConsolidationTimestamp = _startingTimestamp;
        locked = _locked;
        stakingCap = _stakingCap;
        initialized = true;
        canceled = false;

        emit Initialized(
            _rewardTokenAddresses,
            _stakableTokenAddress,
            _rewardAmounts,
            _startingTimestamp,
            _endingTimestamp,
            _locked,
            _stakingCap
        );
    }

    function cancel() external onlyOwner {
        require(initialized && !canceled, "SRD19");
        require(block.timestamp < startingTimestamp, "SRD08");
        for (uint256 _i; _i < rewards.length; _i++) {
            Reward storage _reward = rewards[_i];
            IERC20(_reward.token).safeTransfer(
                owner,
                IERC20(_reward.token).balanceOf(address(this))
            );
        }
        canceled = true;
        emit Canceled();
    }

    function recoverUnassignedRewards() external onlyStarted {
        consolidateReward();
        uint256[] memory _recoveredUnassignedRewards =
            new uint256[](rewards.length);
        require(block.timestamp >= endingTimestamp, "SRD12");
        bool _atLeastOneNonZeroRecovery = false;
        for (uint256 _i; _i < rewards.length; _i++) {
            Reward storage _reward = rewards[_i];
            // recoverable rewards are going to be recovered in this tx (if it does not revert),
            if (_reward.unassigned == 0) continue;
            _atLeastOneNonZeroRecovery = true;
            _recoveredUnassignedRewards[_i] = _reward.unassigned / MULTIPLIER;
            IERC20(_reward.token).safeTransfer(
                owner,
                _reward.unassigned / MULTIPLIER
            );
            _reward.unassigned = 0;
        }
        require(_atLeastOneNonZeroRecovery, "SRD22");
        emit Recovered(_recoveredUnassignedRewards);
    }

    function stake(uint256 _amount) external onlyRunning {
        require(
            !IERC20StakingRewardsDistributionFactory(factory).stakingPaused(),
            "SRD25"
        );
        require(_amount > 0, "SRD09");
        if (stakingCap > 0) {
            require(totalStakedTokensAmount + _amount <= stakingCap, "SRD10");
        }
        consolidateReward();
        Staker storage _staker = stakers[msg.sender];
        _staker.stake += _amount;
        totalStakedTokensAmount += _amount;
        stakableToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) public onlyStarted {
        require(_amount > 0, "SRD11");
        if (locked) {
            require(block.timestamp > endingTimestamp, "SRD12");
        }
        consolidateReward();
        Staker storage _staker = stakers[msg.sender];
        require(_staker.stake >= _amount, "SRD13");
        _staker.stake -= _amount;
        totalStakedTokensAmount -= _amount;
        stakableToken.safeTransfer(msg.sender, _amount);
        emit Withdrawn(msg.sender, _amount);
    }

    function claim(uint256[] memory _amounts, address _recipient)
        external
        onlyStarted
    {
        require(_amounts.length == rewards.length, "SRD14");
        consolidateReward();
        Staker storage _staker = stakers[msg.sender];
        uint256[] memory _claimedRewards = new uint256[](rewards.length);
        bool _atLeastOneNonZeroClaim = false;
        for (uint256 _i; _i < rewards.length; _i++) {
            Reward storage _reward = rewards[_i];
            StakerRewardInfo storage _stakerRewardInfo =
                _staker.rewardInfo[_reward.token];
            uint256 _claimableReward =
                _stakerRewardInfo.earned - _stakerRewardInfo.claimed;
            uint256 _wantedAmount = _amounts[_i];
            require(_claimableReward >= _wantedAmount, "SRD15");
            if (!_atLeastOneNonZeroClaim && _wantedAmount > 0)
                _atLeastOneNonZeroClaim = true;
            _stakerRewardInfo.claimed += _wantedAmount;
            IERC20(_reward.token).safeTransfer(_recipient, _wantedAmount);
            _claimedRewards[_i] = _wantedAmount;
        }
        require(_atLeastOneNonZeroClaim, "SRD24");
        emit Claimed(msg.sender, _claimedRewards);
    }

    function claimAll(address _recipient) public onlyStarted {
        consolidateReward();
        Staker storage _staker = stakers[msg.sender];
        uint256[] memory _claimedRewards = new uint256[](rewards.length);
        bool _atLeastOneNonZeroClaim = false;
        for (uint256 _i; _i < rewards.length; _i++) {
            Reward storage _reward = rewards[_i];
            StakerRewardInfo storage _stakerRewardInfo =
                _staker.rewardInfo[_reward.token];
            uint256 _claimableReward =
                _stakerRewardInfo.earned - _stakerRewardInfo.claimed;
            if (_claimableReward == 0) continue;
            _atLeastOneNonZeroClaim = true;
            _stakerRewardInfo.claimed += _claimableReward;

            IERC20(_reward.token).safeTransfer(_recipient, _claimableReward);
            _claimedRewards[_i] = _claimableReward;
        }
        require(_atLeastOneNonZeroClaim, "SRD23");
        emit Claimed(msg.sender, _claimedRewards);
    }

    function exit(address _recipient) external onlyStarted {
        claimAll(_recipient);
        withdraw(stakers[msg.sender].stake);
    }

    function consolidateReward() private {
        uint64 _consolidationTimestamp =
            uint64(Math.min(block.timestamp, endingTimestamp));
        if (_consolidationTimestamp < lastConsolidationTimestamp)
            // hasn't started yet
            return;
        uint256 _lastPeriodDuration =
            uint256(_consolidationTimestamp - lastConsolidationTimestamp);
        uint256 _unconsolidatedDuration =
            uint256(endingTimestamp - lastConsolidationTimestamp);
        Staker storage _staker = stakers[msg.sender];
        lastConsolidationTimestamp = _consolidationTimestamp;
        for (uint256 _i; _i < rewards.length; _i++) {
            Reward storage _reward = rewards[_i];
            StakerRewardInfo storage _stakerRewardInfo =
                _staker.rewardInfo[_reward.token];
            if (_unconsolidatedDuration * totalStakedTokensAmount > 0) {
                uint256 _thisPerStakedToken =
                    (_lastPeriodDuration * _reward.unassigned) /
                        totalStakedTokensAmount /
                        _unconsolidatedDuration;
                _reward.perStakedToken += _thisPerStakedToken;
                _reward.unassigned -= (_thisPerStakedToken *
                    totalStakedTokensAmount);
            }
            _stakerRewardInfo.earned +=
                (_staker.stake *
                    (_reward.perStakedToken -
                        _stakerRewardInfo.consolidatedPerStakedToken)) /
                MULTIPLIER;
            _stakerRewardInfo.consolidatedPerStakedToken = _reward
                .perStakedToken;
        }
    }

    function addRewards(address _token, uint256 _amount) public {
        consolidateReward();
        uint256[] memory _updatedAmounts = new uint256[](rewards.length);
        for (uint32 _i = 0; _i < rewards.length; _i++) {
            address _rewardTokenAddress = rewards[_i].token;
            if (_rewardTokenAddress == _token) {
                IERC20(_token).safeTransferFrom(
                    msg.sender,
                    address(this),
                    _amount
                );
                rewards[_i].amount += _amount;
                rewards[_i].unassigned += _amount * MULTIPLIER;
            }
            _updatedAmounts[_i] = rewards[_i].amount;
        }
        emit UpdatedRewards(_updatedAmounts);
    }

    function claimableRewards(address _account)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory _outstandingRewards = new uint256[](rewards.length);
        if (!initialized) return _outstandingRewards;
        if (block.timestamp < startingTimestamp) return _outstandingRewards;
        uint64 _consolidationTimestamp =
            uint64(Math.min(block.timestamp, endingTimestamp));
        uint256 _lastPeriodDuration =
            uint256(_consolidationTimestamp - lastConsolidationTimestamp);
        uint256 _unconsolidatedDuration =
            uint256(endingTimestamp - lastConsolidationTimestamp);
        Staker storage _staker = stakers[_account];
        for (uint256 _i; _i < rewards.length; _i++) {
            Reward storage _reward = rewards[_i];
            StakerRewardInfo storage _stakerRewardInfo =
                _staker.rewardInfo[_reward.token];
            _outstandingRewards[_i] = (_stakerRewardInfo.earned -
                _stakerRewardInfo.claimed);
            if (_staker.stake == 0) continue;
            if (_unconsolidatedDuration == 0)
                continue;
            _outstandingRewards[_i] +=
                ((_staker.stake * _lastPeriodDuration * _reward.unassigned) /
                    MULTIPLIER) /
                totalStakedTokensAmount /
                _unconsolidatedDuration;
        }
        return _outstandingRewards;
    }

    function getRewardTokens() external view returns (address[] memory) {
        address[] memory _rewardTokens = new address[](rewards.length);
        for (uint256 _i = 0; _i < rewards.length; _i++) {
            _rewardTokens[_i] = rewards[_i].token;
        }
        return _rewardTokens;
    }

    function rewardAmount(address _rewardToken)
        external
        view
        returns (uint256)
    {
        for (uint256 _i = 0; _i < rewards.length; _i++) {
            Reward storage _reward = rewards[_i];
            if (_rewardToken == _reward.token) return _reward.amount;
        }
        return 0;
    }

    function stakedTokensOf(address _staker) external view returns (uint256) {
        return stakers[_staker].stake;
    }

    function earnedRewardsOf(address _staker)
        external
        view
        returns (uint256[] memory)
    {
        Staker storage _stakerFromStorage = stakers[_staker];
        uint256[] memory _earnedRewards = new uint256[](rewards.length);
        for (uint256 _i; _i < rewards.length; _i++) {
            _earnedRewards[_i] = _stakerFromStorage.rewardInfo[
                rewards[_i].token
            ]
                .earned;
        }
        return _earnedRewards;
    }

    function recoverableUnassignedReward(address _rewardToken)
        external
        view
        returns (uint256)
    {
        require(block.timestamp >= endingTimestamp, "SRD12");
        uint64 _consolidationTimestamp =
            uint64(Math.min(block.timestamp, endingTimestamp));
        uint256 _lastPeriodDuration =
            uint256(_consolidationTimestamp - lastConsolidationTimestamp);
        uint256 _unconsolidatedDuration =
            uint256(endingTimestamp - lastConsolidationTimestamp);
        for (uint256 _i; _i < rewards.length; _i++) {
            Reward memory _reward = rewards[_i];
            if (_reward.token != _rewardToken) continue;
            if (_unconsolidatedDuration * totalStakedTokensAmount > 0) {
                uint256 _thisPerStakedToken =
                    (_lastPeriodDuration * _reward.unassigned) /
                        totalStakedTokensAmount /
                        _unconsolidatedDuration;
                _reward.perStakedToken += _thisPerStakedToken;
                _reward.unassigned -= (_thisPerStakedToken *
                    totalStakedTokensAmount);
            }
            return _reward.unassigned / MULTIPLIER;
        }
        return 0;
    }

    function getClaimedRewards(address _claimer)
        external
        view
        returns (uint256[] memory)
    {
        Staker storage _staker = stakers[_claimer];
        uint256[] memory _claimedRewards = new uint256[](rewards.length);
        for (uint256 _i = 0; _i < rewards.length; _i++) {
            Reward storage _reward = rewards[_i];
            _claimedRewards[_i] = _staker.rewardInfo[_reward.token].claimed;
        }
        return _claimedRewards;
    }

    function renounceOwnership() public onlyOwner {
        owner = address(0);
        emit OwnershipTransferred(owner, address(0));
    }

    function transferOwnership(address _newOwner) public onlyOwner {
        require(_newOwner != address(0), "SRD16");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    modifier onlyOwner() {
        require(owner == msg.sender, "SRD17");
        _;
    }

    modifier onlyUninitialized() {
        require(!initialized, "SRD18");
        _;
    }

    modifier onlyStarted() {
        require(
            initialized && !canceled && block.timestamp >= startingTimestamp,
            "SRD20"
        );
        _;
    }

    modifier onlyRunning() {
        require(
            initialized &&
                !canceled &&
                block.timestamp >= startingTimestamp &&
                block.timestamp <= endingTimestamp,
            "SRD21"
        );
        _;
    }
}


/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * Errors codes:
 *
 * SRF01: cannot pause staking (already paused)
 * SRF02: cannot resume staking (already active)
 */
contract ERC20StakingRewardsDistributionFactory is Ownable {
    using SafeERC20 for IERC20;

    address public implementation;
    bool public stakingPaused;
    IERC20StakingRewardsDistribution[] public distributions;

    event DistributionCreated(address owner, address deployedAt);

    constructor(address _implementation) {
        implementation = _implementation;
    }

    function upgradeImplementation(address _implementation) external onlyOwner {
        implementation = _implementation;
    }

    function pauseStaking() external onlyOwner {
        require(!stakingPaused, "SRF01");
        stakingPaused = true;
    }

    function resumeStaking() external onlyOwner {
        require(stakingPaused, "SRF02");
        stakingPaused = false;
    }

    function createDistribution(
        address[] calldata _rewardTokenAddresses,
        address _stakableTokenAddress,
        uint256[] calldata _rewardAmounts,
        uint64 _startingTimestamp,
        uint64 _endingTimestamp,
        bool _locked,
        uint256 _stakingCap
    ) public virtual {
        address _distributionProxy = Clones.clone(implementation);
        for (uint256 _i; _i < _rewardTokenAddresses.length; _i++) {
            if (_rewardAmounts[_i] > 0) {
                IERC20(_rewardTokenAddresses[_i]).safeTransferFrom(
                    msg.sender,
                    _distributionProxy,
                    _rewardAmounts[_i]
                );
            }
        }
        IERC20StakingRewardsDistribution _distribution =
            IERC20StakingRewardsDistribution(_distributionProxy);
        _distribution.initialize(
            _rewardTokenAddresses,
            _stakableTokenAddress,
            _rewardAmounts,
            _startingTimestamp,
            _endingTimestamp,
            _locked,
            _stakingCap
        );
        _distribution.transferOwnership(msg.sender);
        distributions.push(_distribution);
        emit DistributionCreated(msg.sender, address(_distribution));
    }

    function getDistributionsAmount() external view returns (uint256) {
        return distributions.length;
    }
}

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow, so we distribute
        return (a / 2) + (b / 2) + (((a % 2) + (b % 2)) / 2);
    }
}

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        // solhint-disable-next-line avoid-low-level-calls, avoid-call-value
        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain`call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
      return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.call{ value: value }(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data, string memory errorMessage) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.staticcall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function _verifyCallResult(bool success, bytes memory returndata, string memory errorMessage) private pure returns(bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}


/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        // solhint-disable-next-line max-line-length
        require((value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            uint256 newAllowance = oldAllowance - value;
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

/**
 * @dev https://eips.ethereum.org/EIPS/eip-1167[EIP 1167] is a standard for
 * deploying minimal proxy contracts, also known as "clones".
 *
 * > To simply and cheaply clone contract functionality in an immutable way, this standard specifies
 * > a minimal bytecode implementation that delegates all calls to a known, fixed address.
 *
 * The library includes functions to deploy a proxy using either `create` (traditional deployment) or `create2`
 * (salted deterministic deployment). It also includes functions to predict the addresses of clones deployed using the
 * deterministic method.
 *
 * _Available since v3.4._
 */
library Clones {
    /**
     * @dev Deploys and returns the address of a clone that mimics the behaviour of `implementation`.
     *
     * This function uses the create opcode, which should never revert.
     */
    function clone(address implementation) internal returns (address instance) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        require(instance != address(0), "ERC1167: create failed");
    }

    /**
     * @dev Deploys and returns the address of a clone that mimics the behaviour of `implementation`.
     *
     * This function uses the create2 opcode and a `salt` to deterministically deploy
     * the clone. Using the same `implementation` and `salt` multiple time will revert, since
     * the clones cannot be deployed twice at the same address.
     */
    function cloneDeterministic(address implementation, bytes32 salt) internal returns (address instance) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "ERC1167: create2 failed");
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministic}.
     */
    function predictDeterministicAddress(address implementation, bytes32 salt, address deployer) internal pure returns (address predicted) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, deployer))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            predicted := keccak256(add(ptr, 0x37), 0x55)
        }
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministic}.
     */
    function predictDeterministicAddress(address implementation, bytes32 salt) internal view returns (address predicted) {
        return predictDeterministicAddress(implementation, salt, address(this));
    }
}

interface IERC20StakingRewardsDistribution {
    function rewardAmount(address _rewardToken) external view returns (uint256);

    function recoverableUnassignedReward(address _rewardToken)
        external
        view
        returns (uint256);

    function stakedTokensOf(address _staker) external view returns (uint256);

    function getRewardTokens() external view returns (address[] memory);

    function getClaimedRewards(address _claimer)
        external
        view
        returns (uint256[] memory);

    function initialize(
        address[] calldata _rewardTokenAddresses,
        address _stakableTokenAddress,
        uint256[] calldata _rewardAmounts,
        uint64 _startingTimestamp,
        uint64 _endingTimestamp,
        bool _locked,
        uint256 _stakingCap
    ) external;

    function cancel() external;

    function recoverUnassignedRewards() external;

    function stake(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function claim(uint256[] memory _amounts, address _recipient) external;

    function claimAll(address _recipient) external;

    function exit(address _recipient) external;

    function consolidateReward() external;

    function claimableRewards(address _staker)
        external
        view
        returns (uint256[] memory);

    function renounceOwnership() external;

    function transferOwnership(address _newOwner) external;
}

interface IERC20StakingRewardsDistributionFactory {
    function createDistribution(
        address[] calldata _rewardTokenAddresses,
        address _stakableTokenAddress,
        uint256[] calldata _rewardAmounts,
        uint64 _startingTimestamp,
        uint64 _endingTimestamp,
        bool _locked,
        uint256 _stakingCap
    ) external;

    function getDistributionsAmount() external view returns (uint256);

    function implementation() external view returns (address);

    function upgradeTo(address newImplementation) external;

    function distributions(uint256 _index) external returns (address);

    function stakingPaused() external returns (bool);
}

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC20
 * applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract TestERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
        _mint(msg.sender, 10000 * 10 ** decimals());
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        unchecked {
            _approve(sender, _msgSender(), currentAllowance - amount);
        }

        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(_msgSender(), spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `sender` to `recipient`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[sender] = senderBalance - amount;
        }
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);

        _afterTokenTransfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
}