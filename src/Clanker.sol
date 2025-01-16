// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager, IUniswapV3Factory, ExactInputSingleParams, ISwapRouter, ILpLockerv2, IWETH} from "./interface.sol";
import {ClankerToken} from "./ClankerToken.sol";

library ClankerLib {
    /// @notice Given a tickSpacing, compute the maximum usable tick
    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        }
    }
}

contract Clanker is Ownable {
    using TickMath for int24;

    error Unauthorized();
    error NotFound();
    error Invalid();
    ILpLockerv2 public liquidityLocker;
    string constant version = "0.0.3";

    address public weth = 0x4200000000000000000000000000000000000006;

    IUniswapV3Factory public uniswapV3Factory;
    INonfungiblePositionManager public positionManager;
    address public swapRouter;

    mapping(address => bool) public admins;

    struct PoolConfig {
        int24 tick;
        address pairedToken;
        uint24 devBuyFee;
    }

    struct DeploymentInfo {
        address token;
        uint256 positionId;
        address locker;
    }

    struct PreSaleConfig {
        uint256 bpsAvailable; // maximum 100%
        uint256 ethPerBps; // how much eth per bps
        uint256 endTime; // when it ends (in epoch seconds)
        uint256 bpsSold; // how many bps have been sold so far
        address tokenAddress;
    }

    struct PreSalePurchase {
        uint256 bpsBought;
        address user;
    }

    struct PreSaleTokenConfig {
        string _name;
        string _symbol;
        uint256 _supply;
        uint24 _fee;
        bytes32 _salt;
        address _deployer;
        uint256 _fid;
        string _image;
        string _castHash;
        PoolConfig _poolConfig;
    }

    mapping(address => DeploymentInfo[]) public tokensDeployedByUsers;
    mapping(address => DeploymentInfo) public deploymentInfoForToken;

    event TokenCreated(
        address tokenAddress,
        uint256 positionId,
        address deployer,
        uint256 fid,
        string name,
        string symbol,
        uint256 supply,
        string castHash
    );

    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner() && !admins[msg.sender])
            revert Unauthorized();
        _;
    }

    constructor(
        address locker_,
        address uniswapV3Factory_,
        address positionManager_,
        address swapRouter_,
        address owner_
    ) Ownable(owner_) {
        liquidityLocker = ILpLockerv2(locker_);
        uniswapV3Factory = IUniswapV3Factory(uniswapV3Factory_);
        positionManager = INonfungiblePositionManager(positionManager_);
        IERC20(weth).approve(address(positionManager), type(uint256).max);
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
        address deployer,
        uint256 preSaleEth
    ) internal returns (uint256 positionId) {
        if (newToken >= pairedToken) revert Invalid();
        uint160 sqrtPriceX96 = tick.getSqrtRatioAtTick();

        // Create pool
        address pool = uniswapV3Factory.createPool(newToken, pairedToken, fee);

        // Initialize pool
        IUniswapV3Factory(pool).initialize(sqrtPriceX96);

        if (preSaleEth > 0) {
            // Have to deposit the preSaleEthCollected to weth
            IWETH(weth).deposit{value: preSaleEth}();
        }

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams(
                newToken,
                pairedToken,
                fee,
                preSaleEth > 0 ? -ClankerLib.maxUsableTick(tickSpacing) : tick,
                ClankerLib.maxUsableTick(tickSpacing),
                supplyPerPool,
                preSaleEth,
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

        liquidityLocker.addUserRewardRecipient(
            ILpLockerv2.UserRewardRecipient({
                recipient: deployer,
                lpTokenId: positionId
            })
        );
    }

    function deployToken(
        PreSaleTokenConfig memory preSaleTokenConfig,
        uint256 preSaleId,
        PreSalePurchase[] memory preSalePurchases,
        PreSaleConfig memory preSaleConfig
    )
        external
        payable
        onlyOwnerOrAdmin
        returns (address token, uint256 positionId)
    {
        return
            _deployToken(
                preSaleTokenConfig,
                preSaleId,
                preSalePurchases,
                preSaleConfig
            );
    }

    function deployToken(
        PreSaleTokenConfig memory preSaleTokenConfig
    )
        external
        payable
        onlyOwnerOrAdmin
        returns (address token, uint256 positionId)
    {
        return
            _deployToken(
                preSaleTokenConfig,
                0,
                new PreSalePurchase[](0),
                PreSaleConfig(0, 0, 0, 0, address(0))
            );
    }

    function _deployToken(
        PreSaleTokenConfig memory preSaleTokenConfig,
        uint256 preSaleId,
        PreSalePurchase[] memory preSalePurchases,
        PreSaleConfig memory _preSaleConfig
    ) internal returns (address tokenAddress, uint256 positionId) {
        // Make sure pre sale sold out if it was presale
        if (preSaleId != 0) {
            if (_preSaleConfig.bpsAvailable == 0)
                revert NotFound();
            if (_preSaleConfig.bpsSold < _preSaleConfig.bpsAvailable)
                revert NotFound();
        }

        int24 tickSpacing = uniswapV3Factory.feeAmountTickSpacing(
            preSaleTokenConfig._fee
        );
        require(
            tickSpacing != 0 &&
                preSaleTokenConfig._poolConfig.tick % tickSpacing == 0,
            "Invalid tick"
        );

        ClankerToken token = new ClankerToken{
            salt: keccak256(
                abi.encode(
                    preSaleTokenConfig._deployer,
                    preSaleTokenConfig._salt
                )
            )
        }(
            preSaleTokenConfig._name,
            preSaleTokenConfig._symbol,
            preSaleTokenConfig._supply,
            preSaleTokenConfig._deployer,
            preSaleTokenConfig._fid,
            preSaleTokenConfig._image,
            preSaleTokenConfig._castHash
        );

        tokenAddress = address(token);

        uint256 poolSupply = preSaleTokenConfig._supply;

        if (preSaleId != 0) {
            for (uint256 i = 0; i < preSalePurchases.length; i++) {
                PreSalePurchase memory purchase = preSalePurchases[i];
                // Send tokens to user
                token.transfer(
                    purchase.user,
                    (preSaleTokenConfig._supply * purchase.bpsBought) / 10000
                );
            }
            poolSupply =
                preSaleTokenConfig._supply -
                ((preSaleTokenConfig._supply * _preSaleConfig.bpsSold) / 10000);
        }

        token.approve(address(positionManager), preSaleTokenConfig._supply);

        positionId = configurePool(
            address(token),
            preSaleTokenConfig._poolConfig.pairedToken,
            preSaleTokenConfig._poolConfig.tick,
            tickSpacing,
            preSaleTokenConfig._fee,
            poolSupply,
            preSaleTokenConfig._deployer,
            _preSaleConfig.ethPerBps * _preSaleConfig.bpsSold
        );

        // Can only devbuy if no presale. Otherwise there is a msg.value from the final presale
        // buyer... which we don't want to use.
        if (msg.value > 0 && preSaleId == 0) {
            uint256 amountOut = msg.value;
            // If it's not WETH, we must buy the token first...
            if (preSaleTokenConfig._poolConfig.pairedToken != weth) {
                ExactInputSingleParams memory swapParams = ExactInputSingleParams({
                    tokenIn: weth, // The token we are exchanging from (ETH wrapped as WETH)
                    tokenOut: preSaleTokenConfig._poolConfig.pairedToken, // The token we are exchanging to
                    fee: preSaleTokenConfig._poolConfig.devBuyFee, // The pool fee
                    recipient: address(this), // The recipient address
                    amountIn: msg.value, // The amount of ETH (WETH) to be swapped
                    amountOutMinimum: 0, // Minimum amount to receive
                    sqrtPriceLimitX96: 0 // No price limit
                });

                amountOut = ISwapRouter(swapRouter).exactInputSingle{ // The call to `exactInputSingle` executes the swap.
                    value: msg.value
                }(swapParams);


                IERC20(preSaleTokenConfig._poolConfig.pairedToken).approve(
                    address(swapRouter),
                    type(uint256).max
                );
            }

            ExactInputSingleParams memory swapParamsToken = ExactInputSingleParams({
                tokenIn: preSaleTokenConfig._poolConfig.pairedToken, // The token we are exchanging from (ETH wrapped as WETH)
                tokenOut: address(token), // The token we are exchanging to
                fee: preSaleTokenConfig._fee, // The pool fee
                recipient: preSaleTokenConfig._deployer, // The recipient address
                amountIn: amountOut, // The amount of ETH (WETH) to be swapped
                amountOutMinimum: 0, // Minimum amount to receive
                sqrtPriceLimitX96: 0 // No price limit
            });

            // The call to `exactInputSingle` executes the swap.
            ISwapRouter(swapRouter).exactInputSingle{
                value: preSaleTokenConfig._poolConfig.pairedToken == weth
                    ? msg.value
                    : 0
            }(swapParamsToken);
        }

        DeploymentInfo memory deploymentInfo = DeploymentInfo({
            token: address(token),
            positionId: positionId,
            locker: address(liquidityLocker)
        });

        deploymentInfoForToken[address(token)] = deploymentInfo;
        tokensDeployedByUsers[preSaleTokenConfig._deployer].push(
            deploymentInfo
        );

        emit TokenCreated(
            address(token),
            positionId,
            preSaleTokenConfig._deployer,
            preSaleTokenConfig._fid,
            preSaleTokenConfig._name,
            preSaleTokenConfig._symbol,
            preSaleTokenConfig._supply,
            preSaleTokenConfig._castHash
        );
    }

    function setAdmin(address admin, bool isAdmin) external onlyOwner {
        admins[admin] = isAdmin;
    }

    function claimRewards(address token) external {
        DeploymentInfo memory deploymentInfo = deploymentInfoForToken[token];

        if (deploymentInfo.token == address(0)) revert NotFound();

        ILpLockerv2(deploymentInfo.locker).collectRewards(
            deploymentInfo.positionId
        );
    }

    function updateLiquidityLocker(address newLocker) external onlyOwner {
        liquidityLocker = ILpLockerv2(newLocker);
    }
}
