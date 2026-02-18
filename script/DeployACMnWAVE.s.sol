// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import { ACM } from "../src/ACM.sol";
import { WAVE } from "../src/WAVE.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();
        address admin = msg.sender;
        ACM acm = new ACM(admin);
        WAVE wave = new WAVE(address(acm));
        vm.stopBroadcast();

        console.log("ACM deployed to:", address(acm));
        console.log("WAVE deployed to:", address(wave));
    }
}
