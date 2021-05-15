pragma solidity 0.5.17;

import "./IERC20.sol";

interface ITreasury {
    function nativeToken() external view returns (IERC20);
    function defaultToken() external view returns (IERC20);

    function deposit(IERC20 token, uint256 amount) external;

    function withdraw(uint256 amount, address withdrawAddress) external;
}
