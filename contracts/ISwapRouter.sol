//SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.5.17;

interface SwapRouter {
    function WETH() external pure returns (address);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
