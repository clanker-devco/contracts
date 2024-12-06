// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Clanker} from "../src/Clanker.sol";
import {ClankerToken} from "../src/ClankerToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LPLocker} from "./InterfacesForTesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LockerFactory} from "../src/LockerFactory.sol";
import {LpLocker} from "../src/LpLocker.sol";
import {ExactInputSingleParams, ISwapRouter} from "../src/interface.sol";
import "./Bytes32AddressLib.sol";
import {OldLpLocker} from "./InterfacesForTesting.sol";
import {LpLockerv2} from "../src/LpLockerv2.sol";

// Mock contract that reverts when receiving ETH
contract MockNonReceiver {
    receive() external payable {
        revert("Cannot receive ETH");
    }
}

contract ClankerTest is Test {
    using Bytes32AddressLib for bytes32;

    Clanker public clanker;
    LpLockerv2 public liquidityLocker;

    address proxystudio = 0x053707B201385AE3421D450A1FF272952D2D6971;
    uint256 proxystudio_fid = 270504;
    address not_proxystudio = makeAddr("not_proxystudio");

    address badBot = 0xB8E8d2a9b5D1FF8FEb4EFA686ac1D15Bf960070d;

    address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address clankerToken = 0x1bc0c42215582d5A085795f4baDbaC3ff36d1Bcb;

    string clankerImage =
        "https://assets.coingecko.com/coins/images/51440/standard/CLANKER.png?1731232869";

    string exampleCastHash = "0x2f0359fa";

    uint baseFork;
    uint forkBlock = 23054702;
    string alchemyBase =
        "https://base-mainnet.g.alchemy.com/v2/78Auxb3oCMIgLQ_-CMVzF6r69yKdUA9u";

    address taxCollector = 0x04F6ef12a8B6c2346C8505eE4Cff71C43D2dd825;
    address weth = 0x4200000000000000000000000000000000000006;
    address swapRouter = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address uniswapV3Factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address positionManager = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    uint64 defaultLockingPeriod = 4132317178;

    address currentClankerContract = 0x250c9FB2b411B48273f69879007803790A6AeA47;
    address clankerTeamEOA = 0xE0c959EeDcFD004952441Ea4FB4B8f5af424e74B;

    address blondeLPLocker = 0xf4eFaFac1629274DECca0ba379a7c2a6A05fd3e0;
    uint256 blondeLPTokenId = 1223215;

    //////////////////////////////////////////////////////////////
    // Super helpful just for testing... have to move to backend server (typescript) for actual use...

    function predictToken(
        address deployer,
        uint256 fid,
        string calldata name,
        string calldata symbol,
        string calldata image,
        string calldata castHash,
        uint256 supply,
        bytes32 salt
    ) public view returns (address) {
        bytes32 create2Salt = keccak256(abi.encode(deployer, salt));
        return
            keccak256(
                abi.encodePacked(
                    bytes1(0xFF),
                    address(clanker),
                    create2Salt,
                    keccak256(
                        abi.encodePacked(
                            type(ClankerToken).creationCode,
                            abi.encode(
                                name,
                                symbol,
                                supply,
                                deployer,
                                fid,
                                image,
                                castHash
                            )
                        )
                    )
                )
            ).fromLast20Bytes();
    }

    function generateSalt(
        address deployer,
        uint256 fid,
        string calldata name,
        string calldata symbol,
        string calldata image,
        string calldata castHash,
        uint256 supply
    ) external view returns (bytes32 salt, address token) {
        for (uint256 i; ; i++) {
            salt = bytes32(i);
            token = predictToken(
                deployer,
                fid,
                name,
                symbol,
                image,
                castHash,
                supply,
                salt
            );
            if (
                token < weth && token.code.length == 0 && token < clankerToken
            ) {
                break;
            }
        }
    }

    function initialSwapTokens(address token, uint24 _fee) public payable {
        ExactInputSingleParams memory swapParams = ExactInputSingleParams({
            tokenIn: weth, // The token we are exchanging from (ETH wrapped as WETH)
            tokenOut: address(token), // The token we are exchanging to
            fee: _fee, // The pool fee
            recipient: msg.sender, // The recipient address
            amountIn: msg.value, // The amount of ETH (WETH) to be swapped
            amountOutMinimum: 0, // Minimum amount of DAI to receive
            sqrtPriceLimitX96: 0 // No price limit
        });

        // The call to `exactInputSingle` executes the swap.
        ISwapRouter(swapRouter).exactInputSingle{value: msg.value}(swapParams);
    }

    //////////////////////////////////////////////////////////////

    function setUp() public {
        baseFork = vm.createSelectFork(alchemyBase, forkBlock);

        vm.startPrank(proxystudio);

        LockerFactory lockerFactory = new LockerFactory();
        lockerFactory.setFeeRecipient(clankerTeamEOA);

        clanker = new Clanker(
            weth,
            address(0),
            uniswapV3Factory,
            positionManager,
            swapRouter,
            clankerTeamEOA
        );

        liquidityLocker = new LpLockerv2(
            address(clanker),
            address(positionManager),
            clankerTeamEOA,
            50
        );

        vm.stopPrank();
        vm.startPrank(clankerTeamEOA);
        clanker.updateLiquidityLocker(address(liquidityLocker));
        // Approve the clanker deployer to spend the clanker
        IERC20(clankerToken).approve(address(clanker), type(uint256).max);

        // Set the clanker amount to 5
        clanker.setInitialClankerBuyAmount(5);

        // Market buy some CLANKER
        ExactInputSingleParams memory swapParams = ExactInputSingleParams({
            tokenIn: weth, // The token we are exchanging from (ETH wrapped as WETH)
            tokenOut: clankerToken, // The token we are exchanging to
            fee: 10000, // The pool fee
            recipient: clankerTeamEOA, // The recipient address
            amountIn: 0.1 ether, // The amount of ETH (WETH) to be swapped
            amountOutMinimum: 0, // Minimum amount of DAI to receive
            sqrtPriceLimitX96: 0 // No price limit
        });

        vm.deal(clankerTeamEOA, 1 ether);

        // The call to `exactInputSingle` executes the swap.
        ISwapRouter(swapRouter).exactInputSingle{value: 0.1 ether}(swapParams);

        vm.stopPrank();
    }

    function test_generateSalt() public {
        // Generate a salt as if proxystudio deployed a token
        (, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether
        );

        assertTrue(token != address(0));
        assertTrue(token < weth);
    }

    function test_ownerOnlyFunctions() public {
        // Reverts with Ownable if not owner...
        vm.startPrank(not_proxystudio);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                not_proxystudio
            )
        );
        clanker.updateLiquidityLocker(address(0));

        // It didn't change
        assertEq(address(clanker.liquidityLocker()), address(liquidityLocker));

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                not_proxystudio
            )
        );
        clanker.updateProtocolFees(0);

        // It didn't change
        assertEq(clanker.lpFeesCut(), 50);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                not_proxystudio
            )
        );
        clanker.setDeprecated(true);

        // It didn't change
        assertEq(clanker.deprecated(), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                not_proxystudio
            )
        );
        clanker.setAdmin(not_proxystudio, true);

        // not_proxystudio is still not an admin
        assertEq(clanker.admins(not_proxystudio), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                not_proxystudio
            )
        );
        clanker.setInitialClankerBuyAmount(10);

        // It didn't change
        assertEq(clanker.initialClankerBuyAmount(), 5);

        vm.stopPrank();

        // Now update it as owner
        vm.startPrank(clankerTeamEOA);

        clanker.updateLiquidityLocker(address(0));
        assertEq(address(clanker.liquidityLocker()), address(0));

        clanker.updateProtocolFees(0);
        assertEq(clanker.lpFeesCut(), 0);

        clanker.setDeprecated(true);
        assertEq(clanker.deprecated(), true);

        clanker.setAdmin(not_proxystudio, true);
        assertEq(clanker.admins(not_proxystudio), true);

        clanker.setAdmin(not_proxystudio, false);
        assertEq(clanker.admins(not_proxystudio), false);

        clanker.setInitialClankerBuyAmount(10);
        assertEq(clanker.initialClankerBuyAmount(), 10);

        vm.stopPrank();
    }

    function test_deployToken() public {
        vm.startPrank(clankerTeamEOA);
        vm.warp(block.timestamp + 1);

        vm.deal(clankerTeamEOA, 10 ether);

        // Try to deploy with an invalid fee amount leading to an invalid tick

        // Fee of 10 is invalid (this is 0.1%)
        vm.expectRevert("Invalid tick");
        clanker.deployToken(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            10,
            10,
            bytes32(0),
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        // A token address greater than WETH is invalid
        vm.expectRevert("Invalid salt");
        clanker.deployToken(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            100,
            100,
            bytes32(
                0x0000000000000000000000000000000000000000000000000000000000000002
            ),
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        // Make a valid salt...
        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether
        );

        assertTrue(token < weth);

        // Deploy the token without value
        vm.startPrank(clankerTeamEOA);
        clanker.deployToken(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            100,
            100,
            salt,
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        // All the token's data is correct
        ClankerToken tokenContract = ClankerToken(token);
        assertEq(tokenContract.name(), "proxystudio");
        assertEq(tokenContract.symbol(), "WKND");
        assertEq(tokenContract.totalSupply(), 1 ether);
        assertEq(tokenContract.deployer(), proxystudio);
        assertEq(tokenContract.fid(), proxystudio_fid);
        assertEq(tokenContract.image(), clankerImage);
        assertEq(tokenContract.castHash(), exampleCastHash);
        assertEq(tokenContract.decimals(), 18);

        // Check the tokensDeployedByUsers mapping
        Clanker.DeploymentInfo[] memory deployments = clanker
            .getTokensDeployedByUser(proxystudio);
        assertEq(deployments.length, 1);
        assertEq(deployments[0].token, token);
        assertEq(deployments[0].wethPositionId, 1260053);
        assertEq(deployments[0].clankerPositionId, 1260054);
        assertEq(deployments[0].locker, address(liquidityLocker));

        // Cannot deploy again with the same salt
        vm.expectRevert();
        clanker.deployToken(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            100,
            100,
            salt,
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        vm.deal(proxystudio, 1 ether);

        // Make a new salt
        (bytes32 newSalt, address newToken) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether
        );

        // Add not_proxystudio as an admin so they can deploy
        clanker.setAdmin(not_proxystudio, true);
        assertEq(clanker.admins(not_proxystudio), true);

        vm.stopPrank();

        vm.deal(not_proxystudio, 2 ether);
        vm.startPrank(not_proxystudio);

        // Buy and approve some clanker!

        // Approve the clanker deployer to spend the clanker
        IERC20(clankerToken).approve(address(clanker), type(uint256).max);

        // Market buy some CLANKER
        ExactInputSingleParams memory swapParams = ExactInputSingleParams({
            tokenIn: weth, // The token we are exchanging from (ETH wrapped as WETH)
            tokenOut: clankerToken, // The token we are exchanging to
            fee: 10000, // The pool fee
            recipient: not_proxystudio, // The recipient address
            amountIn: 0.1 ether, // The amount of ETH (WETH) to be swapped
            amountOutMinimum: 0, // Minimum amount of DAI to receive
            sqrtPriceLimitX96: 0 // No price limit
        });

        // The call to `exactInputSingle` executes the swap.
        ISwapRouter(swapRouter).exactInputSingle{value: 0.1 ether}(swapParams);

        // Deploy the token with value
        clanker.deployToken{value: 1 ether}(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            100,
            100,
            newSalt,
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        vm.stopPrank();
        vm.startPrank(clankerTeamEOA);

        // Cannot deploy after deprecating the factory
        clanker.setDeprecated(true);

        (bytes32 newSalt2, address newToken2) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether
        );

        vm.expectRevert(Clanker.Deprecated.selector);
        clanker.deployToken(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            100,
            100,
            newSalt2,
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        // Undeprecate the factory
        clanker.setDeprecated(false);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.deal(clankerTeamEOA, 2 ether);
        // Deploy a new token with value
        clanker.deployToken{value: 0.05 ether}(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            100,
            100,
            newSalt2,
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        vm.stopPrank();
    }

    function test_specificNewSaltBehavior() public {
        // Create a token with a salt for deployer, should be the same token as expected...
        vm.selectFork(baseFork);
        vm.warp(block.timestamp + 1);

        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether
        );

        // Deploy the token
        vm.startPrank(clankerTeamEOA);

        vm.expectEmit(true, true, true, true);
        emit Clanker.TokenCreated(
            token,
            1260053,
            1260054,
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            1 ether,
            address(liquidityLocker),
            exampleCastHash
        );

        clanker.deployToken(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            100,
            100,
            salt,
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        vm.stopPrank();
    }

    function test_whoCanClaimFeesOnCurrentBlondeLocker() public {
        vm.selectFork(baseFork);
        vm.warp(block.timestamp + 1);
        vm.roll(23054702);

        // Only clanker team EOA can claim fees...
        vm.startPrank(not_proxystudio);
        vm.expectRevert(bytes("only owner can call"));
        OldLpLocker(blondeLPLocker).collectFees(
            not_proxystudio,
            blondeLPTokenId
        );

        vm.stopPrank();

        // Can claim if team EOA
        vm.startPrank(clankerTeamEOA);
        OldLpLocker(blondeLPLocker).collectFees(
            not_proxystudio,
            blondeLPTokenId
        );

        vm.stopPrank();
    }

    function test_whoCanClaimFeesOnNewTokenWithNewContract() public {
        vm.selectFork(baseFork);
        vm.warp(block.timestamp + 1);
        vm.roll(23054702);

        // Make proxystudio persistent
        // vm.makePersistent(proxystudio);
        // vm.makePersistent(clankerTeamEOA);

        // Make a new token for proxystudio
        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether
        );

        vm.startPrank(clankerTeamEOA);

        // Check the event is emitted
        vm.expectEmit(true, true, true, true);
        emit Clanker.TokenCreated(
            token,
            1260053,
            1260054,
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            1 ether,
            address(liquidityLocker),
            exampleCastHash
        );

        vm.deal(clankerTeamEOA, 0.1 ether);
        clanker.deployToken{value: 0.1 ether}(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            100,
            100,
            salt,
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        vm.stopPrank();

        // Trade the coin...
        vm.deal(not_proxystudio, 1 ether);
        vm.startPrank(not_proxystudio);
        this.initialSwapTokens{value: 1 ether}(token, 100);
        vm.stopPrank();

        uint proxystudioBalanceBefore = IERC20(weth).balanceOf(proxystudio);
        uint clankerTeamEoABalanceBefore = IERC20(weth).balanceOf(
            clankerTeamEOA
        );

        uint proxystudioBalanceAfter = IERC20(weth).balanceOf(proxystudio);
        uint clankerTeamEoABalanceAfter = IERC20(weth).balanceOf(
            clankerTeamEOA
        );
        assertEq(proxystudioBalanceBefore, proxystudioBalanceAfter);
        assertEq(clankerTeamEoABalanceBefore, clankerTeamEoABalanceAfter);

        // proxystudio can claim fees
        vm.startPrank(proxystudio);
        LpLockerv2(address(liquidityLocker)).collectFees(1260053);

        LpLockerv2(address(liquidityLocker)).collectFees(1260054);

        vm.stopPrank();

        proxystudioBalanceAfter = IERC20(weth).balanceOf(proxystudio);
        clankerTeamEoABalanceAfter = IERC20(weth).balanceOf(clankerTeamEOA);

        // Should split the fees...
        assertGt(proxystudioBalanceAfter, proxystudioBalanceBefore);
        assertGt(clankerTeamEoABalanceAfter, clankerTeamEoABalanceBefore);
    }

    function test_claimFees() public {
        vm.selectFork(baseFork);
        vm.warp(block.timestamp + 1);
        vm.roll(23054702);

        // Make proxystudio persistent
        // vm.makePersistent(proxystudio);
        // vm.makePersistent(clankerTeamEOA);

        // Make a new token for proxystudio
        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether
        );

        vm.startPrank(clankerTeamEOA);
        // Check the event is emitted
        vm.expectEmit(true, true, true, true);
        emit Clanker.TokenCreated(
            token,
            1260053,
            1260054,
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            1 ether,
            address(liquidityLocker),
            exampleCastHash
        );

        vm.deal(clankerTeamEOA, 0.1 ether);
        clanker.deployToken{value: 0.1 ether}(
            "proxystudio",
            "WKND",
            1 ether,
            1,
            100,
            100,
            salt,
            proxystudio,
            proxystudio_fid,
            clankerImage,
            exampleCastHash
        );

        vm.stopPrank();

        // Trade the coin...
        vm.deal(not_proxystudio, 1 ether);
        vm.startPrank(not_proxystudio);
        this.initialSwapTokens{value: 1 ether}(token, 100);
        vm.stopPrank();

        // Clanker team EOA can't claim fees from the locker
        vm.startPrank(clankerTeamEOA);

        uint proxystudioBalanceBefore = IERC20(weth).balanceOf(proxystudio);
        uint clankerTeamEoABalanceBefore = IERC20(weth).balanceOf(
            clankerTeamEOA
        );

        vm.expectRevert(bytes("Token not found"));
        clanker.claimFees(token);
        vm.stopPrank();

        uint proxystudioBalanceAfter = IERC20(weth).balanceOf(proxystudio);
        uint clankerTeamEoABalanceAfter = IERC20(weth).balanceOf(
            clankerTeamEOA
        );
        assertEq(proxystudioBalanceBefore, proxystudioBalanceAfter);
        assertEq(clankerTeamEoABalanceBefore, clankerTeamEoABalanceAfter);

        // proxystudio can claim fees
        vm.startPrank(proxystudio, proxystudio);
        // Get the LP Locker address for the token that was deployed...

        Clanker.DeploymentInfo[] memory deployments = clanker
            .getTokensDeployedByUser(proxystudio);
        assertEq(deployments.length, 1);
        assertEq(deployments[0].token, token);
        assertEq(deployments[0].wethPositionId, 1260053);
        assertEq(deployments[0].clankerPositionId, 1260054);
        assertEq(deployments[0].locker, address(liquidityLocker));
        clanker.claimFees(token);

        vm.stopPrank();

        proxystudioBalanceAfter = IERC20(weth).balanceOf(proxystudio);
        clankerTeamEoABalanceAfter = IERC20(weth).balanceOf(clankerTeamEOA);

        assertGt(proxystudioBalanceAfter, proxystudioBalanceBefore);
        assertGt(clankerTeamEoABalanceAfter, clankerTeamEoABalanceBefore);
    }
}
