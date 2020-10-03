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

import "./SafeMath.sol";
import "./zeppelin/SafeERC20.sol";
import "./IERC20.sol";
import "./IGov.sol";
import "./ITreasury.sol";
import "./ISwapRouter.sol";
import "./LPTokenWrapperWithSlash.sol";


contract BoostGovV2 is IGov, LPTokenWrapperWithSlash {
    IERC20 public stablecoin;
    ITreasury public treasury;
    SwapRouter public swapRouter;
    
    // 1% = 100
    uint256 public constant MIN_QUORUM_PUNISHMENT = 500; // 5%
    uint256 public constant MIN_QUORUM_THRESHOLD = 3000; // 30%
    uint256 public constant PERCENTAGE_PRECISION = 10000;
    uint256 public constant WITHDRAW_THRESHOLD = 1e21; // 1000 yCRV

    mapping(address => uint256) public voteLock; // timestamp that boost stakes are locked after voting
    
    struct Proposal {
        address proposer;
        address withdrawAddress;
        uint256 withdrawAmount;
        mapping(address => uint256) forVotes;
        mapping(address => uint256) againstVotes;
        uint256 totalForVotes;
        uint256 totalAgainstVotes;
        uint256 totalSupply;
        uint256 start; // block start;
        uint256 end; // start + period
        string url;
        string title;
    }

    // reward variables
    uint256 public constant DURATION = 3 days;
    uint256 public starttime;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    IERC20 public boostToken;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // gov variables
    mapping (uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    uint256 public constant PROPOSAL_PERIOD = 2 days;
    uint256 public constant LOCK_PERIOD = 3 days;
    uint256 public minimum = 1337e16; // 13.37 BOOST

    constructor(IERC20 _stakeToken, ITreasury _treasury, SwapRouter _swapRouter)
        public
        LPTokenWrapperWithSlash(_stakeToken)
    {
        boostToken = _stakeToken;
        treasury = _treasury;
        stablecoin = treasury.defaultToken();
        stablecoin.safeApprove(address(treasury), uint256(-1));
        stakeToken.safeApprove(address(_swapRouter), uint256(-1));
        swapRouter = _swapRouter;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function notifyRewardAmount(uint256 reward)
        external
        updateReward(address(0))
    {
        require(msg.sender == address(treasury), "!treasury");
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(DURATION);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(DURATION);
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(DURATION);
    }

    function propose(
        string calldata _url,
        string calldata _title,
        uint256 _withdrawAmount,
        address _withdrawAddress
    ) external {
        require(balanceOf(msg.sender) > minimum, "stake more boost");
        proposals[proposalCount++] = Proposal({
            proposer: msg.sender,
            withdrawAddress: _withdrawAddress,
            withdrawAmount: _withdrawAmount,
            totalForVotes: 0,
            totalAgainstVotes: 0,
            totalSupply: 0,
            start: block.timestamp,
            end: PROPOSAL_PERIOD.add(block.timestamp),
            url: _url,
            title: _title
            });
        voteLock[msg.sender] = LOCK_PERIOD.add(block.timestamp);
        _getReward(msg.sender);
    }

    function voteFor(uint256 id) external updateReward(msg.sender) {
        require(proposals[id].start < block.timestamp , "<start");
        require(proposals[id].end > block.timestamp , ">end");
        require(proposals[id].againstVotes[msg.sender] == 0, "cannot switch votes");
        uint256 userVotes = Math.sqrt(balanceOf(msg.sender));
        uint256 votes = userVotes.sub(proposals[id].forVotes[msg.sender]);
        proposals[id].totalForVotes = proposals[id].totalForVotes.add(votes);
        proposals[id].forVotes[msg.sender] = userVotes;

        voteLock[msg.sender] = LOCK_PERIOD.add(block.timestamp);
        _getReward(msg.sender);
    }

    function voteAgainst(uint256 id) external updateReward(msg.sender) {
        require(proposals[id].start < block.timestamp , "<start");
        require(proposals[id].end > block.timestamp , ">end");
        require(proposals[id].forVotes[msg.sender] == 0, "cannot switch votes");
        uint256 userVotes = Math.sqrt(balanceOf(msg.sender));
        uint256 votes = userVotes.sub(proposals[id].againstVotes[msg.sender]);
        proposals[id].totalAgainstVotes = proposals[id].totalAgainstVotes.add(votes);
        proposals[id].againstVotes[msg.sender] = userVotes;

        voteLock[msg.sender] = LOCK_PERIOD.add(block.timestamp);
        _getReward(msg.sender);
    }

    function stake(uint256 amount) public updateReward(msg.sender) {
        super.stake(amount);
        _getReward(msg.sender);
    }

    function withdraw(uint256 amount) public updateReward(msg.sender) {
        require(voteLock[msg.sender] < block.timestamp, "tokens locked");
        super.withdraw(amount);
    }

    function exit() public updateReward(msg.sender) {
        require(voteLock[msg.sender] < block.timestamp, "tokens locked");
        withdraw(balanceOf(msg.sender));
        _getReward(msg.sender);
    }

    function resolveProposal(uint256 id) public updateReward(msg.sender) {
        require(proposals[id].proposer != address(0), "non-existent proposal");
        require(proposals[id].end < block.timestamp , "ongoing proposal");
        require(proposals[id].totalSupply == 0, "already resolved");

        // update proposal total supply
        proposals[id].totalSupply = Math.sqrt(totalSupply());

        // sum votes, multiply by precision, divide by square rooted total supply
        uint256 quorum = 
            (proposals[id].totalForVotes.add(proposals[id].totalAgainstVotes))
            .mul(PERCENTAGE_PRECISION)
            .div(proposals[id].totalSupply);

        if ((quorum < MIN_QUORUM_PUNISHMENT) && proposals[id].withdrawAmount > WITHDRAW_THRESHOLD) {
            // user's stake gets slashed, converted to stablecoin and sent to treasury
            uint256 amount = slash(proposals[id].proposer);
            convertAndSendTreasuryFunds(amount);
        } else if (
            (quorum > MIN_QUORUM_THRESHOLD) &&
            (proposals[id].totalForVotes > proposals[id].totalAgainstVotes)
         ) {
            // treasury to send funds to proposal
            treasury.withdraw(
                proposals[id].withdrawAmount,
                proposals[id].withdrawAddress
            );
        }
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(totalSupply())
            );
    }

    function earned(address account) public view returns (uint256) {
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }
    
    function convertAndSendTreasuryFunds(uint256 amount) internal {
        address[] memory routeDetails = new address[](3);
        routeDetails[0] = address(stakeToken);
        routeDetails[1] = swapRouter.WETH();
        routeDetails[2] = address(stablecoin);
        uint[] memory amounts = swapRouter.swapExactTokensForTokens(
            amount,
            0,
            routeDetails,
            address(this),
            block.timestamp + 100
        );
        // 0 = input token amt, 1 = weth output amt, 2 = stablecoin output amt
        treasury.deposit(stablecoin, amounts[2]);
    }

    function _getReward(address user) internal {
        uint256 reward = earned(user);
        if (reward > 0) {
            rewards[user] = 0;
            boostToken.safeTransfer(user, reward);
        }
    }
}
