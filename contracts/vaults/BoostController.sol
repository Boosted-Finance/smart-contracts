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


contract Controller is IController {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    struct TokenStratInfo {
        IVault vault;
        IVaultRewards rewards;
        IStrategy[] strategies;
        uint256 vaultRewardPercentage;
        uint256 currentHurdleRate;
        uint256 nextHurdleRate;
        uint256 hurdleLastUpdateTime;
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
    uint256 internal constant BASE_REWARD_PERCENTAGE = 8000; // 80%
    uint256 internal constant HARVEST_PERCENTAGE_MAX = 100; // max 1% extra
    
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
        boostToken.safeApprove(address(treasury), uint256(-1));
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

    function getHarvestInfo(
        address strategy,
        address user
    ) external view returns (
        uint256 vaultRewardPercentage,
        uint256 hurdleAmount,
        uint256 harvestPercentage
    ) {
        address token = IStrategy(strategy).want();
        vaultRewardPercentage = tokenStratsInfo[token].vaultRewardPercentage;
        hurdleAmount = getHurdleAmount(strategy, token);
        harvestPercentage = getHarvestPercentage(user, token);
    }

    function setTreasury(ITreasury _treasury) updateEpoch external {
        require(msg.sender == gov, "!gov");
        boostToken.safeApprove(address(treasury), 0);
        treasury = _treasury;
        boostToken.safeApprove(address(treasury), uint256(-1));
    }
    
    function setStrategist(address _strategist) updateEpoch external {
        require(msg.sender == gov, "!gov");
        strategist = _strategist;
    }
    
    function setGovernance(address _gov) updateEpoch external {
        require(msg.sender == gov, "!gov");
        gov = _gov;
    }

    function setRewards(IVaultRewards _rewards) updateEpoch external {
        require(msg.sender == strategist || msg.sender == gov, "!authorized");
        address token = address(_rewards.want());
        require(tokenStratsInfo[token].rewards == IVaultRewards(0), "rewards exists");
        tokenStratsInfo[token].rewards = _rewards;
    }
    
    function setVaultAndInitRewardPercentage(IVault _vault) updateEpoch external {
        require(msg.sender == strategist || msg.sender == gov, "!authorized");
        address token = address(_vault.want());
        require(tokenStratsInfo[token].vault == IVault(0), "vault exists");
        tokenStratsInfo[token].vault = _vault;
        tokenStratsInfo[token].vaultRewardPercentage = BASE_REWARD_PERCENTAGE;
    }
    
    function approveStrategy(address _strategy, uint256 _cap) updateEpoch external {
        require(msg.sender == gov, "!gov");
        address token = IStrategy(_strategy).want();
        require(!approvedStrategies[token][_strategy], "strat alr approved");
        require(tokenStratsInfo[token].vault.want() == IERC20(token), "unequal wants");
        capAmounts[_strategy] = _cap;
        tokenStratsInfo[token].strategies.push(IStrategy(_strategy));
        approvedStrategies[token][_strategy] = true;
    }
    
    function changeCap(address strategy, uint256 _cap) updateEpoch external {
        require(msg.sender == gov, "!gov");
        capAmounts[strategy] = _cap;
    }

    function revokeStrategy(address _strategy, uint256 _index) updateEpoch external {
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
    function earn(address strategy, uint256 amount) updateEpoch public {
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
    function earnMiscTokens(IStrategy strategy, IERC20 token) updateEpoch external {
        // should send tokens to this contract
        strategy.withdraw(address(token));
        uint256 bal = token.balanceOf(address(this));
        // send funds to treasury
        treasury.deposit(token, bal);
    }

    function increaseHarvestPercentage(address token) updateEpoch external {
        // TODO: implement pricing
        // TODO: send boost tokens to treasury
        TokenStratInfo storage info = tokenStratsInfo[token];
        require(msg.sender == address(info.rewards), "!rewards");
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

    function changeVaultRewardPercentage(address token, bool isIncrease) updateEpoch external {
        // flat cost of 1 boost
        // TODO: maybe change to increasing price per epoch
        boostToken.safeTransferFrom(msg.sender, address(this), 1e18);
        treasury.deposit(boostToken, 1e18);
        TokenStratInfo storage info = tokenStratsInfo[token];
        if (isIncrease) {
            info.vaultRewardPercentage = Math.min(DENOM, info.vaultRewardPercentage.add(10));
        } else {
            info.vaultRewardPercentage = info.vaultRewardPercentage.sub(10);
        }
    }
    
    // handle vault withdrawal
    function withdraw(address token, uint256 withdrawAmount) updateEpoch external {
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
            remainingWithdrawAmount = remainingWithdrawAmount.sub(actualWithdrawAmount);
            investedAmounts[address(strategy)] = investedAmounts[address(strategy)]
                    .sub(remainingWithdrawAmount);
            // do the actual withdrawal
            strategy.withdraw(actualWithdrawAmount);
        }
    }

    function increaseHurdleRate(address token) updateEpoch public {
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

    function withdrawAll(address strategy) updateEpoch public {
        require(
            msg.sender == strategist ||
            msg.sender == gov ||
            msg.sender == address(this),
            "!authorized"
        );
        investedAmounts[strategy] = 0;
        IStrategy(strategy).withdrawAll();
    }
    
    function inCaseTokensGetStuck(address token, uint amount) updateEpoch public {
        require(msg.sender == strategist || msg.sender == gov, "!authorized");
        IERC20(token).safeTransfer(msg.sender, amount);
    }
    
    function inCaseStrategyTokenGetStuck(IStrategy strategy, address token) updateEpoch public {
        require(msg.sender == strategist || msg.sender == gov, "!authorized");
        strategy.withdraw(token);
    }
}
