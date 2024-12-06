// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LpMetaLocker} from "../src/LpMetaLocker.sol";
import {ExactInputSingleParams, ISwapRouter} from "../src/interface.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LpLocker} from "../src/LpLocker.sol";
import "./Bytes32AddressLib.sol";
import {OldLpLocker} from "./InterfacesForTesting.sol";

contract LpMetaLockerTest is Test {
    using Bytes32AddressLib for bytes32;

    LpMetaLocker public lpMetaLocker;

    address proxystudio = 0x053707B201385AE3421D450A1FF272952D2D6971;
    address baseWeth = 0x4200000000000000000000000000000000000006;

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
    uint256 clankerTeamFee = 60;

    function setUp() public {
        baseFork = vm.createSelectFork(alchemyBase, 23314605);

        vm.startPrank(clankerTeamOriginalEOA);

        lpMetaLocker = new LpMetaLocker(
            positionManager,
            clankerTeamOriginalEOA,
            clankerTeamFee
        );

        vm.stopPrank();
    }

    function test_constructor() public {
        assertEq(lpMetaLocker.owner(), clankerTeamOriginalEOA);
        assertEq(lpMetaLocker.positionManager(), positionManager);
        assertEq(lpMetaLocker._clankerTeamRecipient(), clankerTeamOriginalEOA);
        assertEq(lpMetaLocker._clankerTeamFee(), clankerTeamFee);
    }

    function test_ownerOnlyFunctions() public {
        vm.startPrank(proxystudio);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpMetaLocker.updateClankerTeamFee(50);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpMetaLocker.updateClankerTeamRecipient(proxystudio);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpMetaLocker.setOverrideTeamFeesForToken(1, proxystudio, 50);

        vm.stopPrank();

        // Recipient and fee are not updated
        assertEq(lpMetaLocker._clankerTeamFee(), clankerTeamFee);
        assertEq(lpMetaLocker._clankerTeamRecipient(), clankerTeamOriginalEOA);

        // Now update them
        vm.startPrank(clankerTeamOriginalEOA);
        lpMetaLocker.updateClankerTeamFee(50);
        lpMetaLocker.updateClankerTeamRecipient(proxystudio);
        vm.stopPrank();

        // Recipient and fee are updated
        assertEq(lpMetaLocker._clankerTeamFee(), 50);
        assertEq(lpMetaLocker._clankerTeamRecipient(), proxystudio);

        vm.startPrank(clankerTeamOriginalEOA);
        lpMetaLocker.setOverrideTeamFeesForToken(1, proxystudio, 50);
        vm.stopPrank();

        (address recipient, uint256 fee, uint256 lpTokenId) = lpMetaLocker
            ._teamOverrideFeeRecipientForToken(1);

        assertEq(recipient, proxystudio);
        assertEq(fee, 50);
        assertEq(lpTokenId, 1);
    }

    function test_withdrawAndReceive() public {
        // it can receive ETH
        vm.deal(address(lpMetaLocker), 1 ether);

        assertEq(address(lpMetaLocker).balance, 1 ether);

        uint256 balanceBefore = clankerTeamOriginalEOA.balance;

        // Only owner can withdraw
        vm.startPrank(proxystudio);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpMetaLocker.withdrawETH(proxystudio);
        vm.stopPrank();

        assertEq(address(lpMetaLocker).balance, 1 ether);
        assertEq(clankerTeamOriginalEOA.balance, balanceBefore);
        vm.startPrank(clankerTeamOriginalEOA);
        lpMetaLocker.withdrawETH(clankerTeamOriginalEOA);
        vm.stopPrank();

        assertEq(address(lpMetaLocker).balance, 0);
        assertEq(clankerTeamOriginalEOA.balance, balanceBefore + 1 ether);

        // Now send some ERC20 tokens to the contract
        address baseDegen = 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed;
        vm.startPrank(proxystudio);
        IERC20(baseDegen).transfer(address(lpMetaLocker), 1);
        vm.stopPrank();

        assertEq(IERC20(baseDegen).balanceOf(address(lpMetaLocker)), 1);
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
        lpMetaLocker.withdrawERC20(baseDegen, proxystudio);
        vm.stopPrank();

        assertEq(IERC20(baseDegen).balanceOf(address(lpMetaLocker)), 1);

        vm.startPrank(clankerTeamOriginalEOA);
        lpMetaLocker.withdrawERC20(baseDegen, clankerTeamOriginalEOA);
        vm.stopPrank();

        assertEq(IERC20(baseDegen).balanceOf(address(lpMetaLocker)), 0);
        assertEq(
            IERC20(baseDegen).balanceOf(clankerTeamOriginalEOA),
            balanceBeforeUSDC + 1
        );
    }

    function test_onERC721Received() public {
        // Can only send tokens that are uniswap positions
        vm.startPrank(0x46EFbAedc92067E6d60E84ED6395099723252496);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpMetaLocker.NotOwner.selector,
                0x46EFbAedc92067E6d60E84ED6395099723252496
            )
        );
        IERC721(0x28d991e49FB82ed004982EbC2Ea4Ad28C9a91f93).safeTransferFrom(
            0x46EFbAedc92067E6d60E84ED6395099723252496,
            address(lpMetaLocker),
            2
        );
        vm.stopPrank();

        // First the clanker team EOA needs to get the LP position from the previous locker...

        address runnerERC20Locker = 0xD0bfd7b524BEB42e2AEE4d858EB2087418a6B756;
        uint256 runnerERC20LockerTokenId = 1119331;

        vm.startPrank(clankerTeamOriginalEOA);
        OldLpLocker(payable(runnerERC20Locker)).release();
        vm.stopPrank();

        // Clanker team EOA should now own the NFT
        assertEq(
            IERC721(positionManager).ownerOf(runnerERC20LockerTokenId),
            clankerTeamOriginalEOA
        );

        // Now the clanker team EOA can send the NFT to the lpMetaLocker
        vm.startPrank(clankerTeamOriginalEOA);
        IERC721(positionManager).safeTransferFrom(
            clankerTeamOriginalEOA,
            address(lpMetaLocker),
            runnerERC20LockerTokenId
        );
        vm.stopPrank();

        // Now the lpMetaLocker should own the NFT
        assertEq(
            IERC721(positionManager).ownerOf(runnerERC20LockerTokenId),
            address(lpMetaLocker)
        );
    }

    function test_setUserFeeRecipients() public {
        address runnerERC20Locker = 0xD0bfd7b524BEB42e2AEE4d858EB2087418a6B756;
        uint256 runnerERC20LockerTokenId = 1119331;

        address lumERC20Locker = 0x7A4FBB9A9951706fd9D6FFE95cae2d910b863F50;
        uint256 lumERC20LockerTokenId = 1119627;

        LpMetaLocker.UserFeeRecipient[]
            memory recipients = new LpMetaLocker.UserFeeRecipient[](1);
        recipients[0] = LpMetaLocker.UserFeeRecipient(
            proxystudio,
            runnerERC20LockerTokenId
        );

        // Only owner can set the recipients
        vm.startPrank(proxystudio);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpMetaLocker.setUserFeeRecipients(recipients);
        vm.stopPrank();

        // Only owner can add recipients
        vm.startPrank(proxystudio);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                proxystudio
            )
        );
        lpMetaLocker.addUserFeeRecipient(recipients[0]);
        vm.stopPrank();

        // Should be now recipients
        (address recipient, uint256 lpTokenId) = lpMetaLocker
            ._userFeeRecipientForToken(runnerERC20LockerTokenId);
        assertEq(recipient, address(0));
        assertEq(lpTokenId, 0);

        // getLpTokenIdsForUser
        uint256[] memory tokenIds = lpMetaLocker.getLpTokenIdsForUser(
            proxystudio
        );
        assertEq(tokenIds.length, 0);

        // Move the runner locker
        vm.startPrank(clankerTeamOriginalEOA);
        OldLpLocker(payable(runnerERC20Locker)).release();
        IERC721(positionManager).safeTransferFrom(
            clankerTeamOriginalEOA,
            address(lpMetaLocker),
            runnerERC20LockerTokenId
        );

        // Move the friday locker
        OldLpLocker(payable(lumERC20Locker)).release();
        IERC721(positionManager).safeTransferFrom(
            clankerTeamOriginalEOA,
            address(lpMetaLocker),
            lumERC20LockerTokenId
        );

        // Now configure the runner locker
        lpMetaLocker.setUserFeeRecipients(recipients);

        // Add friday locker recipient
        lpMetaLocker.addUserFeeRecipient(
            LpMetaLocker.UserFeeRecipient(proxystudio, lumERC20LockerTokenId)
        );

        vm.stopPrank();

        // Should be now recipients
        (recipient, lpTokenId) = lpMetaLocker._userFeeRecipientForToken(
            runnerERC20LockerTokenId
        );
        assertEq(recipient, proxystudio);
        assertEq(lpTokenId, runnerERC20LockerTokenId);

        (recipient, lpTokenId) = lpMetaLocker._userFeeRecipientForToken(
            lumERC20LockerTokenId
        );
        assertEq(recipient, proxystudio);
        assertEq(lpTokenId, lumERC20LockerTokenId);

        // getLpTokenIdsForUser
        tokenIds = lpMetaLocker.getLpTokenIdsForUser(proxystudio);
        assertEq(tokenIds.length, 2);
        assertEq(tokenIds[0], runnerERC20LockerTokenId);
        assertEq(tokenIds[1], lumERC20LockerTokenId);
        // Collect fees from each tokenId (anyone can collect fees)
        uint256 wethBalanceBeforeproxystudio = IERC20(weth).balanceOf(
            proxystudio
        );
        uint256 wethBalanceBeforeClankerTeamEOA = IERC20(weth).balanceOf(
            clankerTeamOriginalEOA
        );

        lpMetaLocker.collectFees(runnerERC20LockerTokenId);

        assertGt(
            IERC20(weth).balanceOf(proxystudio),
            wethBalanceBeforeproxystudio
        );
        assertGt(
            IERC20(weth).balanceOf(clankerTeamOriginalEOA),
            wethBalanceBeforeClankerTeamEOA
        );

        // try to collect fees from a tokenId that is not set
        vm.expectRevert(
            abi.encodeWithSelector(LpMetaLocker.InvalidTokenId.selector, 1)
        );
        lpMetaLocker.collectFees(1);

        // Override the team fees for the friday locker
        vm.startPrank(clankerTeamOriginalEOA);
        lpMetaLocker.setOverrideTeamFeesForToken(
            lumERC20LockerTokenId,
            proxystudio,
            50
        );
        vm.stopPrank();

        (
            address fridayLockerRecipient,
            uint256 fridayLockerFee,
            uint256 fridayLockerTokenId
        ) = lpMetaLocker._teamOverrideFeeRecipientForToken(
                lumERC20LockerTokenId
            );
        assertEq(fridayLockerRecipient, proxystudio);
        assertEq(fridayLockerFee, 50);
        assertEq(fridayLockerTokenId, lumERC20LockerTokenId);

        uint256 proxystudioWethBalanceBefore = IERC20(weth).balanceOf(
            proxystudio
        );
        uint256 clankerTeamWethBalanceBefore = IERC20(weth).balanceOf(
            clankerTeamOriginalEOA
        );

        lpMetaLocker.collectFees(lumERC20LockerTokenId);

        assertGt(
            IERC20(weth).balanceOf(proxystudio),
            proxystudioWethBalanceBefore
        );
        assertEq(
            IERC20(weth).balanceOf(clankerTeamOriginalEOA),
            clankerTeamWethBalanceBefore
        );
    }
}
