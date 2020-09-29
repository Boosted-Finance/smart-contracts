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
import "../SafeMath.sol";
import "../zeppelin/ERC20.sol";
import "../zeppelin/ERC20Detailed.sol";
import "../zeppelin/SafeERC20.sol";


contract BoostVault is ERC20, ERC20Detailed {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 public want;
  
    uint256 public maxUtilisation = 9500;
    uint256 public withdrawalFee = 350;
    uint256 public cap;
    uint256 public constant MAX_UTILISATION_ALLOWABLE = 9900; // max 99% utilisation
    uint256 public constant MAX_WITHDRAWAL_FEE = 500; // 5%
    uint256 public constant DENOM = 10000;
  
    address public gov;
    IController public controller;

    constructor(
        address _want,
        address _gov,
        IController _controller,
        uint256 _cap
    ) public ERC20Detailed(
      string(abi.encodePacked("bfVault-", ERC20Detailed(_want).name())),
      string(abi.encodePacked("bf", ERC20Detailed(_want).symbol())),
      ERC20Detailed(_want).decimals()
  ) {
      want = IERC20(_want);
      gov = _gov;
      controller = _controller;
      cap = _cap;
  }
  
    function balance() public view returns (uint256) {
        return want.balanceOf(address(this))
            .add(controller.balanceOf(address(want)));
    }
  
    function setMaxUtilisation(uint256 _maxUtilisation) external {
        require(msg.sender == gov, "not gov");
        require(_maxUtilisation <= MAX_UTILISATION_ALLOWABLE, "min 1%");
        maxUtilisation = _maxUtilisation;
    }
  
    function setGovernance(address _gov) external {
        require(msg.sender == gov, "not gov");
        gov = _gov;
    }
  
    function setController(IController _controller) external {
        require(msg.sender == gov, "not gov");
        controller = _controller;
    }
    
    function setCap(uint256 _cap) external {
        require(msg.sender == gov, "not gov");
        cap = _cap;
    }

    function setWithdrawalFee(uint256 _percent) external {
        require (_percent <= MAX_WITHDRAWAL_FEE, "fee too high");
        withdrawalFee = _percent;
    }

    // Buffer to process small withdrawals
    function availableFunds() public view returns (uint256) {
        return want.balanceOf(address(this)).mul(maxUtilisation).div(DENOM);
    }
  
    // Strategies will request funds from controller
    // Controller should have checked that
    // 1) Strategy is authorized to pull funds
    // 2) Amount requested is below set cap
    function transferFundsToStrategy(address strategy, uint256 amount) external {
        require(msg.sender == address(controller), "not controller");
        uint256 availAmt = availableFunds();
        require(amount <= availAmt, "too much requested");
        want.safeTransfer(strategy, amount);
    }

    function deposit(uint256 amount) external {
        uint256 poolAmt = balance();
        require(poolAmt.add(amount) <= cap, "cap exceeded");
        want.safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = 0;
        if (poolAmt == 0) {
            shares = amount;
        } else {
            shares = (amount.mul(totalSupply())).div(poolAmt);
        }
        _mint(msg.sender, shares);
    }

    function withdraw(uint256 shares) external {
        uint256 requestedAmt = (balance().mul(shares)).div(totalSupply());
        _burn(msg.sender, shares);

        // Check balance
        uint256 currentAvailFunds = want.balanceOf(address(this));
        if (currentAvailFunds < requestedAmt) {
            uint256 withdrawDiffAmt = requestedAmt.sub(currentAvailFunds);
            // pull funds from strategies through controller
            controller.withdraw(address(want), withdrawDiffAmt);
            uint256 newAvailFunds = want.balanceOf(address(this));
            uint256 diff = newAvailFunds.sub(currentAvailFunds);
            if (diff < withdrawDiffAmt) {
                requestedAmt = newAvailFunds;
            }
        }

        // Apply withdrawal fee, transfer and notify rewards pool
        uint256 withdrawFee = requestedAmt.mul(withdrawalFee).div(DENOM);
        want.safeTransfer(address(controller.rewards(address(want))), withdrawFee);

        // TODO: Call vault rewards notifyRewardDistribution

        requestedAmt = requestedAmt.sub(withdrawFee);
        want.safeTransfer(msg.sender, requestedAmt);
    }

    function getPricePerFullShare() public view returns (uint256) {
        return balance().mul(1e18).div(totalSupply());
    }
}
