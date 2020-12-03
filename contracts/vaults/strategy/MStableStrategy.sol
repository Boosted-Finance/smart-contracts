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

import "../IStrategy.sol";
import "../IController.sol";
import "../../ISwapRouter.sol";
import "../../SafeMath.sol";
import "../../zeppelin/SafeERC20.sol";

interface IBPT {
    function totalSupply() external view returns (uint256);
    function balanceOf(address whom) external view returns (uint);
    function getSpotPrice(address tokenIn, address tokenOut) external view returns (uint spotPrice);
    function swapExactAmountIn(address, uint, address, uint, uint) external returns (uint, uint);
    function swapExactAmountOut(address, uint, address, uint, uint) external returns (uint, uint);
    function joinswapExternAmountIn(
        address tokenIn,
        uint tokenAmountIn,
        uint minPoolAmountOut
    ) external returns (uint poolAmountOut);
    function exitswapExternAmountOut(
        address tokenOut,
        uint tokenAmountOut,
        uint maxPoolAmountIn
    ) external returns (uint poolAmountIn);
    function exitswapPoolAmountIn(
        address tokenOut,
        uint poolAmountIn,
        uint minAmountOut
    ) external returns (uint tokenAmountOut);
}

interface IMPool {
    function balanceOf(address _account) external view returns (uint256);
    function earned(address _account) external view returns (uint256, uint256);
    function stake(uint256 _amount) external;
    function claimReward() external;
    function exit() external;
}

interface IMTAGov {
    function balanceOf(address _account) external view returns (uint256);
    function earned(address _account) external view returns (uint256);
    function createLock(uint256 _value, uint256 _unlockTime) external;
    function withdraw() external;
    function increaseLockAmount(uint256 _value) external;
    function claimReward() external;
}


contract MStableStrat is IStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 public constant PERFORMANCE_FEE = 500; // 5%
    uint256 public constant DENOM = 10000;
    uint256 public hurdleLastUpdateTime;
    uint256 public harvestAmountThisEpoch;
    uint256 public strategistCollectedFee;
    uint256 public numPools = 1;

    IERC20 internal usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal musd = IERC20(0xe2f2a5C287993345a840Db3B0845fbC70f5935a5);
    IERC20 internal mta = IERC20(0xa3BeD4E1c75D00fa6f4E5E6922DB7261B5E9AcD2);

    IBPT internal musdcBpt = IBPT(0x72Cd8f4504941Bf8c5a21d1Fd83A96499FD71d2C);

    SwapRouter public swapRouter = SwapRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IMPool internal mPool = IMPool(0x881c72D1e6317f10a1cDCBe05040E7564E790C80);
    IMTAGov internal mtaGov = IMTAGov(0xaE8bC96DA4F9A9613c323478BE181FDb2Aa0E1BF);

    IERC20 public want = usdc; // should be set only in constructor or hardcoded
    IController public controller; // should be set only in constructor

    address public strategist; // mutable, but only by strategist

    // want must be equal to an underlying vault token (Eg. USDC)
    constructor(IController _controller) public {
        controller = _controller;
        strategist = msg.sender;
    }

    modifier onlyStrategist() {
        require(msg.sender == strategist, "!strategist");
        _;
    }

    modifier onlyController() {
        require(msg.sender == address(controller), "!controller");
        _;
    }

    function getName() external pure returns (string memory) {
        return "MstableStrategy";
    }

    function setStrategist(address _strategist) external onlyStrategist {
        strategist = _strategist;
    }

    function setNumPoolsForSwap(uint256 _numPools) external onlyStrategist {
        numPools = _numPools;
    }

    function setAllowances(IERC20 token, address[] calldata recipients, bool isIncrease) external {
        require(msg.sender == strategist, "!strategist");
        for (uint i = 0; i < recipients.length; i++) {
            require(
                recipients[i] == address(musdcBpt) ||
                recipients[i] == address(swapRouter) ||
                recipients[i] == address(mPool) ||
                recipients[i] == address(mtaGov),
                "bad recipient"
            );
            uint256 allowance = isIncrease ? uint256(-1) : 0;
            token.safeApprove(recipients[i], allowance);
        }
    }

    // Assumed that caller checks against available funds in vault
    function deposit(uint256 amount) public {
        uint256 availFunds = controller.allowableAmount(address(this));
        require(amount <= availFunds, "exceed contAllowance");
        controller.earn(address(this), amount);
        
        // deposit into musdcBpt
        uint256 bptTokenAmt = musdcBpt.joinswapExternAmountIn(address(want), amount, 0);

        // deposit into mstable pool
        mPool.stake(bptTokenAmt);

        // deposit any MTA token in this contract into mStaking contract
        depositMTAInStaking();
    }

    function balanceOf() external view returns (uint256) {
        // get balance in mPool
        uint256 bptStakeAmt = mPool.balanceOf(address(this));

        // get usdc + musd amts in BPT, and total BPT
        uint256 usdcAmt = usdc.balanceOf(address(musdcBpt));
        uint256 musdAmt = musd.balanceOf(address(musdcBpt));
        uint256 totalBptAmt = musdcBpt.totalSupply();

        // convert musd to usdc
        usdcAmt = usdcAmt.add(
            musdAmt.mul(1e18).div(musdcBpt.getSpotPrice(address(musd), address(usdc)))
        );

        return bptStakeAmt.mul(usdcAmt).div(totalBptAmt);
    }

    function earned() external view returns (uint256) {
        (uint256 earnedAmt,) = mPool.earned(address(this));
        return earnedAmt.add(mtaGov.earned(address(this)));
    }

    function withdraw(address token) external onlyController {
        IERC20 erc20Token = IERC20(token);
        erc20Token.safeTransfer(address(controller), erc20Token.balanceOf(address(this)));
    }

    function withdraw(uint256 amount) external onlyController {
        // exit fully
        mPool.exit();

        // convert to desired amount
        musdcBpt.exitswapExternAmountOut(address(want), amount, uint256(-1));

        // deposit whatever remaining bpt back into mPool
        mPool.stake(musdcBpt.balanceOf(address(this)));

        // send funds to vault
        want.safeTransfer(address(controller.vault(address(want))), amount);
    }

    function withdrawAll() external onlyController returns (uint256 balance) {
        // exit fully
        mPool.exit();

        // convert reward to want tokens
        // in case swap fails, continue
        (bool success, ) = address(this).call(
            abi.encodeWithSignature(
                "exchangeRewardForWant(bool)",
                true
            )
        );
        // to remove compiler warning
        success;

        // convert bpt to want tokens
        musdcBpt.exitswapPoolAmountIn(
            address(want),
            musdcBpt.balanceOf(address(this)),
            0
        );
        
        // exclude collected strategist fee
        balance = want.balanceOf(address(this)).sub(strategistCollectedFee);
        // send funds to vault
        want.safeTransfer(address(controller.vault(address(want))), balance);
    }

    function harvest(bool claimMPool, bool claimGov) external {
        if (claimMPool) mPool.claimReward();
        if (claimGov) mtaGov.claimReward();

        // convert 80% reward to want tokens
        // in case swap fails, return
        (bool success, ) = address(this).call(
            abi.encodeWithSignature(
                "exchangeRewardForWant(bool)",
                false
            )
        );
        // to remove compiler warning
        if (!success) return;

        uint256 amount = want.balanceOf(address(this)).sub(strategistCollectedFee);
        uint256 vaultRewardPercentage;
        uint256 hurdleAmount;
        uint256 harvestPercentage;
        (vaultRewardPercentage, hurdleAmount, harvestPercentage) = 
            controller.getHarvestInfo(address(this), msg.sender);

        // if new epoch, harvest amount should reset
        if (hurdleLastUpdateTime < controller.currentEpochTime()) {
            // reset collected amount
            harvestAmountThisEpoch = 0;
        }
        // update variables
        hurdleLastUpdateTime = block.timestamp;
        harvestAmountThisEpoch = harvestAmountThisEpoch.add(amount);

        // first, take harvester fee
        uint256 harvestFee = amount.mul(harvestPercentage).div(DENOM);
        want.safeTransfer(msg.sender, harvestFee);

        uint256 fee;
        // then, if hurdle amount has been exceeded, take performance fee
        if (harvestAmountThisEpoch >= hurdleAmount) {
            fee = amount.mul(PERFORMANCE_FEE).div(DENOM);
            strategistCollectedFee = strategistCollectedFee.add(fee);
        }
        
        // do the subtraction of harvester and strategist fees
        amount = amount.sub(harvestFee).sub(fee);

        // calculate how much is to be re-invested
        // fee = vault reward amount, reusing variable
        fee = amount.mul(vaultRewardPercentage).div(DENOM);
        want.safeTransfer(address(controller.rewards(address(want))), fee);
        controller.rewards(address(want)).notifyRewardAmount(fee);
        amount = amount.sub(fee);

        // finally, use remaining want amount for reinvestment
        amount = musdcBpt.joinswapExternAmountIn(address(want), amount, 0);

        // deposit into mstable pool
        mPool.stake(amount);

        // deposit any MTA token in this contract into mStaking contract
        depositMTAInStaking();
    }

    function withdrawStrategistFee() external {
        uint256 strategistFeeToTransfer = strategistCollectedFee;
        strategistCollectedFee = 0;
        want.safeTransfer(strategist, strategistFeeToTransfer);
    }

    function exitMGov() external {
        mtaGov.withdraw();
        // convert to want tokens
        // in case swap fails, continue
        (bool success, ) = address(this).call(
            abi.encodeWithSignature(
                "exchangeRewardForWant(bool)",
                true
            )
        );
        // to remove compiler warning
        success;
        want.safeTransfer(
            address(controller.rewards(address(want))),
            want.balanceOf(address(this)).sub(strategistCollectedFee)
        );
    }

    function exchangeRewardForWant(bool exchangeAll) public {
        uint256 swapAmt = mta.balanceOf(address(this));
        if (swapAmt == 0) return;

        // do the exchange
        address[] memory routeDetails = new address[](3);
        routeDetails[0] = address(mta);
        routeDetails[1] = swapRouter.WETH();
        routeDetails[2] = address(want);

        swapRouter.swapExactTokensForTokens(
            exchangeAll ? swapAmt : swapAmt.mul(8000).div(DENOM),
            0,
            routeDetails,
            address(this),
            block.timestamp + 100
        );
    }

    function depositMTAInStaking() internal {
        uint256 mtaBal = mta.balanceOf(address(this));
        if (mtaBal == 0) return;
        if (mtaGov.balanceOf(address(this)) == 0) {
            // create lock with max time
            mtaGov.createLock(mtaBal, 1632580257);
        } else {
            // increase amount
            mtaGov.increaseLockAmount(mtaBal);
        }
    }
}
