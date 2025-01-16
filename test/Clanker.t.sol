// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Clanker} from "../src/Clanker.sol";
import {ClankerToken} from "../src/ClankerToken.sol";
import {ClankerPreSale, IClankerFactory} from "../src/ClankerPreSale.sol";
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
    ClankerPreSale public clankerPreSale;

    address proxystudio = 0x053707B201385AE3421D450A1FF272952D2D6971;
    uint256 proxystudio_fid = 270504;
    address not_proxystudio = makeAddr("not_proxystudio");

    address badBot = 0xB8E8d2a9b5D1FF8FEb4EFA686ac1D15Bf960070d;

    address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address clankerToken = 0x1bc0c42215582d5A085795f4baDbaC3ff36d1Bcb;
    address higherToken = 0x0578d8A44db98B23BF096A382e016e29a5Ce0ffe;
    address degenToken = 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed;

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
        uint256 supply,
        address pairedToken
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
            if (token < weth && token.code.length == 0 && token < pairedToken) {
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

    function initialSwapTokensClankerPool(
        address token,
        uint24 _fee
    ) public payable {
        // Buy clanker
        ExactInputSingleParams memory swapParams = ExactInputSingleParams({
            tokenIn: weth, // The token we are exchanging from (ETH wrapped as WETH)
            tokenOut: clankerToken, // The token we are exchanging to
            fee: 10000, // The pool fee
            recipient: msg.sender, // The recipient address
            amountIn: msg.value, // The amount of ETH (WETH) to be swapped
            amountOutMinimum: 0, // Minimum amount of DAI to receive
            sqrtPriceLimitX96: 0 // No price limit
        });

        // The call to `exactInputSingle` executes the swap.
        uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle{
            value: msg.value
        }(swapParams);

        assertEq(amountOut, 52928283830399435859);

        assertEq(msg.sender, 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496);

        // Approve the clanker to swapRouter
        IERC20(clankerToken).approve(address(swapRouter), type(uint256).max);

        swapParams = ExactInputSingleParams({
            tokenIn: clankerToken, // The token we are exchanging from (ETH wrapped as WETH)
            tokenOut: address(token), // The token we are exchanging to
            fee: _fee, // The pool fee
            recipient: msg.sender, // The recipient address
            amountIn: amountOut, // The amount of ETH (WETH) to be swapped
            amountOutMinimum: 0, // Minimum amount of DAI to receive
            sqrtPriceLimitX96: 0 // No price limit
        });

        // The call to `exactInputSingle` executes the swap.
        ISwapRouter(swapRouter).exactInputSingle(swapParams);
    }

    //////////////////////////////////////////////////////////////

    function setUp() public {
        baseFork = vm.createSelectFork(alchemyBase, forkBlock);

        vm.startPrank(proxystudio);

        LockerFactory lockerFactory = new LockerFactory();
        lockerFactory.setFeeRecipient(clankerTeamEOA);

        clanker = new Clanker(
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

        clankerPreSale = new ClankerPreSale(address(clanker), clankerTeamEOA);

        vm.stopPrank();
        vm.startPrank(clankerTeamEOA);
        clanker.updateLiquidityLocker(address(liquidityLocker));

        // Set the presale factory as admin on clanker
        clanker.setAdmin(address(clankerPreSale), true);

        // Approve the clanker deployer to spend the clanker
        IERC20(clankerToken).approve(address(clanker), type(uint256).max);

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
        (bytes32 salt, address token) = this.generateSalt(
            0x8865910d6ca985782Dc9CC521d23a10100fC800B,
            211845,
            "test",
            "tt",
            " ",
            "0xcf27a12ab3d2859ad56e3432c958019ea9cc8abb",
            1000000000 ether,
            weth
        );

        assertTrue(token != address(0));
        assertTrue(token < weth);

        // assertEq(salt, bytes32(0));
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
        clanker.setAdmin(not_proxystudio, true);

        // not_proxystudio is still not an admin
        assertEq(clanker.admins(not_proxystudio), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                not_proxystudio
            )
        );
        clankerPreSale.setAdmin(not_proxystudio, true);

        // not_proxystudio is still not an admin
        assertEq(clankerPreSale.admins(not_proxystudio), false);

        // Can't withdraw
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                not_proxystudio
            )
        );
        clankerPreSale.withdraw(not_proxystudio, 1 ether);

        // Can't change the clankerFactory
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                not_proxystudio
            )
        );
        clankerPreSale.setClankerFactory(address(0));

        // It didn't change
        assertEq(clankerPreSale.clankerFactory(), address(clanker));

        vm.stopPrank();

        // Now update it as owner
        vm.startPrank(clankerTeamEOA);

        clanker.updateLiquidityLocker(address(0));
        assertEq(address(clanker.liquidityLocker()), address(0));

        clanker.setAdmin(not_proxystudio, true);
        assertEq(clanker.admins(not_proxystudio), true);

        clanker.setAdmin(not_proxystudio, false);
        assertEq(clanker.admins(not_proxystudio), false);

        clankerPreSale.setAdmin(not_proxystudio, true);
        assertEq(clankerPreSale.admins(not_proxystudio), true);

        clankerPreSale.setAdmin(not_proxystudio, false);
        assertEq(clankerPreSale.admins(not_proxystudio), false);

        clankerPreSale.setClankerFactory(address(0));
        assertEq(clankerPreSale.clankerFactory(), address(0));

        // Send some eth to the clankerPreSale
        vm.deal(address(clankerPreSale), 1 ether);

        uint256 balanceBefore = payable(clankerTeamEOA).balance;
        clankerPreSale.withdraw(clankerTeamEOA, 1 ether);
        uint256 balanceAfter = payable(clankerTeamEOA).balance;

        assertEq(balanceAfter - balanceBefore, 1 ether);

        vm.stopPrank();
    }

    function test_deployToken() public {
        vm.startPrank(clankerTeamEOA);
        vm.warp(block.timestamp + 1);

        vm.deal(clankerTeamEOA, 10 ether);

        Clanker.PoolConfig memory poolConfig = Clanker.PoolConfig({
            tick: 1,
            pairedToken: weth,
            devBuyFee: 10000
        });

        // Try to deploy with an invalid fee amount leading to an invalid tick

        // Fee of 10 is invalid (this is 0.1%)
        vm.expectRevert("Invalid tick");
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 10,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // A token address greater than WETH is invalid
        vm.expectRevert(Clanker.Invalid.selector);
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(
                    0x0000000000000000000000000000000000000000000000000000000000000001
                ),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Make a valid salt...
        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether,
            weth
        );
        assertTrue(token < weth);

        // Deploy the token without value
        vm.startPrank(clankerTeamEOA);
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: salt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
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
        assertEq(deployments[0].positionId, 1260053);
        assertEq(deployments[0].locker, address(liquidityLocker));

        // Cannot deploy again with the same salt
        vm.expectRevert();
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: salt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
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
            1 ether,
            weth
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
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: newSalt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        vm.stopPrank();
        vm.startPrank(clankerTeamEOA);

        (bytes32 newSalt2, address newToken2) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether,
            weth
        );

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.deal(clankerTeamEOA, 2 ether);
        // Deploy a new token with value
        clanker.deployToken{value: 0.05 ether}(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: newSalt2,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        vm.stopPrank();
    }

    function test_deployTokenClankerPoolOnly() public {
        vm.startPrank(clankerTeamEOA);
        vm.warp(block.timestamp + 1);

        vm.deal(clankerTeamEOA, 10 ether);

        Clanker.PoolConfig memory poolConfig = Clanker.PoolConfig({
            tick: -230400,
            pairedToken: clankerToken,
            devBuyFee: 10000
        });

        // Try to deploy with an invalid fee amount leading to an invalid tick

        // Fee of 10 is invalid (this is 0.1%)
        vm.expectRevert("Invalid tick");
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 10,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // A token address greater than WETH is invalid
        vm.expectRevert(Clanker.Invalid.selector);
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(
                    0x0000000000000000000000000000000000000000000000000000000000000001
                ),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Make a valid salt...
        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether,
            clankerToken
        );

        // Deploy the token without value
        vm.startPrank(clankerTeamEOA);
        clanker.deployToken{value: 0.1 ether}(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 10000,
                _salt: salt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
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
        assertEq(deployments[0].positionId, 1260053);
        assertEq(deployments[0].locker, address(liquidityLocker));

        // The deployer (proxystudio) can update the image
        vm.startPrank(proxystudio);
        tokenContract.updateImage("new image");
        vm.stopPrank();

        assertEq(tokenContract.image(), "new image");

        // No one else can update the image
        vm.startPrank(not_proxystudio);
        vm.expectRevert(ClankerToken.NotDeployer.selector);
        tokenContract.updateImage("new image 2");
        vm.stopPrank();

        // Image still the same
        assertEq(tokenContract.image(), "new image");

        // Buy the token from the clanker pool
        // vm.startPrank(not_proxystudio);
        // vm.deal(not_proxystudio, 2 ether);
        // this.initialSwapTokensClankerPool{value: 1 ether}(token, 100);
        // vm.stopPrank();

        // // Collect rewards
        // vm.startPrank(proxystudio);
        // clanker.claimRewards(token);
        // vm.stopPrank();

        vm.stopPrank();
    }

    function test_deployTokenHigherPoolOnly() public {
        vm.startPrank(clankerTeamEOA);
        vm.warp(block.timestamp + 1);

        vm.deal(clankerTeamEOA, 10 ether);

        Clanker.PoolConfig memory poolConfig = Clanker.PoolConfig({
            tick: -230400,
            pairedToken: higherToken,
            devBuyFee: 10000
        });

        // Try to deploy with an invalid fee amount leading to an invalid tick

        // Fee of 10 is invalid (this is 0.1%)
        vm.expectRevert("Invalid tick");
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 10,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // A token address greater than WETH is invalid
        vm.expectRevert(Clanker.Invalid.selector);
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(
                    0x0000000000000000000000000000000000000000000000000000000000000001
                ),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Make a valid salt...
        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether,
            higherToken
        );

        // Deploy the token without value
        vm.startPrank(clankerTeamEOA);
        clanker.deployToken{value: 0.1 ether}(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 10000,
                _salt: salt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
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
        assertEq(deployments[0].positionId, 1260053);
        assertEq(deployments[0].locker, address(liquidityLocker));

        // The deployer (proxystudio) can update the image
        vm.startPrank(proxystudio);
        tokenContract.updateImage("new image");
        vm.stopPrank();

        assertEq(tokenContract.image(), "new image");

        // No one else can update the image
        vm.startPrank(not_proxystudio);
        vm.expectRevert(ClankerToken.NotDeployer.selector);
        tokenContract.updateImage("new image 2");
        vm.stopPrank();

        // Image still the same
        assertEq(tokenContract.image(), "new image");

        // Buy the token from the clanker pool
        // vm.startPrank(not_proxystudio);
        // vm.deal(not_proxystudio, 2 ether);
        // this.initialSwapTokensClankerPool{value: 1 ether}(token, 100);
        // vm.stopPrank();

        // // Collect rewards
        // vm.startPrank(proxystudio);
        // clanker.claimRewards(token);
        // vm.stopPrank();

        vm.stopPrank();
    }

    function test_deployTokenDegenPoolOnly() public {
        vm.startPrank(clankerTeamEOA);
        vm.warp(block.timestamp + 1);

        vm.deal(clankerTeamEOA, 10 ether);

        Clanker.PoolConfig memory poolConfig = Clanker.PoolConfig({
            tick: -230400,
            pairedToken: degenToken,
            devBuyFee: 3000
        });

        // Try to deploy with an invalid fee amount leading to an invalid tick

        // Fee of 10 is invalid (this is 0.1%)
        vm.expectRevert("Invalid tick");
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 10,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // A token address greater than WETH is invalid
        vm.expectRevert(Clanker.Invalid.selector);
        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(
                    0x0000000000000000000000000000000000000000000000000000000000000001
                ),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Make a valid salt...
        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether,
            degenToken
        );

        // Deploy the token without value
        vm.startPrank(clankerTeamEOA);
        clanker.deployToken{value: 0.1 ether}(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 10000,
                _salt: salt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
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
        assertEq(deployments[0].positionId, 1260053);
        assertEq(deployments[0].locker, address(liquidityLocker));

        // The deployer (proxystudio) can update the image
        vm.startPrank(proxystudio);
        tokenContract.updateImage("new image");
        vm.stopPrank();

        assertEq(tokenContract.image(), "new image");

        // No one else can update the image
        vm.startPrank(not_proxystudio);
        vm.expectRevert(ClankerToken.NotDeployer.selector);
        tokenContract.updateImage("new image 2");
        vm.stopPrank();

        // Image still the same
        assertEq(tokenContract.image(), "new image");

        // Buy the token from the clanker pool
        // vm.startPrank(not_proxystudio);
        // vm.deal(not_proxystudio, 2 ether);
        // this.initialSwapTokensClankerPool{value: 1 ether}(token, 100);
        // vm.stopPrank();

        // // Collect rewards
        // vm.startPrank(proxystudio);
        // clanker.claimRewards(token);
        // vm.stopPrank();

        vm.stopPrank();
    }

    function test_specificNewSaltBehavior() public {
        // Create a token with a salt for deployer, should be the same token as expected...
        vm.selectFork(baseFork);
        vm.warp(block.timestamp + 1);

        Clanker.PoolConfig memory poolConfig = Clanker.PoolConfig({
            tick: 1,
            pairedToken: weth,
            devBuyFee: 10000
        });

        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether,
            weth
        );

        // Deploy the token
        vm.startPrank(clankerTeamEOA);

        vm.expectEmit(true, true, true, true);
        emit Clanker.TokenCreated(
            token,
            1260053,
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            1 ether,
            exampleCastHash
        );

        clanker.deployToken(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: salt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        vm.stopPrank();
    }

    function test_whoCanClaimRewardsOnCurrentBlondeLocker() public {
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

    function test_whoCanClaimRewardsOnNewTokenWithNewContract() public {
        vm.selectFork(baseFork);
        vm.warp(block.timestamp + 1);
        vm.roll(23054702);

        Clanker.PoolConfig memory poolConfig = Clanker.PoolConfig({
            tick: 1,
            pairedToken: weth,
            devBuyFee: 10000
        });

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
            1 ether,
            weth
        );

        vm.startPrank(clankerTeamEOA);

        // Check the event is emitted
        vm.expectEmit(true, true, true, true);
        emit Clanker.TokenCreated(
            token,
            1260053,
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            1 ether,
            exampleCastHash
        );

        vm.deal(clankerTeamEOA, 0.1 ether);
        clanker.deployToken{value: 0.1 ether}(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: salt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        vm.stopPrank();

        // Get the LP Token IDs for the user
        uint256[] memory lpTokenIds = LpLockerv2(address(liquidityLocker))
            .getLpTokenIdsForUser(proxystudio);
        assertEq(lpTokenIds.length, 1);

        assertEq(lpTokenIds[0], 1260053);

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
        LpLockerv2(address(liquidityLocker)).collectRewards(1260053);

        // Can't collect fees for a token that doesn't exist
        vm.expectRevert(
            abi.encodeWithSelector(LpLockerv2.InvalidTokenId.selector, 1)
        );
        LpLockerv2(address(liquidityLocker)).collectRewards(1);

        vm.stopPrank();

        proxystudioBalanceAfter = IERC20(weth).balanceOf(proxystudio);
        clankerTeamEoABalanceAfter = IERC20(weth).balanceOf(clankerTeamEOA);

        // Should split the fees...
        assertGt(proxystudioBalanceAfter, proxystudioBalanceBefore);
        assertGt(clankerTeamEoABalanceAfter, clankerTeamEoABalanceBefore);

        // Test with an override fee recipient
        vm.startPrank(clankerTeamEOA);
        LpLockerv2(address(liquidityLocker)).setOverrideTeamRewardsForToken(
            1260053,
            not_proxystudio,
            50
        );
        vm.stopPrank();

        vm.deal(not_proxystudio, 1 ether);
        vm.startPrank(not_proxystudio);
        this.initialSwapTokens{value: 1 ether}(token, 100);
        vm.stopPrank();

        // Get the balance before
        proxystudioBalanceBefore = IERC20(weth).balanceOf(proxystudio);
        uint256 notProxystudioBalanceBefore = IERC20(weth).balanceOf(
            not_proxystudio
        );

        // Collect fees
        vm.startPrank(proxystudio);
        LpLockerv2(address(liquidityLocker)).collectRewards(1260053);
        vm.stopPrank();

        // Check the balances
        assertGt(IERC20(weth).balanceOf(proxystudio), proxystudioBalanceBefore);
        assertGt(
            IERC20(weth).balanceOf(not_proxystudio),
            notProxystudioBalanceBefore
        );
    }

    function test_claimRewards() public {
        vm.selectFork(baseFork);
        vm.warp(block.timestamp + 1);
        vm.roll(23054702);

        Clanker.PoolConfig memory poolConfig = Clanker.PoolConfig({
            tick: 1,
            pairedToken: weth,
            devBuyFee: 10000
        });

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
            1 ether,
            weth
        );

        vm.startPrank(clankerTeamEOA);
        // Check the event is emitted
        vm.expectEmit(true, true, true, true);
        emit Clanker.TokenCreated(
            token,
            1260053,
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            1 ether,
            exampleCastHash
        );

        vm.deal(clankerTeamEOA, 0.1 ether);
        clanker.deployToken{value: 0.1 ether}(
            Clanker.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: salt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
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
        uint notProxystudioBalanceBefore = IERC20(weth).balanceOf(
            not_proxystudio
        );

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
        assertEq(deployments[0].positionId, 1260053);
        assertEq(deployments[0].locker, address(liquidityLocker));
        clanker.claimRewards(token);

        // Try to claim rewards for a token that doesn't exist
        vm.expectRevert(Clanker.NotFound.selector);
        clanker.claimRewards(address(0));

        vm.stopPrank();

        proxystudioBalanceAfter = IERC20(weth).balanceOf(proxystudio);
        clankerTeamEoABalanceAfter = IERC20(weth).balanceOf(clankerTeamEOA);

        assertGt(proxystudioBalanceAfter, proxystudioBalanceBefore);
        assertGt(clankerTeamEoABalanceAfter, clankerTeamEoABalanceBefore);

        // Update the reward recipient
        vm.startPrank(clankerTeamEOA);
        LpLockerv2(address(liquidityLocker)).replaceUserRewardRecipient(
            LpLockerv2.UserRewardRecipient({
                lpTokenId: 1260053,
                recipient: not_proxystudio
            })
        );
        vm.stopPrank();

        // Check the reward recipient is updated
        (address recipient, uint256 lpTokenId) = LpLockerv2(
            address(liquidityLocker)
        )._userRewardRecipientForToken(1260053);
        assertEq(recipient, not_proxystudio);

        // Trade some more
        vm.deal(not_proxystudio, 1 ether);
        vm.startPrank(not_proxystudio);
        this.initialSwapTokens{value: 1 ether}(token, 100);
        vm.stopPrank();

        // Claim rewards
        vm.startPrank(proxystudio);
        clanker.claimRewards(token);
        vm.stopPrank();

        // Check the balances
        assertEq(IERC20(weth).balanceOf(proxystudio), proxystudioBalanceAfter);
        assertGt(
            IERC20(weth).balanceOf(not_proxystudio),
            notProxystudioBalanceBefore
        );
    }

    function test_createPreSaleToken() public {
        vm.startPrank(clankerTeamEOA);

        IClankerFactory.PoolConfig memory poolConfig = IClankerFactory
            .PoolConfig({tick: 1, pairedToken: weth, devBuyFee: 10000});

        // Cannot create with pre sale id 0
        vm.expectRevert(
            abi.encodeWithSelector(ClankerPreSale.InvalidConfig.selector)
        );
        clankerPreSale.createPreSaleToken(
            IClankerFactory.PreSaleConfig({
                bpsAvailable: 9999,
                bpsSold: 0,
                endTime: block.timestamp + 1000000000,
                ethPerBps: 0.000000001 ether,
                tokenAddress: address(0)
            }),
            0,
            IClankerFactory.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Make a new presale token
        clankerPreSale.createPreSaleToken(
            IClankerFactory.PreSaleConfig({
                bpsAvailable: 9999,
                bpsSold: 0,
                endTime: block.timestamp + 1000000000,
                ethPerBps: 0.000000001 ether,
                tokenAddress: address(0)
            }),
            1,
            IClankerFactory.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Cannot create with a pre sale id that already exists
        vm.expectRevert(ClankerPreSale.InvalidConfig.selector);
        clankerPreSale.createPreSaleToken(
            IClankerFactory.PreSaleConfig({
                bpsAvailable: 9999,
                bpsSold: 0,
                endTime: block.timestamp + 1000000000,
                ethPerBps: 0.0000000069 ether,
                tokenAddress: address(0)
            }),
            1,
            IClankerFactory.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Cannot create with 100% available bps
        vm.expectRevert(
            abi.encodeWithSelector(ClankerPreSale.InvalidConfig.selector)
        );
        clankerPreSale.createPreSaleToken(
            IClankerFactory.PreSaleConfig({
                bpsAvailable: 10000,
                bpsSold: 0,
                endTime: block.timestamp + 1000000000,
                ethPerBps: 0.000000001 ether,
                tokenAddress: address(0)
            }),
            2,
            IClankerFactory.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );
    }

    function test_refundPreSale() public {
        vm.startPrank(clankerTeamEOA);

        IClankerFactory.PoolConfig memory poolConfig = IClankerFactory
            .PoolConfig({tick: 1, pairedToken: weth, devBuyFee: 10000});

        // Cannot refund a pre sale that doesn't exist
        vm.expectRevert(
            abi.encodeWithSelector(ClankerPreSale.PreSaleNotFound.selector, 0)
        );
        clankerPreSale.refundPreSale(0);

        // Make a new presale token
        clankerPreSale.createPreSaleToken(
            IClankerFactory.PreSaleConfig({
                bpsAvailable: 9999,
                bpsSold: 10000, // already sold out...
                endTime: block.timestamp + 1000000000,
                ethPerBps: 0.000000001 ether,
                tokenAddress: address(0)
            }),
            1,
            IClankerFactory.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Try to refund if sold out
        vm.expectRevert(
            abi.encodeWithSelector(ClankerPreSale.PreSaleEnded.selector, 1)
        );
        clankerPreSale.refundPreSale(1);

        // Cannot refund if not sold out but time hasn't ended yet
        clankerPreSale.createPreSaleToken(
            IClankerFactory.PreSaleConfig({
                bpsAvailable: 9999,
                bpsSold: 0,
                endTime: block.timestamp + 1000000000,
                ethPerBps: 0.000000001 ether,
                tokenAddress: address(0)
            }),
            2,
            IClankerFactory.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Warp forward 1 seconds
        vm.warp(block.timestamp + 1);
        // Refund
        vm.expectRevert(
            abi.encodeWithSelector(ClankerPreSale.PreSaleNotEnded.selector, 2)
        );
        clankerPreSale.refundPreSale(2);

        // Buy into the pre sale
        vm.deal(not_proxystudio, 1 ether);
        uint256 not_proxystudio_balance_before = payable(not_proxystudio)
            .balance;

        vm.startPrank(not_proxystudio);
        clankerPreSale.buyIntoPreSale{value: 0.000000001 ether}(2);
        vm.stopPrank();

        // Warp to after the pre sale has ended
        vm.warp(block.timestamp + 1000000000 + 1);

        // Refund
        clankerPreSale.refundPreSale(2);

        // Can't refund again
        vm.expectRevert(
            abi.encodeWithSelector(ClankerPreSale.AlreadyRefunded.selector, 2)
        );
        clankerPreSale.refundPreSale(2);

        // Check the balance
        assertEq(
            payable(not_proxystudio).balance,
            not_proxystudio_balance_before
        );
    }

    function test_buyIntoPreSale() public {
        vm.startPrank(clankerTeamEOA);

        IClankerFactory.PoolConfig memory poolConfig = IClankerFactory
            .PoolConfig({tick: 1, pairedToken: weth, devBuyFee: 10000});

        // Cannot buy into a pre sale that doesn't exist
        vm.expectRevert(
            abi.encodeWithSelector(ClankerPreSale.PreSaleNotFound.selector, 0)
        );
        clankerPreSale.buyIntoPreSale(0);

        // Make a new presale token
        clankerPreSale.createPreSaleToken(
            IClankerFactory.PreSaleConfig({
                bpsAvailable: 9999,
                bpsSold: 0,
                endTime: block.timestamp + 1000000000,
                ethPerBps: 0.000000001 ether,
                tokenAddress: address(0)
            }),
            1,
            IClankerFactory.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Warp forward and try to buy after the pre sale has ended
        vm.warp(block.timestamp + 1000000000 + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ClankerPreSale.PreSaleEnded.selector, 1)
        );
        clankerPreSale.buyIntoPreSale(1);

        // Can't buy if bpsSold is greater than bpsAvailable
        clankerPreSale.createPreSaleToken(
            IClankerFactory.PreSaleConfig({
                bpsAvailable: 9999,
                bpsSold: 10000,
                endTime: block.timestamp + 1000000000,
                ethPerBps: 0.000000001 ether,
                tokenAddress: address(0)
            }),
            2,
            IClankerFactory.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: bytes32(0),
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // Buy into the pre sale
        vm.expectRevert(
            abi.encodeWithSelector(ClankerPreSale.PreSaleEnded.selector, 2)
        );
        clankerPreSale.buyIntoPreSale(2);

        (bytes32 salt, address token) = this.generateSalt(
            proxystudio,
            proxystudio_fid,
            "proxystudio",
            "WKND",
            clankerImage,
            exampleCastHash,
            1 ether,
            weth
        );

        // Make a new presale token
        clankerPreSale.createPreSaleToken(
            IClankerFactory.PreSaleConfig({
                bpsAvailable: 1000,
                bpsSold: 0,
                endTime: block.timestamp + 2000000000, // must start later than we are
                ethPerBps: 0.000000001 ether,
                tokenAddress: address(0)
            }),
            3,
            IClankerFactory.PreSaleTokenConfig({
                _name: "proxystudio",
                _symbol: "WKND",
                _supply: 1 ether,
                _fee: 100,
                _salt: salt,
                _deployer: proxystudio,
                _fid: proxystudio_fid,
                _image: clankerImage,
                _castHash: exampleCastHash,
                _poolConfig: poolConfig
            })
        );

        // proxystudio balance before
        uint256 proxystudio_balance_before = payable(proxystudio).balance;
        // Buy into the presale more than is available
        vm.deal(not_proxystudio, 1 ether);
        vm.startPrank(not_proxystudio);
        clankerPreSale.buyIntoPreSale{value: 0.000000001 ether * 1001}(3);
        vm.stopPrank();

        // Check the balance (should still be equal because they get no money from the presale)
        assertEq(payable(proxystudio).balance, proxystudio_balance_before);

        // The clanker contract should not have any money in it
        assertEq(address(clanker).balance, 0);

        // It should also own no weth
        assertEq(IERC20(weth).balanceOf(address(clanker)), 0);

        // Get the presale purchases
        IClankerFactory.PreSalePurchase[] memory preSalePurchases = clankerPreSale.getPreSalePurchases(3);
        assertEq(preSalePurchases.length, 1);
        assertEq(preSalePurchases[0].user, not_proxystudio);
        assertEq(preSalePurchases[0].bpsBought, 1000);

        // Get the presale purchases for the user
        IClankerFactory.PreSalePurchase[] memory preSalePurchasesForUser = clankerPreSale.getPreSalePurchasesForUser(3, not_proxystudio);
        assertEq(preSalePurchasesForUser.length, 1);
        assertEq(preSalePurchasesForUser[0].user, not_proxystudio);
        assertEq(preSalePurchasesForUser[0].bpsBought, 1000);

        // Get it for some other user
        IClankerFactory.PreSalePurchase[] memory preSalePurchasesForOtherUser = clankerPreSale.getPreSalePurchasesForUser(3, proxystudio);
        assertEq(preSalePurchasesForOtherUser.length, 0);
    }
}
