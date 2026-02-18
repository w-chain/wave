// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPAPeriphery} from "./interfaces/IPAPeriphery.sol";

interface IWPlus {
    /**
     * @notice Gets comprehensive subscription information for an account
     * @param account The user's address
     * @return tier Current tier (0 if no subscription)
     * @return expiredAt Expiration timestamp
     * @return multiplier Current multiplier value
     * @return stake Staked WCO amount
     * @return isActive Whether subscription is currently active
     */
    function getSubscriptionInfo(address account) external view returns (
        uint8 tier,
        uint32 expiredAt,
        uint128 multiplier,
        uint256 stake,
        bool isActive
    );
}

contract WPlusPeriphery is IPAPeriphery {
    address public constant WPLUS = 0x8ec5c2Fbe8Eec67e516B75Ec3B92137C32d31B76;

    /// @notice Returns the WAVE multiplier for a given account
    /// @param account The account to get the WAVE multiplier for
    /// @return waveMultiplier The WAVE multiplier for the account in WAD
    function getWAVEMultiplier(address account) external view returns (uint256 waveMultiplier) {
        (, , uint128 multiplier, , bool isActive) = IWPlus(WPLUS).getSubscriptionInfo(account);
        if (!isActive) {
            waveMultiplier = 1e18;
        } else {
            waveMultiplier = multiplier;
        }
    }
}
