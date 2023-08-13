// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {StableCoin} from "./StableCoin.sol";
import {DSCEngine} from "./DSCEngine.sol";

contract DeployDSC is Script {
    function run() external returns (StableCoin, DSCEngine) {
        vm.startBroadcast();
        StableCoin dsc = new StableCoin();
        //DSCEngine engine = new DSCEngine(,,dsc);
        vm.stopBroadcast();
    }
}
