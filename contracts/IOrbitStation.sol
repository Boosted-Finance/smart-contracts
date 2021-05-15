pragma solidity ^0.5.17;


/*

 __     ______     ______     ______     __     ______   ______     ______   ______     ______   __     ______     __   __
/\ \   /\  __ \   /\  == \   /\  == \   /\ \   /\__  _\ /\  ___\   /\__  _\ /\  __ \   /\__  _\ /\ \   /\  __ \   /\ "-.\ \
\ \ \  \ \ \/\ \  \ \  __<   \ \  __<   \ \ \  \/_/\ \/ \ \___  \  \/_/\ \/ \ \  __ \  \/_/\ \/ \ \ \  \ \ \/\ \  \ \ \-.  \
 \ \_\  \ \_____\  \ \_\ \_\  \ \_____\  \ \_\    \ \_\  \/\_____\    \ \_\  \ \_\ \_\    \ \_\  \ \_\  \ \_____\  \ \_\\"\_\
  \/_/   \/_____/   \/_/ /_/   \/_____/   \/_/     \/_/   \/_____/     \/_/   \/_/\/_/     \/_/   \/_/   \/_____/   \/_/ \/_/

*/

interface IOrbitStation {
    function enter(uint256 _amount) external;

    function enterViaPools(address _staker, uint256 _amount) external;

    function leave(uint256[] calldata _vestingIds) external;
}
