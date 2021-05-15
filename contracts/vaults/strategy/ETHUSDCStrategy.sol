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

import "./SkeletalStrategy.sol";

interface ISushiswapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );
}

interface IValueLiquidPool {
    function swapExactAmountIn(
        address,
        uint256,
        address,
        uint256,
        uint256
    ) external returns (uint256, uint256);

    function swapExactAmountOut(
        address,
        uint256,
        address,
        uint256,
        uint256
    ) external returns (uint256, uint256);

    function calcInGivenOut(
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    ) external pure returns (uint256);

    function calcOutGivenIn(
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    ) external pure returns (uint256);

    function getDenormalizedWeight(address) external view returns (uint256);

    function getBalance(address) external view returns (uint256);

    function swapFee() external view returns (uint256);
}

interface ISushiPool {
    function deposit(uint256 _poolId, uint256 _amount) external;

    function withdraw(uint256 _poolId, uint256 _amount) external;

    function emergencyWithdraw(uint256 _poolId) external;
}

contract SushiV2ETHUSDCStrategy is SkeletalStrategy {
    address public strategist;
    IERC20 public weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ISushiswapRouter public sushiRouter =
        ISushiswapRouter(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    IERC20 public lpPairTokenA = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    IERC20 public lpPairTokenB = weth; // For this contract it will be always be WETH
    uint256 private constant MAX_UINT = uint256(-1);
    uint256 private constant FEE_DENOMINATOR = 10000;
    uint256 public gasFeeChargeable = 50; // 0.05%

    mapping(address => mapping(address => address[])) public sushiswapPaths; // [input -> output] => sushiswap_path
    mapping(address => mapping(address => IValueLiquidPool)) public liquidPools; // [input -> output] => value_liquid_pool (valueliquid.io)

    struct PoolInfo {
        IERC20 targetToken;
        ISushiPool targetPool;
        uint256 targetPoolId;
        uint256 balance;
    }

    PoolInfo public poolInfo;

    modifier onlyAdminOrStrategist() {
        require(msg.sender == admin || msg.sender == strategist, "not authorized");
        _;
    }

    constructor(IVault _vault, IVaultRewards _vaultRewards)
        public
        SkeletalStrategy(_vault, _vaultRewards)
    {
        require(want == IERC20(0x397FF1542f962076d0BFE58eA045FfA2d347ACa0), "bad want token");
        strategist = tx.origin;

        poolInfo.targetToken = IERC20(0x6B3595068778DD592e39A122f4f5a5cF09C90fE2); // sushi token
        poolInfo.targetPool = ISushiPool(0xc2EdaD668740f1aA35E4D8f227fB8E17dcA888Cd); // masterchef
        poolInfo.targetPoolId = 1;

        // Approve all
        lpPairTokenA.approve(address(sushiRouter), MAX_UINT);
        lpPairTokenB.approve(address(sushiRouter), MAX_UINT);
        want.approve(address(poolInfo.targetPool), MAX_UINT);
        poolInfo.targetToken.approve(address(sushiRouter), MAX_UINT);
    }

    function getName() external pure returns (string memory) {
        return "SushiV2ETHUSDCStrategy";
    }

    function setGasFeeChargeable(uint256 _gasFeeChargeable) external onlyAdmin {
        gasFeeChargeable = _gasFeeChargeable;
    }

    function approveForSpender(IERC20 _token, address _spender) external onlyAdminOrStrategist {
        _token.approve(_spender, MAX_UINT);
    }

    function setStrategist(address _strategist) external onlyAdminOrStrategist {
        strategist = _strategist;
    }

    function setSushiRouter(ISushiswapRouter _sushiRouter) external onlyAdminOrStrategist {
        sushiRouter = _sushiRouter;
        lpPairTokenA.approve(address(sushiRouter), MAX_UINT);
        lpPairTokenB.approve(address(sushiRouter), MAX_UINT);
        poolInfo.targetToken.approve(address(sushiRouter), MAX_UINT);
    }

    function setSushiswapPath(
        address _input,
        address _output,
        address[] calldata _path
    ) external onlyAdminOrStrategist {
        sushiswapPaths[_input][_output] = _path;
    }

    function setLiquidPool(
        address _input,
        address _output,
        IValueLiquidPool _pool
    ) external onlyAdminOrStrategist {
        liquidPools[_input][_output] = _pool;
        IERC20(_input).approve(address(_pool), MAX_UINT);
    }

    function deposit() public {
        uint256 availFunds = vault.availableFunds();
        _deposit(availFunds);
    }

    function depositCustomAmount(uint256 amount) external onlyAdminOrStrategist {
        vault.transferFundsToStrategy(amount);
        _deposit(amount);
    }

    function withdraw(uint256 amount) external onlyVault {
        _withdraw(amount);
        // send funds to vault
        want.safeTransfer(address(vault), amount);
    }

    function withdrawAll() external onlyVault returns (uint256 balance) {
        _withdraw(poolInfo.balance);
        balance = want.balanceOf(address(this));
        want.safeTransfer(address(vault), balance);
    }

    function balanceOf() public view returns (uint256) {
        return poolInfo.balance;
    }

    function harvest() external {
        poolInfo.targetPool.withdraw(poolInfo.targetPoolId, 0);
        IERC20 targetToken = poolInfo.targetToken;
        uint256 targetTokenBal = targetToken.balanceOf(address(this));
        _swapTokens(address(targetToken), address(weth), targetTokenBal);
        uint256 wethBal = weth.balanceOf(address(this));

        if (wethBal > 0) {
            // calculate ETH gas rebate to caller
            if (gasFeeChargeable > 0) {
                // block scoping
                {
                    uint256 _gasFee = wethBal.mul(gasFeeChargeable).div(FEE_DENOMINATOR);
                    weth.transfer(msg.sender, _gasFee);
                    wethBal = wethBal.sub(_gasFee);
                }
            }

            // send 50% weth bal to vault rewards
            {
                uint256 _vaultRewardAmount = wethBal.div(2);
                weth.transfer(address(vaultRewards), _vaultRewardAmount);
                vaultRewards.notifyRewardAmount(address(weth), _vaultRewardAmount);
                wethBal = wethBal.sub(_vaultRewardAmount);
            }

            // we have TokenB (WETH) already, so use 1/2 bal to buy TokenA (USDC)
            uint256 wethToBuyTokenA = wethBal.div(2);
            _swapTokens(address(weth), address(lpPairTokenA), wethToBuyTokenA);

            // reinvest back to pool and deposit
            _addLiquidity();
            uint256 lpAmount = want.balanceOf(address(this));
            poolInfo.targetPool.deposit(poolInfo.targetPoolId, lpAmount);
            poolInfo.balance = poolInfo.balance.add(lpAmount);
        }
    }

    function _deposit(uint256 amount) internal {
        vault.transferFundsToStrategy(amount);
        poolInfo.targetPool.deposit(poolInfo.targetPoolId, amount);
        poolInfo.balance = poolInfo.balance.add(amount);
    }

    function _withdraw(uint256 amount) internal {
        poolInfo.targetPool.withdraw(poolInfo.targetPoolId, amount);
        if (poolInfo.balance < amount) {
            amount = poolInfo.balance;
        }
        poolInfo.balance = poolInfo.balance - amount;
    }

    function _swapTokens(
        address _input,
        address _output,
        uint256 _amount
    ) internal {
        IValueLiquidPool _pool = IValueLiquidPool(liquidPools[_input][_output]);
        if (_pool != IValueLiquidPool(0)) {
            // use ValueLiquid
            // swapExactAmountIn(tokenIn, tokenAmountIn, tokenOut, minAmountOut, maxPrice)
            _pool.swapExactAmountIn(_input, _amount, _output, 1, MAX_UINT);
        } else {
            // use sushiswap
            address[] memory path = sushiswapPaths[_input][_output];
            if (path.length == 0) {
                // path: _input -> _output
                path = new address[](2);
                path[0] = _input;
                path[1] = _output;
            }
            // swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline)
            sushiRouter.swapExactTokensForTokens(_amount, 1, path, address(this), now.add(1800));
        }
    }

    function _addLiquidity() internal {
        // addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline)
        sushiRouter.addLiquidity(
            address(lpPairTokenA),
            address(lpPairTokenB),
            lpPairTokenA.balanceOf(address(this)),
            lpPairTokenB.balanceOf(address(this)),
            1,
            1,
            address(this),
            now.add(1800)
        );
    }
}
