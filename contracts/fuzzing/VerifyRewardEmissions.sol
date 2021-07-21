pragma solidity ^0.8.4;

import "./FlattenedERC20StakingRewardsDistribution.sol";

contract VerifyRewardEmissions is ERC20StakingRewardsDistribution {
    constructor() public {}

    // Assert the total staked tokens * reward per staked token == total reward amount
    function echidna_validRewardPerStakedToken() public view returns (bool) {
        for (uint256 i = 0; i < rewards.length; i++) {
            if (
                rewards[i].perStakedToken > 0 &&
                rewards[i].amount / rewards[i].perStakedToken !=
                totalStakedTokensAmount
            ) {
                return false;
            }
        }
        return true;
    }

    function echidna_boundedUnassignedRewards() public view returns (bool) {
        for (uint256 i = 0; i < rewards.length; i++) {
            if (
                rewards[i].unassigned <
                (rewards[i].amount *
                    ((endingTimestamp - block.timestamp) /
                        (endingTimestamp - startingTimestamp)))
            ) {
                return false;
            }

            if (
                rewards[i].unassigned >
                IERC20(rewards[i].token).balanceOf(address(this))
            ) {
                return false;
            }
        }
        return true;
    }
}
