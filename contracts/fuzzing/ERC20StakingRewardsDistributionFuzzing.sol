pragma solidity ^0.8.4;

import {
    ERC20StakingRewardsDistribution,
    ERC20StakingRewardsDistributionFactory,
    TestERC20,
    IERC20
} from "./FlattenedERC20StakingRewardsDistribution.sol";

contract ERC20StakingRewardsDistributionFuzzing {
    ERC20StakingRewardsDistribution internal distribution;
    address internal holder;
    address[] rewardTokens;
    uint256[] rewardAmounts;

    IERC20 token1;
    IERC20 token2;
    IERC20 token3;

    constructor() {
        // Create two reward tokens and one staking token
        token1 = new TestERC20("token1", "tkn1");
        token2 = new TestERC20("token2", "tkn2");
        token3 = new TestERC20("token3", "tkn3");

        // Populate reward token and amounts arrays
        rewardTokens.push(address(token1));
        rewardTokens.push(address(token2));
        rewardAmounts.push(uint256(1 * 10**18));
        rewardAmounts.push(uint256(2 * 10**18));

        // Instantiate reference distribution implementation
        ERC20StakingRewardsDistribution implementation =
            new ERC20StakingRewardsDistribution();

        // Instantiate factory with reference implementation
        ERC20StakingRewardsDistributionFactory factory =
            new ERC20StakingRewardsDistributionFactory(address(implementation));

        // Approve reward tokens to factory
        token1.approve(address(factory), 1 * 10**18);
        token2.approve(address(factory), 2 * 10**18);

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
        distribution = ERC20StakingRewardsDistribution(
            address(factory.distributions(0))
        );

        // Approve staking token to distribution
        token3.approve(address(distribution), 10000 * 10**18);
    }

    // Test stake function
    function stake(uint256 amount) public {
        uint256 stakingTokenBalanceBefore = token3.balanceOf(address(this));
        distribution.stake(amount);
        uint256 stakingTokenBalanceAfter = token3.balanceOf(address(this));

        assert(stakingTokenBalanceBefore == amount + stakingTokenBalanceAfter);
    }

    function falsePositive() public pure {
        assert(2 + 2 == 5);
    }
}
