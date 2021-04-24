/*
 A strategy must implement the following functions:
 - getName(): Name of strategy
 - want(): Desired token for investment. Should be same as underlying vault token (Eg. USDC)
 - deposit function that will calls controller.earn() 
 - withdraw(address): For miscellaneous tokens, must exclude any tokens used in the yield
    - Should return to Controller
 - withdraw(uint): Controller | Vault role - withdraw should always return to vault
 - withdrawAll(): Controller | Vault role - withdraw should always return to vault
 - balanceOf(): Should return underlying vault token amount
*/

pragma solidity 0.5.17;

import "../IERC20.sol";

interface IStrategy {
    function getName() external pure returns (string memory);

    function want() external view returns (IERC20);

    function emergencyWithdraw(address) external;

    function withdraw(uint256) external;

    function withdrawAll() external returns (uint256);

    function balanceOf() external view returns (uint256);
}
