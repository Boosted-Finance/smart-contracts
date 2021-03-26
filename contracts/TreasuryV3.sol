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
import "./zeppelin/Ownable.sol";
import "./IERC20.sol";
import "./IERC20Burnable.sol";
import "./ITreasury.sol";
import "./IGov.sol";
import "./ISwapRouter.sol";


contract TreasuryV3 is ITreasury {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    SwapRouter public swapRouter;
    address public gov;
    address public orbitStation;
    IERC20 public nativeToken;


    constructor(SwapRouter _swapRouter, IERC20 _orbitToken, address _orbitStation) public {
        swapRouter = _swapRouter;
        orbitStation = _orbitStation;
        nativeToken = _orbitToken;
        gov = msg.sender;
    }

    modifier onlyGov () {
        require(msg.sender == gov, "not authorized");
        _;
    }

    function setGov(address _gov) external {
        require(msg.sender == gov, "not authorized");
        gov = _gov;
    }

    function setSwapRouter(SwapRouter _swapRouter) external onlyGov {
        swapRouter = _swapRouter;
    }

    function setOrbitStation(address _orbitStation) external onlyGov {
        orbitStation = _orbitStation;
    }

    function balanceOf(IERC20 token) public view returns (uint256) {
        return token.balanceOf(address(this)).sub(ecoFundAmts[address(token)]);
    }

    function deposit(IERC20 token, uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawERC20(uint256 amount, address withdrawAddress, address token) external onlyGov {
        IERC20 coin = IERC20(token);
        require(balanceOf(coin) >= amount, "insufficient funds");
        coin.safeTransfer(withdrawAddress, amount);
    }

    function convertToOrbit(address[] calldata routeDetails, uint256 amount) external {
        require(routeDetails[0] != address(nativeToken), "src can't be boost");
        require(routeDetails[routeDetails.length - 1] == address(nativeToken), "dest not defaultToken");
        IERC20 srcToken = IERC20(routeDetails[0]);
        require(balanceOf(srcToken) >= amount, "insufficient funds");
        if (srcToken.allowance(address(this), address(swapRouter)) <= amount) {
            srcToken.safeApprove(address(swapRouter), 0);
            srcToken.safeApprove(address(swapRouter), uint256(-1));
        }
        swapRouter.swapExactTokensForTokens(
            amount,
            0,
            routeDetails,
            address(this),
            block.timestamp + 100
        );
    }


    function fundOrbitStation(uint256 amount) external onlyGov {
        token.safeTransfer(orbitStation , amount);
    }

}
