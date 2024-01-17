// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title CompoundStake
/// @notice This contract harvests staking rewards, swaps to WSX and restakes in a single tx to earn compounded rewards.
abstract contract ICompoundStakeProxy {
    /// @notice Compound stakes based on the provided token addresses and corresponding amountOutMin amounts
    /// @param tokenAddrs The array of reward token addresses
    /// @param amountOutMins The array of reward token minimum swap output amounts
    function harvestAndCompoundStake(
        address[] memory tokenAddrs,
        uint256[] memory amountOutMins
    ) external virtual;
}
