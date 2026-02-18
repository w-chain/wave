// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { WaveMaker } from "../src/WaveMakerImpl.sol";

contract Upgrade is Script {
    address public constant PROXY = 0x7f483B732Bd148f360ed8Ce64A233aEefC6d1099;
    address public constant WWCO = 0xEdB8008031141024d50cA2839A607B2f82C1c045;
    uint16 public constant allocation = 10;
    uint256 public constant startBlock = 7171717;

    // function run() external {
    //     vm.startBroadcast();
    //     WaveMaker newImplementation = new WaveMaker();
    //     UnsafeUpgrades.upgradeProxy(
    //         PROXY, 
    //         address(newImplementation), 
    //         abi.encodeWithSelector(WaveMaker.initializeETHPool.selector, WWCO, allocation, startBlock) 
    //     );
    //     vm.stopBroadcast(); 
    // }
    function run() external {
        vm.startBroadcast();
        WaveMaker newImplementation = new WaveMaker();
        UnsafeUpgrades.upgradeProxy(
            PROXY, 
            address(newImplementation), 
            ""
        );
        vm.stopBroadcast(); 
    }
}