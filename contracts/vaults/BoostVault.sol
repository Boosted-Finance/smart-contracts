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
import "./IStrategy.sol";
import "../SafeMath.sol";
import "../zeppelin/ERC20.sol";
import "../zeppelin/ERC20Detailed.sol";
import "../zeppelin/SafeERC20.sol";
import "./Admin.sol";

contract BoostVault is Admin, ERC20, ERC20Detailed {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 public want;

    mapping(address => uint256) lastActionTimes;
    uint256 public maxUtilisation = 9500;
    uint256 public withdrawalFee = 5; // 0.05%
    uint256 public constant MAX_UTILISATION_ALLOWABLE = 9900; // max 99% utilisation
    uint256 public constant MAX_WITHDRAWAL_FEE = 100; // 1%
    uint256 public constant DENOM = 10000;

    IVaultRewards public vaultRewards;
    IStrategy public vaultStrategy;
    bool private contractsSet;

    modifier depositWithdrawTxCheck(address user) {
        require(lastActionTimes[user] != block.timestamp, "deposit-withdraw same time");
        lastActionTimes[user] = block.timestamp;
        _;
    }

    constructor(address _want, IVaultRewards _vaultRewards)
        public
        ERC20Detailed(
            string(abi.encodePacked("bfVault-", ERC20Detailed(_want).name())),
            string(abi.encodePacked("bf", ERC20Detailed(_want).symbol())),
            ERC20Detailed(_want).decimals()
        )
    {
        want = IERC20(_want);
        vaultRewards = _vaultRewards;
    }

    function setMaxUtilisation(uint256 _maxUtilisation) external onlyAdmin {
        require(_maxUtilisation <= MAX_UTILISATION_ALLOWABLE, "max 99%");
        maxUtilisation = _maxUtilisation;
    }

    function setVaultStrategy(IStrategy _vaultStrategy) external onlyAdmin {
        require(!contractsSet, "strat alr set");
        contractsSet = true;
        vaultStrategy = _vaultStrategy;
    }

    function setWithdrawalFee(uint256 _percent) external onlyAdmin {
        require(_percent <= MAX_WITHDRAWAL_FEE, "fee too high");
        withdrawalFee = _percent;
    }

    function withdrawAllFromStrategy() external onlyAdmin {
        vaultStrategy.withdrawAll();
    }

    function transferFundsToStrategy(uint256 amount) external {
        require(msg.sender == address(vaultStrategy), "not vault strategy");
        uint256 availAmt = availableFunds();
        // total amount used by strategy should be below utilisation
        require(amount <= availAmt, "too much requested");
        want.safeTransfer(address(vaultStrategy), amount);
    }

    function deposit(uint256 amount) external depositWithdrawTxCheck(msg.sender) {
        uint256 poolAmt = balance();
        want.safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = 0;
        if (poolAmt == 0) {
            shares = amount;
        } else {
            shares = (amount.mul(totalSupply())).div(poolAmt);
        }
        _mint(msg.sender, shares);
        vaultRewards.updateStake(msg.sender);
    }

    function withdraw(uint256 shares) external depositWithdrawTxCheck(msg.sender) {
        uint256 requestedAmt = balance().mul(shares).div(totalSupply());
        _burn(msg.sender, shares);
        vaultRewards.updateStake(msg.sender);

        // Check balance
        uint256 currentAvailFunds = want.balanceOf(address(this));
        if (currentAvailFunds < requestedAmt) {
            uint256 withdrawDiffAmt = requestedAmt.sub(currentAvailFunds);
            // Pull fund from strategy
            vaultStrategy.withdraw(withdrawDiffAmt);
            uint256 newAvailFunds = want.balanceOf(address(this));
            uint256 diff = newAvailFunds.sub(currentAvailFunds);
            if (diff < withdrawDiffAmt) {
                requestedAmt = newAvailFunds;
            }
        }

        // Apply withdrawal fee (sent to rewards contract), transfer and notify rewards pool
        uint256 withdrawFee = requestedAmt.mul(withdrawalFee).div(DENOM);
        want.safeTransfer(address(vaultRewards), withdrawFee);
        vaultRewards.notifyRewardAmount(address(want), withdrawFee);

        requestedAmt = requestedAmt.sub(withdrawFee);
        want.safeTransfer(msg.sender, requestedAmt);
    }

    function balance() public view returns (uint256) {
        return want.balanceOf(address(this))
            .add(vaultStrategy.balanceOf());
    }

    // Buffer to process small withdrawals
    function availableFunds() public view returns (uint256) {
        return want.balanceOf(address(this)).mul(maxUtilisation).div(DENOM);
    }

    function getPricePerFullShare() public view returns (uint256) {
        return balance().mul(1e18).div(totalSupply());
    }

    // override _transfer method to account for stakes in vault reward contract
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        super._transfer(sender, recipient, amount);
        vaultRewards.updateStake(sender);
        vaultRewards.updateStake(recipient);
    }
}
