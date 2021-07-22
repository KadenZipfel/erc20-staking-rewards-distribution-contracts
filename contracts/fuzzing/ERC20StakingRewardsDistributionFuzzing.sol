pragma solidity ^0.8.4;

import {
    ERC20StakingRewardsDistribution,
    IERC20StakingRewardsDistribution,
    ERC20StakingRewardsDistributionFactory,
    TestERC20,
    IERC20
} from "./FlattenedERC20StakingRewardsDistribution.sol";

contract ERC20StakingRewardsDistributionFuzzing {
    IERC20StakingRewardsDistribution internal distribution;
    address internal holder;

    constructor() {
        // Create two reward tokens and one staking token
        IERC20 token1 = new TestERC20("token1", "tkn1");
        IERC20 token2 = new TestERC20("token2", "tkn2");
        IERC20 token3 = new TestERC20("token3", "tkn3");

        // Populate reward token and amounts arrays
        address[] memory rewardTokens;
        rewardTokens[0] = address(token1);
        rewardTokens[1] = address(token2);
        uint256[] memory rewardAmounts;
        rewardAmounts[0] = uint256(1 * 10**18);
        rewardAmounts[1] = uint256(2 * 10**18);

        // Instantiate reference distribution implementation
        ERC20StakingRewardsDistribution implementation =
            new ERC20StakingRewardsDistribution();

        // Instantiate factory with reference implementation
        ERC20StakingRewardsDistributionFactory factory =
            new ERC20StakingRewardsDistributionFactory(address(implementation));

        // Create distribution
        factory.createDistribution(
            rewardTokens,
            address(token3),
            rewardAmounts,
            uint64(block.timestamp),
            uint64(block.timestamp + 10000),
            false,
            1000000000
        );

        // Store distribution
        distribution = factory.distributions(0);
    }
}
