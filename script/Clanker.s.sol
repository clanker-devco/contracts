// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Clanker} from "../src/Clanker.sol";
import {LockerFactory} from "../src/LockerFactory.sol";
import {LpLockerv2} from "../src/LpLockerv2.sol";

contract ClankerScript is Script {
    Clanker public clanker;

    address weth = 0x4200000000000000000000000000000000000006;
    address swapRouter = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4; // 0x2626664c2603336E57B271c5C0b26F421741e481;
    address uniswapV3Factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24; //0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address positionManager = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2; //0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    uint64 defaultLockingPeriod = 4132317178;

    // Make sure to update these addresses
    address taxCollector = 0x0000000000000000000000000000000000000000;
    address clankerTeamEOA = 0x0000000000000000000000000000000000000000;

    function setUp() public {}

    function run() public {
        (address abcd, uint256 key) = makeAddrAndKey("abcd");

        vm.startBroadcast(key);
        console.log(abcd);

        clanker = new Clanker(
            weth,
            address(0),
            uniswapV3Factory,
            positionManager,
            swapRouter,
            clankerTeamEOA
        );

        LpLockerv2 liquidityLocker = new LpLockerv2(
            address(clanker),
            positionManager,
            clankerTeamEOA,
            60
        );

        clanker.updateLiquidityLocker(address(liquidityLocker));
        clanker.setInitialClankerBuyAmount(5 ether);

        vm.stopBroadcast();
    }
}
