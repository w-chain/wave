// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IACM {
    function isFactory(address account) external view returns (bool);
    function isAdmin(address account) external view returns (bool);
}