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

import "./IController.sol";
import "./IStrategy.sol";
import "../SafeMath.sol";
import "../zeppelin/SafeERC20.sol";


contract BoostController is IController {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    struct TokenStratInfo {
        IVault vault;
        IVaultRewards rewards;
        IStrategy[] strategies;
        uint256 currentHurdleRate;
        uint256 nextHurdleRate;
        uint256 hurdleLastUpdateTime;
        uint256 harvestPrice;
        uint256 globalHarvestLastUpdateTime;
        mapping(address => uint256) harvestPercentages;
        mapping(address => uint256) harvestLastUpdateTime;
    }
    
    address public gov;
    address public strategist;
    ITreasury public treasury;
    IERC20 public boostToken;
    
    mapping(address => TokenStratInfo) public tokenStratsInfo;
    mapping(address => uint256) public capAmounts;
    mapping(address => uint256) public investedAmounts;
    mapping(address => mapping(address => bool)) public approvedStrategies;

    uint256 public currentEpochTime;
    uint256 public constant EPOCH_DURATION = 2 weeks;
    uint256 internal constant DENOM = 10000;
    uint256 internal constant HURDLE_RATE_MAX = 500; // max 5%
    uint256 internal constant BASE_HARVEST_PERCENTAGE = 50; // 0.5%
    uint256 internal constant BASE_REWARD_PERCENTAGE = 5000; // 50%
    uint256 internal constant HARVEST_PERCENTAGE_MAX = 100; // max 1% extra
    uint256 internal constant PRICE_INCREASE = 10100; // 1.01x
    uint256 internal constant EPOCH_PRICE_REDUCTION = 8000; // 0.8x

    uint256 vaultRewardChangePrice = 10e18; // initial cost of 10 boosts
    uint256 public globalVaultRewardPercentage = BASE_REWARD_PERCENTAGE;
    uint256 vaultRewardLastUpdateTime;
    
    constructor(
        address _gov,
        address _strategist,
        ITreasury _treasury,
        IERC20 _boostToken,
        uint256 _epochStart
    ) public {
        gov = _gov;
        strategist = _strategist;
        treasury = _treasury;
        boostToken = _boostToken;
        currentEpochTime = _epochStart;
    }
    
    modifier updateEpoch() {
        if (block.timestamp > currentEpochTime.add(EPOCH_DURATION)) {
            currentEpochTime = currentEpochTime.add(EPOCH_DURATION);
        }
        _;
    }

    function rewards(address token) external view returns (IVaultRewards) {
        return tokenStratsInfo[token].rewards;
    }

    function vault(address token) external view returns (IVault) {
        return tokenStratsInfo[token].vault;
    }

    function balanceOf(address token) external view returns (uint256) {
        IStrategy[] storage strategies = tokenStratsInfo[token].strategies;
        uint256 totalBalance;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalBalance = totalBalance.add(strategies[i].balanceOf());
        }
        return totalBalance;
    }

    function allowableAmount(address strategy) external view returns(uint256) {
        return capAmounts[strategy].sub(investedAmounts[strategy]);
    }

    function getHarvestInfo(
        address strategy,
        address user
    ) external view returns (
        uint256 vaultRewardPercentage,
        uint256 hurdleAmount,
        uint256 harvestPercentage
    ) {
        address token = IStrategy(strategy).want();
        vaultRewardPercentage = globalVaultRewardPercentage;
        hurdleAmount = getHurdleAmount(strategy, token);
        harvestPercentage = getHarvestPercentage(user, token);
    }

    function getHarvestUserInfo(address user, address token)
        external
        view
        returns (uint256 harvestPercentage, uint256 lastUpdateTime)
    {
        TokenStratInfo storage info = tokenStratsInfo[token];
        harvestPercentage = info.harvestPercentages[user];
        lastUpdateTime = info.harvestLastUpdateTime[user];
    }

    function getStrategies(address token) external view returns (IStrategy[] memory strategies) {
        return tokenStratsInfo[token].strategies;
    }

    function setTreasury(ITreasury _treasury) external updateEpoch {
        require(msg.sender == gov, "!gov");
        treasury = _treasury;
    }
    
    function setStrategist(address _strategist) external updateEpoch {
        require(msg.sender == gov, "!gov");
        strategist = _strategist;
    }
    
    function setGovernance(address _gov) external updateEpoch {
        require(msg.sender == gov, "!gov");
        gov = _gov;
    }

    function setRewards(IVaultRewards _rewards) external updateEpoch {
        require(msg.sender == strategist || msg.sender == gov, "!authorized");
        address token = address(_rewards.want());
        require(tokenStratsInfo[token].rewards == IVaultRewards(0), "rewards exists");
        tokenStratsInfo[token].rewards = _rewards;
    }
    
    function setVaultAndInitHarvestInfo(IVault _vault) external updateEpoch {
        require(msg.sender == strategist || msg.sender == gov, "!authorized");
        address token = address(_vault.want());
        TokenStratInfo storage info = tokenStratsInfo[token];
        require(info.vault == IVault(0), "vault exists");
        info.vault = _vault;
        // initial harvest booster price of 1 boost
        info.harvestPrice = 1e18;
        info.globalHarvestLastUpdateTime = currentEpochTime;
    }
    
    function approveStrategy(address _strategy, uint256 _cap) external updateEpoch {
        require(msg.sender == gov, "!gov");
        address token = IStrategy(_strategy).want();
        require(!approvedStrategies[token][_strategy], "strat alr approved");
        require(tokenStratsInfo[token].vault.want() == IERC20(token), "unequal wants");
        capAmounts[_strategy] = _cap;
        tokenStratsInfo[token].strategies.push(IStrategy(_strategy));
        approvedStrategies[token][_strategy] = true;
    }
    
    function changeCap(address strategy, uint256 _cap) external updateEpoch {
        require(msg.sender == gov, "!gov");
        capAmounts[strategy] = _cap;
    }

    function revokeStrategy(address _strategy, uint256 _index) external updateEpoch {
        require(msg.sender == gov, "!gov");
        address token = IStrategy(_strategy).want();
        require(approvedStrategies[token][_strategy], "strat alr revoked");
        IStrategy[] storage tokenStrategies = tokenStratsInfo[token].strategies;
        require(address(tokenStrategies[_index]) == _strategy, "wrong index");

        // replace revoked strategy with last element in array
        tokenStrategies[_index] = tokenStrategies[tokenStrategies.length - 1];
        delete tokenStrategies[tokenStrategies.length - 1];
        tokenStrategies.length--;
        capAmounts[_strategy] = 0;
        approvedStrategies[token][_strategy] = false;

        // withdraw all funds in strategy back to vault
        withdrawAll(_strategy);
    }
    
    function getHurdleAmount(address strategy, address token) public view returns (uint256) {
        TokenStratInfo storage info = tokenStratsInfo[token];
        return (info.hurdleLastUpdateTime < currentEpochTime ||
        (block.timestamp > currentEpochTime.add(EPOCH_DURATION))) ?
            0 :
            info.currentHurdleRate
            .mul(investedAmounts[strategy])
            .div(DENOM);
    }

    function getHarvestPercentage(address user, address token) public view returns (uint256) {
        TokenStratInfo storage info = tokenStratsInfo[token];
        return (info.harvestLastUpdateTime[user] < currentEpochTime || 
            (block.timestamp > currentEpochTime.add(EPOCH_DURATION))) ?
            BASE_HARVEST_PERCENTAGE :
            info.harvestPercentages[user];
    }

    /// @dev check that vault has sufficient funds is done by the call to vault
    function earn(address strategy, uint256 amount) public updateEpoch {
        require(msg.sender == strategy, "!strategy");
        address token = IStrategy(strategy).want();
        require(approvedStrategies[token][strategy], "strat !approved");
        TokenStratInfo storage info = tokenStratsInfo[token];
        uint256 newInvestedAmount = investedAmounts[strategy].add(amount);
        require(newInvestedAmount <= capAmounts[strategy], "hit strategy cap");
        // update invested amount
        investedAmounts[strategy] = newInvestedAmount;
        // transfer funds to strategy
        info.vault.transferFundsToStrategy(strategy, amount);
    }
    
    // Anyone can withdraw non-core strategy tokens => sent to treasury
    function earnMiscTokens(IStrategy strategy, IERC20 token) external updateEpoch {
        // should send tokens to this contract
        strategy.withdraw(address(token));
        uint256 bal = token.balanceOf(address(this));
        token.safeApprove(address(treasury), bal);
        // send funds to treasury
        treasury.deposit(token, bal);
    }

    function increaseHarvestPercentage(address token) external updateEpoch {
        TokenStratInfo storage info = tokenStratsInfo[token];
        // first, handle vault global price and update time
        // if new epoch, reduce price by 20%
        if (info.globalHarvestLastUpdateTime < currentEpochTime) {
            info.harvestPrice = info.harvestPrice.mul(EPOCH_PRICE_REDUCTION).div(DENOM);
        }

        // get funds from user, send to treasury
        boostToken.safeTransferFrom(msg.sender, address(this), info.harvestPrice);
        boostToken.safeApprove(address(treasury), info.harvestPrice);
        treasury.deposit(boostToken, info.harvestPrice);

        // increase price
        info.harvestPrice = info.harvestPrice.mul(PRICE_INCREASE).div(DENOM);
        // update globalHarvestLastUpdateTime
        info.globalHarvestLastUpdateTime = block.timestamp;

        // next, handle effect on harvest percentage and update user's harvest time
        // see if percentage needs to be reset
        if (info.harvestLastUpdateTime[msg.sender] < currentEpochTime) {
            info.harvestPercentages[msg.sender] = BASE_HARVEST_PERCENTAGE;
        }
        info.harvestLastUpdateTime[msg.sender] = block.timestamp;

        // increase harvest percentage by 0.25%
        info.harvestPercentages[msg.sender] = Math.min(
            HARVEST_PERCENTAGE_MAX,
            info.harvestPercentages[msg.sender].add(25)
        );
        increaseHurdleRate(token);
    }

    function changeVaultRewardPercentage(bool isIncrease) external updateEpoch {
        // if new epoch, reduce price by 20%
        if ((vaultRewardLastUpdateTime != 0) && (vaultRewardLastUpdateTime < currentEpochTime)) {
            vaultRewardChangePrice = vaultRewardChangePrice.mul(EPOCH_PRICE_REDUCTION).div(DENOM);
        }

        // get funds from user, send to treasury
        boostToken.safeTransferFrom(msg.sender, address(this), vaultRewardChangePrice);
        boostToken.safeApprove(address(treasury), vaultRewardChangePrice);
        treasury.deposit(boostToken, vaultRewardChangePrice);

        // increase price
        vaultRewardChangePrice = vaultRewardChangePrice.mul(PRICE_INCREASE).div(DENOM);
        // update vaultRewardLastUpdateTime
        vaultRewardLastUpdateTime = block.timestamp;
        if (isIncrease) {
            globalVaultRewardPercentage = Math.min(DENOM, globalVaultRewardPercentage.add(25));
        } else {
            globalVaultRewardPercentage = globalVaultRewardPercentage.sub(25);
        }
    }
    
    // handle vault withdrawal
    function withdraw(address token, uint256 withdrawAmount) external updateEpoch {
        TokenStratInfo storage info = tokenStratsInfo[token];
        require(msg.sender == (address(info.vault)), "!vault");
        uint256 remainingWithdrawAmount = withdrawAmount;

        for (uint256 i = 0; i < info.strategies.length; i++) {
            if (remainingWithdrawAmount == 0) break;
            IStrategy strategy = info.strategies[i];
            // withdraw maximum amount possible
            uint256 actualWithdrawAmount = Math.min(
                investedAmounts[address(strategy)], remainingWithdrawAmount
            );
            // update remaining withdraw amt
            remainingWithdrawAmount = remainingWithdrawAmount.sub(actualWithdrawAmount);
            // update strat invested amt
            investedAmounts[address(strategy)] = investedAmounts[address(strategy)]
                    .sub(actualWithdrawAmount);
            // do the actual withdrawal
            strategy.withdraw(actualWithdrawAmount);
        }
    }

    function increaseHurdleRate(address token) public updateEpoch {
        TokenStratInfo storage info = tokenStratsInfo[token];
        require(msg.sender == address(info.rewards) || msg.sender == address(this), "!authorized");
        // see if hurdle rate has to update
        if (info.hurdleLastUpdateTime < currentEpochTime) {
            info.currentHurdleRate = info.nextHurdleRate;
            info.nextHurdleRate = 0;
        }
        info.hurdleLastUpdateTime = block.timestamp;
        // increase hurdle rate by 0.01%
        info.nextHurdleRate = Math.min(HURDLE_RATE_MAX, info.nextHurdleRate.add(1));
    }

    function withdrawAll(address strategy) public updateEpoch {
        require(
            msg.sender == strategist ||
            msg.sender == gov ||
            msg.sender == address(this),
            "!authorized"
        );
        investedAmounts[strategy] = 0;
        IStrategy(strategy).withdrawAll();
    }
    
    function inCaseTokensGetStuck(address token, uint amount) public updateEpoch {
        require(msg.sender == strategist || msg.sender == gov, "!authorized");
        IERC20(token).safeTransfer(msg.sender, amount);
    }
    
    function inCaseStrategyTokenGetStuck(IStrategy strategy, address token) public updateEpoch {
        require(msg.sender == strategist || msg.sender == gov, "!authorized");
        strategy.withdraw(token);
    }
}
