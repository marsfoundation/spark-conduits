// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

interface IAuth {

    event Rely(address indexed usr);
    
    event Deny(address indexed usr);

    function wards(address usr) external view returns (uint256);

    function rely(address usr) external;

    function deny(address usr) external;

}
