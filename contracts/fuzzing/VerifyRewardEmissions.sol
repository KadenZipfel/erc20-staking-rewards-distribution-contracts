pragma solidity ^0.8.4;

import "./FlattenedERC20StakingRewardsDistribution.sol";

contract VerifyRewardEmissions is ERC20StakingRewardsDistribution {
    // Assert the total staked tokens * reward per staked token == total reward amount
    function echidna_validRewardPerStakedToken() public view returns (bool) {
        for (uint256 i = 0; i < rewards.length; i++) {
            if (
                rewards[i].amount / rewards[i].perStakedToken !=
                totalStakedTokensAmount
            ) {
                return false;
            }
        }
        return true;
    }
}
