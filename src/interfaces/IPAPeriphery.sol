// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPAPeriphery {
    /// @notice Returns the WAVE multiplier for a given account
    /// @param account The account to get the WAVE multiplier for
    /// @return waveMultiplier The WAVE multiplier for the account in WAD
    function getWAVEMultiplier(address account) external view returns (uint256 waveMultiplier);
}