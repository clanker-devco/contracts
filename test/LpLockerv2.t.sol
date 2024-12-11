// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LpLockerv2} from "../src/LpLockerv2.sol";
import {ExactInputSingleParams, ISwapRouter} from "../src/interface.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LpLocker} from "../src/LpLocker.sol";
import "./Bytes32AddressLib.sol";
import {OldLpLocker} from "./InterfacesForTesting.sol";
import {Clanker} from "../src/Clanker.sol";

contract LpLockerv2Test is Test {
    using Bytes32AddressLib for bytes32;

    LpLockerv2 public lpLockerv2;
    Clanker public clanker;

    address proxystudio = 0x053707B201385AE3421D450A1FF272952D2D6971;
    address baseUSDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint baseFork;
    string alchemyBase =
        "https://base-mainnet.g.alchemy.com/v2/78Auxb3oCMIgLQ_-CMVzF6r69yKdUA9u";

    address taxCollector = 0x04F6ef12a8B6c2346C8505eE4Cff71C43D2dd825;
    address weth = 0x4200000000000000000000000000000000000006;
    address swapRouter = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address uniswapV3Factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address positionManager = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address liquidityLocker;

    address clankerTeamOriginalEOA = 0xC204af95b0307162118f7Bc36a91c9717490AB69;
    uint256 clankerTeamReward = 60;

    function setUp() public {
        baseFork = vm.createSelectFork(alchemyBase, 23314605);

        vm.startPrank(clankerTeamOriginalEOA);

        clanker = new Clanker(
            address(0),
            uniswapV3Factory,
            positionManager,
            swapRouter,
            clankerTeamOriginalEOA
        );

        lpLockerv2 = new LpLockerv2(
            address(clanker),
            positionManager,
            clankerTeamOriginalEOA,
            clankerTeamReward
        );

        vm.stopPrank();
    }

    function test_constructor() public {
        assertEq(lpLockerv2.owner(), clankerTeamOriginalEOA);
        assertEq(lpLockerv2.positionManager(), positionManager);
        assertEq(lpLockerv2._clankerTeamRecipient(), clankerTeamOriginalEOA);
        assertEq(lpLockerv2._clankerTeamReward(), clankerTeamReward);
    }

    function test_ownerOnlyFunctions() public {
        vm.startPrank(proxystudio);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpLockerv2.updateClankerTeamReward(50);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpLockerv2.updateClankerTeamRecipient(proxystudio);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpLockerv2.setOverrideTeamRewardsForToken(1, proxystudio, 50);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpLockerv2.updateClankerFactory(address(0));

        // Still the same
        assertEq(lpLockerv2._factory(), address(clanker));

        vm.expectRevert(
            abi.encodeWithSelector(LpLockerv2.NotAllowed.selector, proxystudio)
        );
        lpLockerv2.replaceUserRewardRecipient(
            LpLockerv2.UserRewardRecipient({
                lpTokenId: 1,
                recipient: proxystudio
            })
        );

        vm.stopPrank();

        // Recipient and fee are not updated
        assertEq(lpLockerv2._clankerTeamReward(), clankerTeamReward);
        assertEq(lpLockerv2._clankerTeamRecipient(), clankerTeamOriginalEOA);

        // Now update them
        vm.startPrank(clankerTeamOriginalEOA);
        lpLockerv2.updateClankerTeamReward(50);
        lpLockerv2.updateClankerTeamRecipient(proxystudio);
        vm.stopPrank();

        // Recipient and fee are updated
        assertEq(lpLockerv2._clankerTeamReward(), 50);
        assertEq(lpLockerv2._clankerTeamRecipient(), proxystudio);

        vm.startPrank(clankerTeamOriginalEOA);
        lpLockerv2.setOverrideTeamRewardsForToken(1, proxystudio, 50);

        lpLockerv2.updateClankerFactory(address(0));

        // Should have updated
        assertEq(lpLockerv2._factory(), address(0));

        lpLockerv2.replaceUserRewardRecipient(
            LpLockerv2.UserRewardRecipient({
                lpTokenId: 1,
                recipient: proxystudio
            })
        );

        vm.stopPrank();

        (address recipient, uint256 reward, uint256 lpTokenId) = lpLockerv2
            ._teamOverrideRewardRecipientForToken(1);

        assertEq(recipient, proxystudio);
        assertEq(reward, 50);
        assertEq(lpTokenId, 1);
    }

    function test_withdrawAndReceive() public {
        // it can receive ETH
        vm.deal(address(lpLockerv2), 1 ether);

        assertEq(address(lpLockerv2).balance, 1 ether);

        uint256 balanceBefore = clankerTeamOriginalEOA.balance;

        // Only owner can withdraw
        vm.startPrank(proxystudio);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpLockerv2.withdrawETH(proxystudio);
        vm.stopPrank();

        assertEq(address(lpLockerv2).balance, 1 ether);
        assertEq(clankerTeamOriginalEOA.balance, balanceBefore);
        vm.startPrank(clankerTeamOriginalEOA);
        lpLockerv2.withdrawETH(clankerTeamOriginalEOA);
        vm.stopPrank();

        assertEq(address(lpLockerv2).balance, 0);
        assertEq(clankerTeamOriginalEOA.balance, balanceBefore + 1 ether);

        // Now send some ERC20 tokens to the contract
        address baseDegen = 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed;

        vm.startPrank(proxystudio);
        IERC20(baseDegen).transfer(address(lpLockerv2), 1);
        vm.stopPrank();

        assertEq(IERC20(baseDegen).balanceOf(address(lpLockerv2)), 1);
        uint256 balanceBeforeUSDC = IERC20(baseDegen).balanceOf(
            clankerTeamOriginalEOA
        );

        // Only owner can withdraw ERC20 tokens
        vm.startPrank(proxystudio);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpLockerv2.withdrawERC20(baseDegen, proxystudio);
        vm.stopPrank();

        assertEq(IERC20(baseDegen).balanceOf(address(lpLockerv2)), 1);

        vm.startPrank(clankerTeamOriginalEOA);
        lpLockerv2.withdrawERC20(baseDegen, clankerTeamOriginalEOA);
        vm.stopPrank();

        assertEq(IERC20(baseDegen).balanceOf(address(lpLockerv2)), 0);
        assertEq(
            IERC20(baseDegen).balanceOf(clankerTeamOriginalEOA),
            balanceBeforeUSDC + 1
        );
    }
}
