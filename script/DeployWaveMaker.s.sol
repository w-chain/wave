// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { ACM } from "../src/ACM.sol";
import { WaveMaker } from "../src/WaveMakerImpl.sol";

contract Deploy is Script {
    address public acm = 0x9B90aB5176A5bf6f5EF510d608B7753bF128cf0D;
    address public waveMaker;

    address public waveToken = 0x42AbfB13B4E3d25407fFa9705146b7Cb812404a0;
    address public waveLp = 0x35264F0E8cD7A32341f47dBFBf2d85b81fd0ef0A;
    address public treasury = 0xC06b8063FfFBb3dEDc2Dc6471853efa8bB245cA7;

    uint256 public wavePerBlock = 254_000_000_000_000_000;
    uint256 public startBlock = 6531717;

    function run() public {
        vm.startBroadcast();
        address admin = msg.sender;
        
        WaveMaker waveMakerImpl = new WaveMaker();
        waveMaker = UnsafeUpgrades.deployTransparentProxy(
            address(waveMakerImpl),
            admin,
            abi.encodeWithSelector(WaveMaker.initialize.selector, acm, waveToken, waveLp, treasury, wavePerBlock, startBlock)
        );
        
        vm.stopBroadcast();

        console.log("WaveMaker deployed to:", waveMaker);
    }
}
