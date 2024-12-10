// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INonfungiblePositionManager, IUniswapV3Factory, ILockerFactory, ILocker, ExactInputSingleParams, ISwapRouter} from "./interface.sol";
import {ClankerToken} from "./ClankerToken.sol";
import {LpLockerv2} from "./LpLockerv2.sol";

contract Clanker is Ownable {
    using TickMath for int24;

    error Deprecated();
    error InvalidConfig();
    error NotAdmin(address user);

    LpLockerv2 public liquidityLocker;
    string public constant version = "0.0.2";

    address public weth = 0x4200000000000000000000000000000000000006;
    address public degen = 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed;
    address public clankerToken = 0x1bc0c42215582d5A085795f4baDbaC3ff36d1Bcb;
    address public higher = 0x0578d8A44db98B23BF096A382e016e29a5Ce0ffe;

    IUniswapV3Factory public uniswapV3Factory;
    INonfungiblePositionManager public positionManager;
    address public swapRouter;

    bool public deprecated;

    mapping(address => bool) public admins;

    enum PoolType {
        WETH,
        CLANKER,
        DEGEN,
        HIGHER
    }

    struct PoolConfig {
        int24 tick;
        PoolType poolType;
    }

    struct DeploymentInfo {
        address token;
        uint256 positionId;
        address locker;
    }

    mapping(address => DeploymentInfo[]) public tokensDeployedByUsers;

    event TokenCreated(
        address tokenAddress,
        uint256 positionId,
        address deployer,
        uint256 fid,
        string name,
        string symbol,
        uint256 supply,
        address lockerAddress,
        string castHash
    );

    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner() && !admins[msg.sender])
            revert NotAdmin(msg.sender);
        _;
    }

    constructor(
        address locker_,
        address uniswapV3Factory_,
        address positionManager_,
        address swapRouter_,
        address owner_
    ) Ownable(owner_) {
        liquidityLocker = LpLockerv2(locker_);
        uniswapV3Factory = IUniswapV3Factory(uniswapV3Factory_);
        positionManager = INonfungiblePositionManager(positionManager_);
        swapRouter = swapRouter_;
    }

    function getTokensDeployedByUser(
        address user
    ) external view returns (DeploymentInfo[] memory) {
        return tokensDeployedByUsers[user];
    }

    function configurePool(
        address newToken,
        address pairedToken,
        int24 tick,
        int24 tickSpacing,
        uint24 fee,
        uint256 supplyPerPool,
        address deployer
    ) internal returns (uint256 positionId) {
        require(newToken < pairedToken, "Invalid salt");

        uint160 sqrtPriceX96 = tick.getSqrtRatioAtTick();

        // Create pool
        address pool = uniswapV3Factory.createPool(newToken, pairedToken, fee);

        // Initialize pool
        IUniswapV3Factory(pool).initialize(sqrtPriceX96);

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams(
                newToken,
                pairedToken,
                fee,
                tick,
                maxUsableTick(tickSpacing),
                supplyPerPool,
                0,
                0,
                0,
                address(this),
                block.timestamp
            );
        (positionId, , , ) = positionManager.mint(params);

        positionManager.safeTransferFrom(
            address(this),
            address(liquidityLocker),
            positionId
        );

        liquidityLocker.addUserFeeRecipient(
            LpLockerv2.UserFeeRecipient({
                recipient: deployer,
                lpTokenId: positionId
            })
        );
    }

    function deployToken(
        string calldata _name,
        string calldata _symbol,
        uint256 _supply,
        uint24 _fee,
        bytes32 _salt,
        address _deployer,
        uint256 _fid,
        string memory _image,
        string memory _castHash,
        PoolConfig memory _poolConfig
    )
        external
        payable
        onlyOwnerOrAdmin
        returns (ClankerToken token, uint256 positionId)
    {
        if (deprecated) revert Deprecated();

        int24 tickSpacing = uniswapV3Factory.feeAmountTickSpacing(_fee);
        require(
            tickSpacing != 0 && _poolConfig.tick % tickSpacing == 0,
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

        token.approve(address(positionManager), _supply);

        if (_poolConfig.poolType == PoolType.WETH) {
            positionId = configurePool(
                address(token),
                weth,
                _poolConfig.tick,
                tickSpacing,
                _fee,
                _supply,
                _deployer
            );
        } else if (_poolConfig.poolType == PoolType.CLANKER) {
            positionId = configurePool(
                address(token),
                clankerToken,
                _poolConfig.tick,
                tickSpacing,
                _fee,
                _supply,
                _deployer
            );
        } else if (_poolConfig.poolType == PoolType.DEGEN) {
            positionId = configurePool(
                address(token),
                degen,
                _poolConfig.tick,
                tickSpacing,
                _fee,
                _supply,
                _deployer
            );
        } else if (_poolConfig.poolType == PoolType.HIGHER) {
            positionId = configurePool(
                address(token),
                higher,
                _poolConfig.tick,
                tickSpacing,
                _fee,
                _supply,
                _deployer
            );
        }

        if (msg.value > 0) {
            uint256 amountOut = msg.value;
            // If it's not WETH, we must buy the token first...
            if (_poolConfig.poolType != PoolType.WETH) {
                ExactInputSingleParams memory swapParams = ExactInputSingleParams({
                    tokenIn: weth, // The token we are exchanging from (ETH wrapped as WETH)
                    tokenOut: _poolConfig.poolType == PoolType.CLANKER
                        ? clankerToken
                        : _poolConfig.poolType == PoolType.DEGEN
                        ? degen
                        : higher, // The token we are exchanging to
                    fee: _fee, // The pool fee
                    recipient: address(this), // The recipient address
                    amountIn: msg.value, // The amount of ETH (WETH) to be swapped
                    amountOutMinimum: 0, // Minimum amount to receive
                    sqrtPriceLimitX96: 0 // No price limit
                });

                amountOut = ISwapRouter(swapRouter).exactInputSingle{ // The call to `exactInputSingle` executes the swap.
                    value: msg.value
                }(swapParams);

                IERC20(
                    _poolConfig.poolType == PoolType.CLANKER
                        ? clankerToken
                        : _poolConfig.poolType == PoolType.DEGEN
                        ? degen
                        : higher
                ).approve(
                        address(swapRouter),
                        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
                    );
            }

            ExactInputSingleParams memory swapParamsToken = ExactInputSingleParams({
                tokenIn: _poolConfig.poolType == PoolType.CLANKER
                    ? clankerToken
                    : _poolConfig.poolType == PoolType.DEGEN
                    ? degen
                    : _poolConfig.poolType == PoolType.HIGHER
                    ? higher
                    : weth, // The token we are exchanging from (ETH wrapped as WETH)
                tokenOut: address(token), // The token we are exchanging to
                fee: _fee, // The pool fee
                recipient: _deployer, // The recipient address
                amountIn: amountOut, // The amount of ETH (WETH) to be swapped
                amountOutMinimum: 0, // Minimum amount to receive
                sqrtPriceLimitX96: 0 // No price limit
            });

            // The call to `exactInputSingle` executes the swap.
            ISwapRouter(swapRouter).exactInputSingle{
                value: _poolConfig.poolType == PoolType.WETH ? msg.value : 0
            }(swapParamsToken);
        }

        tokensDeployedByUsers[_deployer].push(
            DeploymentInfo({
                token: address(token),
                positionId: positionId,
                locker: address(liquidityLocker)
            })
        );

        emit TokenCreated(
            address(token),
            positionId,
            _deployer,
            _fid,
            _name,
            _symbol,
            _supply,
            address(liquidityLocker),
            _castHash
        );
    }

    function setAdmin(address admin, bool isAdmin) external onlyOwner {
        admins[admin] = isAdmin;
    }

    function claimFees(address token) external {
        DeploymentInfo[] memory tokens = tokensDeployedByUsers[msg.sender];
        bool found = false;
        DeploymentInfo memory tokenInfo;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].token == token) {
                found = true;
                tokenInfo = tokens[i];
                break;
            }
        }

        if (!found) revert("Token not found");

        ILocker(tokenInfo.locker).collectFees(tokenInfo.positionId);
    }

    function setDeprecated(bool _deprecated) external onlyOwner {
        deprecated = _deprecated;
    }

    function updateLiquidityLocker(address newLocker) external onlyOwner {
        liquidityLocker = LpLockerv2(newLocker);
    }
}

/// @notice Given a tickSpacing, compute the maximum usable tick
function maxUsableTick(int24 tickSpacing) pure returns (int24) {
    unchecked {
        return (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
    }
}
