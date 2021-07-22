pragma solidity ^0.8.4;

import {
    ERC20StakingRewardsDistribution,
    IERC20StakingRewardsDistribution,
    ERC20StakingRewardsDistributionFactory,
    TestERC20,
    IERC20
} from "./FlattenedERC20StakingRewardsDistribution.sol";

// Contract receives staking token and allows for it to be retrieved
contract Staker {
    constructor(address stakingToken, address retriever) {
        TestERC20(stakingToken).approve(retriever, type(uint256).max);
    }
}

contract ERC20StakingRewardsDistributionFuzzing {
    IERC20StakingRewardsDistribution internal distribution;
    address internal holder;

    constructor() {
        IERC20 token1 = new TestERC20("token1", "tkn1");
        IERC20 token2 = new TestERC20("token2", "tkn2");
        IERC20 token3 = new TestERC20("token3", "tkn3");

        holder = address(new Staker(address(token3), address(this)));
        token3.transfer(holder, 1 * 10**18);

        address[] memory rewardTokens;
        rewardTokens[0] = address(token1);
        rewardTokens[1] = address(token2);
        uint256[] memory rewardAmounts;
        rewardAmounts[0] = uint256(1 * 10**18);
        rewardAmounts[1] = uint256(2 * 10**18);

        ERC20StakingRewardsDistribution implementation =
            new ERC20StakingRewardsDistribution();

        ERC20StakingRewardsDistributionFactory factory =
            new ERC20StakingRewardsDistributionFactory(address(implementation));

        factory.createDistribution(
            rewardTokens,
            address(token3),
            rewardAmounts,
            uint64(block.timestamp),
            uint64(block.timestamp + 100000),
            false,
            1000000000
        );

        distribution = factory.distributions(0);
    }
}
