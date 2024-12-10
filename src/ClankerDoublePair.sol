// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {INonfungiblePositionManager, IUniswapV3Factory, ILockerFactory, ILocker, ExactInputSingleParams, ISwapRouter} from "./interface.sol";
import {ClankerToken} from "./ClankerToken.sol";

contract Clanker is Ownable {
    using TickMath for int24;

    error Deprecated();
    error NotAdmin(address user);

    address public taxCollector;
    uint64 public defaultLockingPeriod = 33275115461;
    uint8 public taxRate = 25; // 25 / 1000 -> 2.5 %
    uint8 public lpFeesCut = 50; // 5 / 100 -> 5%
    uint8 public protocolCut = 30; // 3 / 100 -> 3%
    ILockerFactory public liquidityLocker;

    address public weth;
    address public constant clanker =
        0x1bc0c42215582d5A085795f4baDbaC3ff36d1Bcb; // Hardcoded CLANKER address
    IUniswapV3Factory public uniswapV3Factory;
    INonfungiblePositionManager public positionManager;
    address public swapRouter;

    bool public deprecated;
    bool public bundleFeeSwitch;

    mapping(address => bool) public admins;

    struct DeploymentInfo {
        address token;
        uint256 lpNftIdWeth;
        uint256 lpNftIdClanker;
        address lockerWeth;
        address lockerClanker;
    }

    mapping(address => DeploymentInfo[]) public tokensDeployedByUsers;

    event TokenCreated(
        address tokenAddress,
        uint256 lpNftIdWeth,
        uint256 lpNftIdClanker,
        address deployer,
        uint256 fid,
        string name,
        string symbol,
        uint256 supply,
        address lockerAddressWeth,
        address lockerAddressClanker,
        string castHash
    );

    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner() && !admins[msg.sender])
            revert NotAdmin(msg.sender);
        _;
    }

    constructor(
        address taxCollector_,
        address weth_,
        address locker_,
        address uniswapV3Factory_,
        address positionManager_,
        uint64 defaultLockingPeriod_,
        address swapRouter_,
        address owner_
    ) Ownable(owner_) {
        taxCollector = taxCollector_;
        weth = weth_;
        liquidityLocker = ILockerFactory(locker_);
        uniswapV3Factory = IUniswapV3Factory(uniswapV3Factory_);
        positionManager = INonfungiblePositionManager(positionManager_);
        defaultLockingPeriod = defaultLockingPeriod_;
        swapRouter = swapRouter_;
    }

    function getTokensDeployedByUser(
        address user
    ) external view returns (DeploymentInfo[] memory) {
        return tokensDeployedByUsers[user];
    }

    function deployToken(
        string calldata _name,
        string calldata _symbol,
        uint256 _supply,
        int24 _initialTick,
        uint24 _fee,
        bytes32 _salt,
        address _deployer,
        uint256 _fid,
        string memory _image,
        string memory _castHash
    )
        external
        payable
        onlyOwnerOrAdmin
        returns (
            ClankerToken token,
            uint256 tokenIdWeth,
            uint256 tokenIdClanker
        )
    {
        if (deprecated) revert Deprecated();

        int24 tickSpacing = uniswapV3Factory.feeAmountTickSpacing(_fee);

        require(
            tickSpacing != 0 && _initialTick % tickSpacing == 0,
            "Invalid tick"
        );

        token = new ClankerToken{salt: keccak256(abi.encode(_deployer, _salt))}(
            _name,
            _symbol,
            _supply,
            _deployer,
            _fid,
            _image,
            _castHash
        );

        // Ensure the token address is less than WETH and CLANKER addresses
        require(address(token) < weth, "Invalid salt");
        require(address(token) < clanker, "Invalid salt");

        uint160 sqrtPriceX96 = _initialTick.getSqrtRatioAtTick();

        // Create and initialize the pool with WETH
        {
            (address token0, address token1) = sortTokens(address(token), weth);
            address pool = uniswapV3Factory.createPool(token0, token1, _fee);
            IUniswapV3Factory(pool).initialize(sqrtPriceX96);
        }

        // Create and initialize the pool with CLANKER
        {
            (address token0, address token1) = sortTokens(
                address(token),
                clanker
            );
            address pool = uniswapV3Factory.createPool(token0, token1, _fee);
            IUniswapV3Factory(pool).initialize(sqrtPriceX96);
        }

        uint256 halfSupply = _supply / 2;

        // Approve the position manager to spend tokens
        token.approve(address(positionManager), _supply);

        // Mint position for the WETH pool
        INonfungiblePositionManager.MintParams
            memory paramsWeth = INonfungiblePositionManager.MintParams({
                token0: address(token),
                token1: weth,
                fee: _fee,
                tickLower: _initialTick,
                tickUpper: maxUsableTick(tickSpacing),
                amount0Desired: halfSupply,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            });
        (tokenIdWeth, , , ) = positionManager.mint(paramsWeth);

        // Mint position for the CLANKER pool
        INonfungiblePositionManager.MintParams
            memory paramsClanker = INonfungiblePositionManager.MintParams({
                token0: address(token),
                token1: clanker,
                fee: _fee,
                tickLower: _initialTick,
                tickUpper: maxUsableTick(tickSpacing),
                amount0Desired: halfSupply,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            });
        (tokenIdClanker, , , ) = positionManager.mint(paramsClanker);

        // Deploy and initialize lockers for WETH pool
        address lockerAddressWeth = liquidityLocker.deploy(
            address(positionManager),
            _deployer,
            defaultLockingPeriod,
            tokenIdWeth,
            lpFeesCut
        );
        positionManager.safeTransferFrom(
            address(this),
            lockerAddressWeth,
            tokenIdWeth
        );
        ILocker(lockerAddressWeth).initializer(tokenIdWeth);

        // Deploy and initialize lockers for CLANKER pool
        address lockerAddressClanker = liquidityLocker.deploy(
            address(positionManager),
            _deployer,
            defaultLockingPeriod,
            tokenIdClanker,
            lpFeesCut
        );
        positionManager.safeTransferFrom(
            address(this),
            lockerAddressClanker,
            tokenIdClanker
        );
        ILocker(lockerAddressClanker).initializer(tokenIdClanker);

        // Handle any swapping logic if needed (e.g., swapping ETH for tokens)

        tokensDeployedByUsers[_deployer].push(
            DeploymentInfo({
                token: address(token),
                lpNftIdWeth: tokenIdWeth,
                lpNftIdClanker: tokenIdClanker,
                lockerWeth: lockerAddressWeth,
                lockerClanker: lockerAddressClanker
            })
        );

        emit TokenCreated(
            address(token),
            tokenIdWeth,
            tokenIdClanker,
            _deployer,
            _fid,
            _name,
            _symbol,
            _supply,
            lockerAddressWeth,
            lockerAddressClanker,
            _castHash
        );
    }

    // Helper function to sort token addresses
    function sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        if (tokenA < tokenB) {
            (token0, token1) = (tokenA, tokenB);
        } else {
            (token0, token1) = (tokenB, tokenA);
        }
    }

    // ... (rest of your contract code remains the same, updating any references to clanker as needed)
}
