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
import "../IVault.sol";
import "../IVaultRewards.sol";
import "../Admin.sol";
import "../../SafeMath.sol";
import "../../zeppelin/SafeERC20.sol";

// To implement a strategy, kindly implement all TODOs
// This contract can either be inherited or modified
contract SkeletalStrategy is Admin, IStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IVault public vault; // should be set only in constructor
    IVaultRewards public vaultRewards; // should be set only in constructor
    IERC20 public want; // should be derived from vault

    constructor(IVault _vault, IVaultRewards _vaultRewards) public {
        vault = _vault;
        vaultRewards = _vaultRewards;
        want = vault.want();
    }

    modifier onlyVault() {
        require(msg.sender == address(vault), "!vault");
        _;
    }

    function getName() external pure returns (string memory) {
        // TODO: change return value
        return "SkeletalStrategy";
    }

    // TODO: Customise this method, as long as it calls vault.transferFundsToStrategy
    // and does something with the funds
    // Example: Calc fund availability, then send it all to this contract
    function deposit() public {
        uint256 availFunds = vault.availableFunds();
        vault.transferFundsToStrategy(availFunds);
        // TODO: funds would be sent here.. convert to desired token (if needed) for investment
    }

    // TODO: Implement this, should return amount invested
    function balanceOf() external view returns (uint256);

    // admin should be a multisig
    // will withdraw to admin
    function emergencyWithdraw(address token) external onlyAdmin {
        IERC20 erc20Token = IERC20(token);
        require(erc20Token != want, "want");
        // TODO: consider excluding more tokens, such as the farmed token
        // and other intermediary tokens used
        erc20Token.safeTransfer(admin, erc20Token.balanceOf(address(this)));
    }

    function withdraw(uint256 amount) external onlyVault {
        // TODO: process the withdrawal

        // send funds to vault
        want.safeTransfer(address(vault), amount);
    }

    function withdrawAll() external onlyVault returns (uint256 balance) {
        // TODO: exit from strategy, withdraw all funds

        // send funds to vault
        want.safeTransfer(address(vault), want.balanceOf(address(this)));
    }

    // left up to implementation
    function harvest() external {
        // TODO: collect farmed tokens and sell for want token
        // send some to vault rewards
    }
}
