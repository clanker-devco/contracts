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

contract LpMetaLockerTest is Test {
    using Bytes32AddressLib for bytes32;

    LpMetaLocker public lpMetaLocker;

    address proxystudio = 0x053707B201385AE3421D450A1FF272952D2D6971;
    address baseUSDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint baseFork;
    string alchemyBase = "https://base-mainnet.g.alchemy.com/v2/";

    address taxCollector = 0x04F6ef12a8B6c2346C8505eE4Cff71C43D2dd825;
    address weth = 0x4200000000000000000000000000000000000006;
    address swapRouter = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address uniswapV3Factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address positionManager = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address liquidityLocker;

    address clankerTeamOriginalEOA = proxystudio;
    uint256 clankerTeamFee = 60;

    function setUp() public {
        baseFork = vm.createSelectFork(alchemyBase);

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
        vm.startPrank(proxystudio);
        IERC20(baseUSDC).transfer(address(lpMetaLocker), 1);
        vm.stopPrank();

        assertEq(IERC20(baseUSDC).balanceOf(address(lpMetaLocker)), 1);
        uint256 balanceBeforeUSDC = IERC20(baseUSDC).balanceOf(
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
        lpMetaLocker.withdrawERC20(baseUSDC, proxystudio);
        vm.stopPrank();

        assertEq(IERC20(baseUSDC).balanceOf(address(lpMetaLocker)), 1);

        vm.startPrank(clankerTeamOriginalEOA);
        lpMetaLocker.withdrawERC20(baseUSDC, clankerTeamOriginalEOA);
        vm.stopPrank();

        assertEq(IERC20(baseUSDC).balanceOf(address(lpMetaLocker)), 0);
        assertEq(
            IERC20(baseUSDC).balanceOf(clankerTeamOriginalEOA),
            balanceBeforeUSDC + 1
        );
    }

    function test_onERC721Received() public {
        // Can only send tokens that are uniswap positions
        vm.startPrank(proxystudio);
        vm.expectRevert(
            abi.encodeWithSelector(LpMetaLocker.NotOwner.selector, proxystudio)
        );
        IERC721(0x68A6f9527a357Ea55c7D1813aE6546E839a4f1cf).safeTransferFrom(
            proxystudio,
            address(lpMetaLocker),
            1
        );
        vm.stopPrank();

        // First the clanker team EOA needs to get the LP position from the previous locker...

        address runnerERC20Locker = 0xD0bfd7b524BEB42e2AEE4d858EB2087418a6B756;
        uint256 runnerERC20LockerTokenId = 1119331;

        vm.startPrank(clankerTeamOriginalEOA);
        LpLocker(payable(runnerERC20Locker)).release();
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

        address fridayERC20Locker = 0x13890D5A27B471852c71E0910b398463Fb9e8b16;
        uint256 fridayERC20LockerTokenId = 1119396;

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
        LpLocker(payable(runnerERC20Locker)).release();
        IERC721(positionManager).safeTransferFrom(
            clankerTeamOriginalEOA,
            address(lpMetaLocker),
            runnerERC20LockerTokenId
        );

        // Now configure the runner locker
        lpMetaLocker.setUserFeeRecipients(recipients);

        // Add friday locker recipient
        lpMetaLocker.addUserFeeRecipient(
            LpMetaLocker.UserFeeRecipient(proxystudio, fridayERC20LockerTokenId)
        );

        vm.stopPrank();

        // Should be now recipients
        (recipient, lpTokenId) = lpMetaLocker._userFeeRecipientForToken(
            runnerERC20LockerTokenId
        );
        assertEq(recipient, proxystudio);
        assertEq(lpTokenId, runnerERC20LockerTokenId);

        (recipient, lpTokenId) = lpMetaLocker._userFeeRecipientForToken(
            fridayERC20LockerTokenId
        );
        assertEq(recipient, proxystudio);
        assertEq(lpTokenId, fridayERC20LockerTokenId);

        // getLpTokenIdsForUser
        tokenIds = lpMetaLocker.getLpTokenIdsForUser(proxystudio);
        assertEq(tokenIds.length, 2);
        assertEq(tokenIds[0], runnerERC20LockerTokenId);
        assertEq(tokenIds[1], fridayERC20LockerTokenId);
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
    }
}
