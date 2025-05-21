// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { IACM } from "./interfaces/IACM.sol";

contract WAVE is ERC20Burnable {
    IACM public immutable ACM;

    constructor(address acm) ERC20("WAVE", "WAVE") {
        ACM = IACM(acm);
    }

    function mint(address to, uint256 amount) external {
        require(ACM.isFactory(msg.sender), "WAVE: UNAUTHORIZED");
        _mint(to, amount);
    }
}