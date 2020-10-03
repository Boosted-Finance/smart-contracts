pragma solidity 0.5.17;

import "../IERC20.sol";
import "../ITreasury.sol";
import "./IVault.sol";
import "./IVaultRewards.sol";


interface IController {
    function currentEpochTime() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function rewards(address token) external view returns (IVaultRewards);
    function vault(address token) external view returns (IVault);
    function allowableAmount(address) external view returns (uint256);
    function treasury() external view returns (ITreasury);
    function approvedStrategies(address, address) external view returns (bool);
    function getHarvestInfo(address strategy, address user)
        external view returns (
        uint256 vaultRewardPercentage,
        uint256 hurdleAmount,
        uint256 harvestPercentage
    );
    function withdraw(address, uint256) external;
    function earn(address, uint256) external;
    function increaseHurdleRate(address token) external;
}
