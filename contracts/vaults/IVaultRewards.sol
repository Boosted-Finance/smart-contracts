pragma solidity 0.5.17;

import "../IERC20.sol";


interface IVaultRewards {
    function want() external view returns (IERC20);
}
