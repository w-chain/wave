// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

contract ACM is AccessControlEnumerable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    function grantAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(ADMIN_ROLE, account);
    }

    function revokeAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(ADMIN_ROLE, account);
    }

    function isAdmin(address account) external view returns (bool) {
        return hasRole(ADMIN_ROLE, account);
    }

    function grantFactoryRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(FACTORY_ROLE, account);
    }

    function revokeFactoryRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(FACTORY_ROLE, account);
    }

    function isFactory(address account) external view returns (bool) {
        return hasRole(FACTORY_ROLE, account);
    }

}