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

import "./IVaultRewards.sol";
import "../IERC20Burnable.sol";
import "../zeppelin/ReentrancyGuard.sol";
import "../zeppelin/SafeERC20.sol";
import "../SafeMath.sol";
import "./Admin.sol";

contract BoostVaultRewards is Admin, ReentrancyGuard, IVaultRewards {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    struct Reward {
        mapping(address => bool) rewardDistributors;
        uint256 rewardsDuration;
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    mapping(address => Reward) public rewardData;
    address[] public rewardTokens;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    IERC20 public vaultToken;
    IERC20 public boostToken;
    address treasury;

    uint256 private _boostedTotalSupply;
    mapping(address => uint256) private _boostedBalances;

    mapping(address => uint256) public numBoostersBought; // each booster = 5% increase in stake amt
    mapping(address => uint256) public nextBoostPurchaseTime; // timestamp for which user is eligible to purchase another booster
    uint256 public lastBoostPurchase; // timestamp of last purchased boost
    uint256 public globalBoosterPrice = 1e18;
    uint256 public boostThreshold = 10;
    uint256 public boostScaleFactor = 20;
    uint256 public scaleFactor = 320;

    constructor(IERC20 _boostToken, address _treasury) public {
        boostToken = _boostToken;
        treasury = _treasury;
    }

    function setVaultToken(IERC20 _vaultToken) external onlyAdmin {
        vaultToken = _vaultToken;
    }

    function setTreasury(address _treasury) external onlyAdmin {
        treasury = _treasury;
    }

    function addRewardConfig(address _rewardsToken, uint256 _rewardsDuration) external onlyAdmin {
        require(rewardData[_rewardsToken].rewardsDuration == 0);
        rewardTokens.push(_rewardsToken);
        rewardData[_rewardsToken].rewardsDuration = _rewardsDuration;
    }

    function setScaleFactorsAndThreshold(
        uint256 _boostThreshold,
        uint256 _boostScaleFactor,
        uint256 _scaleFactor
    ) external onlyAdmin
    {
        boostThreshold = _boostThreshold;
        boostScaleFactor = _boostScaleFactor;
        scaleFactor = _scaleFactor;
    }

    function setRewardDistributor(
        address _rewardsToken,
        address[] calldata _rewardsDistributors,
        bool[] calldata _authorized
    ) external onlyAdmin {
        require(_rewardsDistributors.length == _authorized.length, "bad length");
        for (uint i; i < _rewardsDistributors.length; i++) {
            rewardData[_rewardsToken].rewardDistributors[_rewardsDistributors[i]] = _authorized[i];
        }
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view returns (uint256) {
        return _boostedTotalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _boostedBalances[account];
    }

    function getRewardForDuration(address _rewardsToken) external view returns (uint256) {
        return rewardData[_rewardsToken].rewardRate.mul(rewardData[_rewardsToken].rewardsDuration);
    }

    function lastTimeRewardApplicable(address _rewardsToken) public view returns (uint256) {
        return Math.min(block.timestamp, rewardData[_rewardsToken].periodFinish);
    }

    function rewardPerToken(address _rewardsToken) public view returns (uint256) {
        if (_boostedTotalSupply == 0) {
            return rewardData[_rewardsToken].rewardPerTokenStored;
        }
        return
            rewardData[_rewardsToken].rewardPerTokenStored.add(
                lastTimeRewardApplicable(_rewardsToken)
                    .sub(rewardData[_rewardsToken].lastUpdateTime)
                    .mul(rewardData[_rewardsToken].rewardRate)
                    .mul(1e18)
                    .div(_boostedTotalSupply)
            );
    }

    function earned(address account, address _rewardsToken) public view returns (uint256) {
        return
            _boostedBalances[account]
                .mul(
                rewardPerToken(_rewardsToken).sub(userRewardPerTokenPaid[account][_rewardsToken])
            )
                .div(1e18)
                .add(rewards[account][_rewardsToken]);
    }

    function getBoosterPrice(address user)
        public view returns (uint256 boosterPrice, uint256 newBoostBalance)
    {
        if (_boostedTotalSupply == 0) return (0,0);

        // 5% increase for each previously user-purchased booster
        uint256 boostersBought = numBoostersBought[user];
        boosterPrice = globalBoosterPrice.mul(boostersBought.mul(5).add(100)).div(100);

        // increment boostersBought by 1
        boostersBought = boostersBought.add(1);

        // if no. of boosters exceed threshold, increase booster price by boostScaleFactor;
        if (boostersBought >= boostThreshold) {
            boosterPrice = boosterPrice
                .mul((boostersBought.sub(boostThreshold)).mul(boostScaleFactor).add(100))
                .div(100);
        }

        // 2.5% decrease for every 2 hour interval since last global boost purchase
        boosterPrice = pow(boosterPrice, 975, 1000, (block.timestamp.sub(lastBoostPurchase)).div(2 hours));

        // adjust price based on expected increase in boost supply
        // boostersBought has been incremented by 1 already
        newBoostBalance = _boostedBalances[user]
            .mul(boostersBought.mul(5).add(100))
            .div(100);
        uint256 boostBalanceIncrease = newBoostBalance.sub(_boostedBalances[user]);
        boosterPrice = boosterPrice
            .mul(boostBalanceIncrease)
            .mul(scaleFactor)
            .div(_boostedTotalSupply);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function updateStake(address user) external nonReentrant updateReward(msg.sender) {
        require(msg.sender == address(vaultToken), "not authorized");
        // update user boost balance and boost total supply
        updateBoostBalanceAndSupply(user, 0, true);
    }

    function boost() external updateReward(msg.sender) {
        require(block.timestamp > nextBoostPurchaseTime[msg.sender], "early boost purchase");

        // save current booster price, since transfer is done last
        // since getBoosterPrice() returns new boost balance, avoid re-calculation
        (uint256 boosterAmount, uint256 newBoostBalance) = getBoosterPrice(msg.sender);
        // user's balance and boostedSupply will be changed in this function
        applyBoost(msg.sender, newBoostBalance);

        getReward();

        boostToken.safeTransferFrom(msg.sender, address(this), boosterAmount);

        IERC20Burnable burnableBoostToken = IERC20Burnable(address(boostToken));

        // burn 25%
        uint256 burnAmount = boosterAmount.div(4);
        burnableBoostToken.burn(burnAmount);
        boosterAmount = boosterAmount.sub(burnAmount);

        // transfer the rest to treasury (multisig)
        boostToken.transfer(treasury, boosterAmount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        for (uint256 i; i < rewardTokens.length; i++) {
            address _rewardsToken = rewardTokens[i];
            uint256 reward = rewards[msg.sender][_rewardsToken];
            if (reward > 0) {
                rewards[msg.sender][_rewardsToken] = 0;
                IERC20(_rewardsToken).safeTransfer(msg.sender, reward);
                emit RewardPaid(msg.sender, _rewardsToken, reward);
            }
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function notifyRewardAmount(address _rewardsToken, uint256 reward)
        external
        updateReward(address(0))
    {
        require(rewardData[_rewardsToken].rewardDistributors[msg.sender], "not authorized");
        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the reward amount
        IERC20(_rewardsToken).safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= rewardData[_rewardsToken].periodFinish) {
            rewardData[_rewardsToken].rewardRate = reward.div(
                rewardData[_rewardsToken].rewardsDuration
            );
        } else {
            uint256 remaining = rewardData[_rewardsToken].periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardData[_rewardsToken].rewardRate);
            rewardData[_rewardsToken].rewardRate = reward.add(leftover).div(
                rewardData[_rewardsToken].rewardsDuration
            );
        }

        rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        rewardData[_rewardsToken].periodFinish = block.timestamp.add(
            rewardData[_rewardsToken].rewardsDuration
        );
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyAdmin {
        require(tokenAddress != address(vaultToken), "Cannot withdraw staking token");
        require(rewardData[tokenAddress].lastUpdateTime == 0, "Cannot withdraw reward token");
        IERC20(tokenAddress).safeTransfer(admin, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(address _rewardsToken, uint256 _rewardsDuration) external {
        require(rewardData[_rewardsToken].rewardDistributors[msg.sender], "not authorized");
        require(
            block.timestamp > rewardData[_rewardsToken].periodFinish,
            "Reward period still active"
        );
        require(_rewardsDuration > 0, "Reward duration must be non-zero");
        rewardData[_rewardsToken].rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(_rewardsToken, rewardData[_rewardsToken].rewardsDuration);
    }

    /* ========== INTERNAL FUNCTIONS ========== */
    function updateBoostBalanceAndSupply(
        address user,
        uint256 newBoostBalance,
        bool calcBoostBal
    ) internal {
        // subtract existing balance from boostedSupply
        _boostedTotalSupply = _boostedTotalSupply.sub(_boostedBalances[user]);

        if (calcBoostBal) {
            // each booster adds 5% to current vault token amount
            newBoostBalance = vaultToken
                .balanceOf(user)
                .mul(numBoostersBought[user].mul(5).add(100))
                .div(100);
        }

        // update user's boosted balance
        _boostedBalances[user] = newBoostBalance;

        // update boostedSupply
        _boostedTotalSupply = _boostedTotalSupply.add(newBoostBalance);
    }

    function applyBoost(address user, uint256 newBoostBalance) internal {
        // increase no. of boosters bought
        numBoostersBought[user] = numBoostersBought[user].add(1);

        updateBoostBalanceAndSupply(user, newBoostBalance, false);

        // increase user's next purchase eligibility by an hour
        nextBoostPurchaseTime[user] = block.timestamp.add(3600);

        // increase global booster price by 1%
        globalBoosterPrice = globalBoosterPrice.mul(101).div(100);

        lastBoostPurchase = block.timestamp;
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

    /* ========== MODIFIERS ========== */
    modifier updateReward(address account) {
        for (uint256 i; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            rewardData[token].rewardPerTokenStored = rewardPerToken(token);
            rewardData[token].lastUpdateTime = lastTimeRewardApplicable(token);
            if (account != address(0)) {
                rewards[account][token] = earned(account, token);
                userRewardPerTokenPaid[account][token] = rewardData[token].rewardPerTokenStored;
            }
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, address indexed rewardsToken, uint256 reward);
    event RewardsDurationUpdated(address token, uint256 newDuration);
    event Recovered(address token, uint256 amount);
}
