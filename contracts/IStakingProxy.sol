// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract IStakingProxy {
    // public interface to read these variables
    uint256 public _withdrawDelay;
    mapping(address => uint256) public _pendingWithdrawAmounts;

    // Staker to hold reference to the user staking WSX
    struct Staker {
        address addr; // The address of the staker
        uint256 amount; // The tokens quantity the user has staked.
        bool isDelegateValidator; // Whether or not account has met the minimum staked threshold to be a delegate
        uint256 delegateValidatorIndex; // For _delegateValidators array manipulation
        string name; // The delegateValidator name
        string description; // The delegateValidator description
        uint256 commission; // Commission % as defined by delegate
        uint256 delegatorStakedAmount; // The total amount staked by delegators
        uint256 delegatorCount; // The number of delegators staking in this staker
        bool isDelegator; // Whether or not this staker is delegating
        address parent; // The delegate/parent staker address
        bool enableDelegation; // whether or not this staker should allow delegators to stake under.
        bool approvedToDelegate; // whether or not this staker has been approved to stake as a delegate validator
    }

    /// @notice Returns the length of the rewardTokenList array
    function rewardTokenListLength() external view virtual returns (uint256);

    /// @notice Returns the rewardTokenList array
    function getRewardTokenList()
        external
        view
        virtual
        returns (address[] memory);

    /// @notice Stakes the specified amount for msg.sender under the specified validator
    /// @param amount The amount to stake
    /// @param validator The validator to stake under
    function stake(uint256 amount, address validator) external virtual;

    /// @notice Withdraws pending unstaked WSX once the cooldown period has elapsed
    function withdrawUnstaked() external virtual;

    /// @notice Unstakes locked funds from the validator of msg.sender
    /// @param amount The amount to unstake
    function unstake(uint256 amount) external virtual;

    /// @notice Gets the specified Staker object
    function getStaker(
        address addr
    ) external view virtual returns (Staker memory);

    /// @notice Gets the pending rewards and commission fees to be paid out (as delegator) or pending commission fees (as validator)
    /// @param tokenAddr The token address
    /// @param stakerAddr The address to derive the pending awards for
    function pendingRewards(
        address tokenAddr,
        address stakerAddr
    ) external view virtual returns (uint256, uint256);
}
