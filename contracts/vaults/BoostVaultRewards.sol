//SPDX-License-Identifier: MIT
/*
* MIT License
* ===========
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

pragma solidity 0.5.17;

import "../SafeMath.sol";
import "../zeppelin/SafeERC20.sol";
import "./IController.sol";
import "./IVaultRewards.sol";
import "../LPTokenWrapper.sol";


contract BoostVaultRewards is LPTokenWrapper, IVaultRewards {
    struct EpochRewards {
        uint256 rewardsAvailable;
        uint256 rewardsClaimed;
        uint256 rewardPerToken;
    }

    IERC20 public boostToken;
    IERC20 public want;
    IController public controller;
    
    EpochRewards public previousEpoch;
    EpochRewards public currentEpoch;
    mapping(address => uint256) public previousEpochUserRewardPerTokenPaid;
    mapping(address => uint256) public currentEpochUserRewardPerTokenPaid;
    mapping(address => uint256) public previousEpochRewardsClaimable;
    mapping(address => uint256) public currentEpochRewardsClaimable;

    uint256 public constant EPOCH_DURATION = 2 weeks;
    uint256 public currentEpochTime;
    uint256 public unclaimedRewards;
    
    // booster variables
    // variables to keep track of totalSupply and balances (after accounting for multiplier)
    uint256 public boostedTotalSupply;
    uint256 public lastBoostPurchase; // timestamp of lastBoostPurchase
    mapping(address => uint256) public boostedBalances;
    mapping(address => uint256) public numBoostersBought; // each booster = 5% increase in stake amt
    mapping(address => uint256) public nextBoostPurchaseTime; // timestamp for which user is eligible to purchase another booster
    mapping(address => uint256) public lastActionTime;

    uint256 public globalBoosterPrice = 1e18;
    uint256 public scaleFactor = 125;
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant DENOM = 10000;
    uint256 internal constant TREASURY_FEE = 250;

    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, uint256 reward);

    constructor(
        IERC20 _stakeToken, // bf-token
        IERC20 _boostToken,
        IController _controller
    ) public LPTokenWrapper(_stakeToken) {
        boostToken = _boostToken;
        want = IVault(address(_stakeToken)).want();
        controller = _controller;
        currentEpochTime = controller.currentEpochTime();
    }

    modifier updateEpochRewards() {
        if (block.timestamp > currentEpochTime.add(EPOCH_DURATION)) {
            currentEpochTime = currentEpochTime.add(EPOCH_DURATION);
            // update unclaimed rewards
            unclaimedRewards = unclaimedRewards.add(
                previousEpoch.rewardsAvailable.sub(previousEpoch.rewardsClaimed)
            );
            // replace previous with current epoch
            previousEpoch = currentEpoch;
            // instantiate new epoch
            currentEpoch = EpochRewards({
                rewardsAvailable: 0,
                rewardsClaimed: 0,
                rewardPerToken: 0
            });
        }
        _;
    }

    function earned(address user) external view returns (uint256) {
        return (block.timestamp > currentEpochTime + EPOCH_DURATION) ?
            _earned(user, true) :
            _earned(user, false).add(_earned(user, true));
    }

    function getReward(address user) external updateEpochRewards {
        updateClaimUserRewardAndBooster(user);
    }

    function sendUnclaimedRewards() external updateEpochRewards {
        uint256 pendingRewards = unclaimedRewards;
        unclaimedRewards = 0;
        want.safeTransfer(address(controller.vault(address(want))), pendingRewards);
    }

    function sendTreasuryBoost() external updateEpochRewards {
        // transfer all collected boost tokens to treasury
        uint256 boosterAmount = boostToken.balanceOf(address(this));
        boostToken.safeApprove(address(controller.treasury()), boosterAmount);
        controller.treasury().deposit(boostToken, boosterAmount);
    }
    
    function boost() external updateEpochRewards {
        require(
            block.timestamp > nextBoostPurchaseTime[msg.sender],
            "early boost purchase"
        );
        updateClaimUserRewardAndBooster(msg.sender);

        // save current booster price, since transfer is done last
        // since getBoosterPrice() returns new boost balance, avoid re-calculation
        (uint256 boosterAmount, uint256 newBoostBalance) = getBoosterPrice(msg.sender);
        // user's balance and boostedSupply will be changed in this function
        applyBoost(msg.sender, newBoostBalance);

        // increase hurdle rate
        controller.increaseHurdleRate(address(want));
        
        boostToken.safeTransferFrom(msg.sender, address(this), boosterAmount);
    }

    // can only be called by vault (withdrawal fee) or approved strategy
    // since funds are assumed to have been sent
    function notifyRewardAmount(uint256 reward)
        external
        updateEpochRewards
    {
        require(
            msg.sender == address(stakeToken) ||
            controller.approvedStrategies(address(want), msg.sender),
            "!authorized"
        );

        // send treasury fees
        uint256 rewardAmount = reward.mul(TREASURY_FEE).div(DENOM);
        want.safeApprove(address(controller.treasury()), rewardAmount);
        controller.treasury().deposit(want, rewardAmount);

        // distribute remaining fees
        rewardAmount = reward.sub(rewardAmount);
        currentEpoch.rewardsAvailable = currentEpoch.rewardsAvailable.add(rewardAmount);
        currentEpoch.rewardPerToken = currentEpoch.rewardPerToken.add(
            rewardAmount.mul(PRECISION).div(boostedTotalSupply)
        );
        emit RewardAdded(reward);
    }

    function getBoosterPrice(address user)
        public view returns (uint256 boosterPrice, uint256 newBoostBalance)
    {
        if (boostedTotalSupply == 0) return (0,0);

        // 5% increase for each previously user-purchased booster
        uint256 boostersBought = numBoostersBought[user];
        boosterPrice = globalBoosterPrice.mul(boostersBought.mul(5).add(100)).div(100);

        // increment boostersBought by 1
        boostersBought = boostersBought.add(1);

        // 2.5% decrease for every 2 hour interval since last global boost purchase
        boosterPrice = pow(boosterPrice, 975, 1000, (block.timestamp.sub(lastBoostPurchase)).div(2 hours));

        // adjust price based on expected increase in boost supply
        // boostersBought has been incremented by 1 already
        newBoostBalance = balanceOf(user)
            .mul(boostersBought.mul(5).add(100))
            .div(100);
        uint256 boostBalanceIncrease = newBoostBalance.sub(boostedBalances[user]);
        boosterPrice = boosterPrice
            .mul(boostBalanceIncrease)
            .mul(scaleFactor)
            .div(boostedTotalSupply);
    }

    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(uint256 amount) public updateEpochRewards {
        require(amount > 0, "Cannot stake 0");
        updateClaimUserRewardAndBooster(msg.sender);
        super.stake(amount);

        // previous boosters do not affect new amounts
        boostedBalances[msg.sender] = boostedBalances[msg.sender].add(amount);
        boostedTotalSupply = boostedTotalSupply.add(amount);
        
        // transfer token last, to follow CEI pattern
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public updateEpochRewards {
        require(amount > 0, "Cannot withdraw 0");
        updateClaimUserRewardAndBooster(msg.sender);
        super.withdraw(amount);
        
        // update boosted balance and supply
        updateBoostBalanceAndSupply(msg.sender, 0);
        stakeToken.safeTransfer(msg.sender, amount);
    }

    // simpler withdraw method, in case rewards don't update properly
    // does not claim rewards nor update user's lastActionTime
    function emergencyWithdraw(uint256 amount) public {
        super.withdraw(amount);
        // reset numBoostersBought
        numBoostersBought[msg.sender] = 0;
        // update boosted balance and supply
        updateBoostBalanceAndSupply(msg.sender, 0);
        // transfer tokens to user
        stakeToken.safeTransfer(msg.sender, amount);
    }

    function exit() public updateEpochRewards {
        withdraw(balanceOf(msg.sender));
    }
    
    function updateBoostBalanceAndSupply(address user, uint256 newBoostBalance) internal {
        // subtract existing balance from boostedSupply
        boostedTotalSupply = boostedTotalSupply.sub(boostedBalances[user]);
    
        // when applying boosts,
        // newBoostBalance has already been calculated in getBoosterPrice()
        if (newBoostBalance == 0) {
            // each booster adds 5% to current stake amount
            newBoostBalance = balanceOf(user).mul(numBoostersBought[user].mul(5).add(100)).div(100);
        }

        // update user's boosted balance
        boostedBalances[user] = newBoostBalance;
    
        // update boostedSupply
        boostedTotalSupply = boostedTotalSupply.add(newBoostBalance);
    }

    function updateClaimUserRewardAndBooster(address user) internal {
        // first, reset previous epoch stats and booster count if user's last action exceeds 1 epoch
        if (lastActionTime[user].add(EPOCH_DURATION) <= currentEpochTime) {
            previousEpochRewardsClaimable[user] = 0;
            previousEpochUserRewardPerTokenPaid[user] = 0;
            numBoostersBought[user] = 0;
        }
        // then, update user's claimable amount and booster count for the previous epoch
        if (lastActionTime[user] <= currentEpochTime) {
            previousEpochRewardsClaimable[user] = _earned(user, false);
            previousEpochUserRewardPerTokenPaid[user] = previousEpoch.rewardPerToken;
            numBoostersBought[user] = 0;
        }
        // finally, update user's claimable amount for current epoch
        currentEpochRewardsClaimable[user] = _earned(user, true);
        currentEpochUserRewardPerTokenPaid[user] = currentEpoch.rewardPerToken;
        
        // get reward claimable for previous epoch
        previousEpoch.rewardsClaimed = previousEpoch.rewardsClaimed.add(previousEpochRewardsClaimable[user]);
        uint256 reward = previousEpochRewardsClaimable[user];
        previousEpochRewardsClaimable[user] = 0;

        // get reward claimable for current epoch
        currentEpoch.rewardsClaimed = currentEpoch.rewardsClaimed.add(currentEpochRewardsClaimable[user]);
        reward = reward.add(currentEpochRewardsClaimable[user]);
        currentEpochRewardsClaimable[user] = 0;

        if (reward > 0) {
            want.safeTransfer(user, reward);
            emit RewardPaid(user, reward);
        }

        // last, update user's action timestamp
        lastActionTime[user] = block.timestamp;
    }

    function applyBoost(address user, uint256 newBoostBalance) internal {
        // increase no. of boosters bought
        numBoostersBought[user] = numBoostersBought[user].add(1);

        updateBoostBalanceAndSupply(user, newBoostBalance);
        
        // increase next purchase eligibility by an hour
        nextBoostPurchaseTime[user] = block.timestamp.add(3600);

        // increase global booster price by 1%
        globalBoosterPrice = globalBoosterPrice.mul(101).div(100);

        lastBoostPurchase = block.timestamp;
    }

    function _earned(address account, bool isCurrentEpoch) internal view returns (uint256) {
        uint256 rewardPerToken;
        uint256 userRewardPerTokenPaid;
        uint256 rewardsClaimable;
        
        if (isCurrentEpoch) {
            rewardPerToken = currentEpoch.rewardPerToken;
            userRewardPerTokenPaid = currentEpochUserRewardPerTokenPaid[account];
            rewardsClaimable = currentEpochRewardsClaimable[account];
        } else {
            rewardPerToken = previousEpoch.rewardPerToken;
            userRewardPerTokenPaid = previousEpochUserRewardPerTokenPaid[account];
            rewardsClaimable = previousEpochRewardsClaimable[account];
        }
        return
            boostedBalances[account]
                .mul(rewardPerToken.sub(userRewardPerTokenPaid))
                .div(1e18)
                .add(rewardsClaimable);
    }

   /// Imported from: https://forum.openzeppelin.com/t/does-safemath-library-need-a-safe-power-function/871/7
   /// Modified so that it takes in 3 arguments for base
   /// @return a * (b / c)^exponent 
   function pow(uint256 a, uint256 b, uint256 c, uint256 exponent) internal pure returns (uint256) {
        if (exponent == 0) {
            return a;
        }
        else if (exponent == 1) {
            return a.mul(b).div(c);
        }
        else if (a == 0 && exponent != 0) {
            return 0;
        }
        else {
            uint256 z = a.mul(b).div(c);
            for (uint256 i = 1; i < exponent; i++)
                z = z.mul(b).div(c);
            return z;
        }
    }
}
