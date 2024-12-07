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
    error NotAdmin(address user);

    LpLockerv2 public liquidityLocker;
    string public constant version = "0.0.2";

    address public weth = 0x4200000000000000000000000000000000000006;
    address public clankerToken = 0x1bc0c42215582d5A085795f4baDbaC3ff36d1Bcb;

    IUniswapV3Factory public uniswapV3Factory;
    INonfungiblePositionManager public positionManager;
    address public swapRouter;

    bool public deprecated;

    uint256 public initialClankerBuyAmount;

    mapping(address => bool) public admins;

    struct DeploymentInfo {
        address token;
        uint256 wethPositionId;
        uint256 clankerPositionId;
        address locker;
    }

    mapping(address => DeploymentInfo[]) public tokensDeployedByUsers;

    event TokenCreated(
        address tokenAddress,
        uint256 wethPositionId,
        uint256 clankerPositionId,
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

    function deployToken(
        string calldata _name,
        string calldata _symbol,
        uint256 _supply,
        int24 _initialTickWeth,
        int24 _initialTickClanker,
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
            uint256 wethPositionId,
            uint256 clankerPositionId
        )
    {
        if (deprecated) revert Deprecated();

        int24 tickSpacing = uniswapV3Factory.feeAmountTickSpacing(_fee);

        require(
            tickSpacing != 0 && _initialTickWeth % tickSpacing == 0,
            "Invalid tick"
        );
        require(
            tickSpacing != 0 && _initialTickClanker % tickSpacing == 0,
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

        // Makes sure that the token address is less than the WETH address. This is so that the token
        // is first in the pool. Just makes things consistent.
        require(address(token) < weth, "Invalid salt");
        require(address(token) < clankerToken, "Invalid salt");

        uint160 sqrtPriceX96Weth = _initialTickWeth.getSqrtRatioAtTick();
        uint160 sqrtPriceX96Clanker = _initialTickClanker.getSqrtRatioAtTick();

        // Create weth pool
        address wethPool = uniswapV3Factory.createPool(
            address(token),
            weth,
            _fee
        );

        // Create clanker pool
        address clankerPool = uniswapV3Factory.createPool(
            address(token),
            clankerToken,
            _fee
        );

        IUniswapV3Factory(wethPool).initialize(sqrtPriceX96Weth);
        IUniswapV3Factory(clankerPool).initialize(sqrtPriceX96Clanker);

        uint256 halfSupply = _supply / 2;

        INonfungiblePositionManager.MintParams
            memory wethParams = INonfungiblePositionManager.MintParams(
                address(token),
                weth,
                _fee,
                _initialTickWeth,
                maxUsableTick(tickSpacing),
                halfSupply,
                0,
                0,
                0,
                address(this),
                block.timestamp
            );

        INonfungiblePositionManager.MintParams
            memory clankerParams = INonfungiblePositionManager.MintParams(
                address(token),
                clankerToken,
                _fee,
                _initialTickClanker,
                maxUsableTick(tickSpacing),
                halfSupply,
                0,
                0,
                0,
                address(this),
                block.timestamp
            );

        token.approve(address(positionManager), _supply);
        (wethPositionId, , , ) = positionManager.mint(wethParams);
        (clankerPositionId, , , ) = positionManager.mint(clankerParams);

        positionManager.safeTransferFrom(
            address(this),
            address(liquidityLocker),
            wethPositionId
        );
        positionManager.safeTransferFrom(
            address(this),
            address(liquidityLocker),
            clankerPositionId
        );

        liquidityLocker.addUserFeeRecipient(
            LpLockerv2.UserFeeRecipient({
                recipient: _deployer,
                lpTokenId: wethPositionId
            })
        );

        liquidityLocker.addUserFeeRecipient(
            LpLockerv2.UserFeeRecipient({
                recipient: _deployer,
                lpTokenId: clankerPositionId
            })
        );

        if (msg.value > 0) {
            ExactInputSingleParams memory swapParamsTokenWeth = ExactInputSingleParams({
                tokenIn: weth, // The token we are exchanging from (ETH wrapped as WETH)
                tokenOut: address(token), // The token we are exchanging to
                fee: _fee, // The pool fee
                recipient: _deployer, // The recipient address
                amountIn: msg.value, // The amount of ETH (WETH) to be swapped
                amountOutMinimum: 0, // Minimum amount to receive
                sqrtPriceLimitX96: 0 // No price limit
            });

            // The call to `exactInputSingle` executes the swap.
            ISwapRouter(swapRouter).exactInputSingle{value: msg.value}(
                swapParamsTokenWeth
            );

            IERC20(clankerToken).transferFrom(
                msg.sender,
                address(this),
                initialClankerBuyAmount
            );

            // Buy some token with the clanker
            ExactInputSingleParams memory swapParamsTokenClanker = ExactInputSingleParams({
                tokenIn: clankerToken, // The token we are exchanging from (ETH wrapped as WETH)
                tokenOut: address(token), // The token we are exchanging to
                fee: _fee, // The pool fee
                recipient: _deployer, // The recipient address
                amountIn: initialClankerBuyAmount, // The amount of CLANKER to be swapped
                amountOutMinimum: 0, // Minimum amount to receive
                sqrtPriceLimitX96: 0 // No price limit
            });

            // Approve clanker to the swap router
            IERC20(clankerToken).approve(swapRouter, initialClankerBuyAmount);

            ISwapRouter(swapRouter).exactInputSingle(swapParamsTokenClanker);
        }

        tokensDeployedByUsers[_deployer].push(
            DeploymentInfo({
                token: address(token),
                wethPositionId: wethPositionId,
                clankerPositionId: clankerPositionId,
                locker: address(liquidityLocker)
            })
        );

        emit TokenCreated(
            address(token),
            wethPositionId,
            clankerPositionId,
            _deployer,
            _fid,
            _name,
            _symbol,
            _supply,
            address(liquidityLocker),
            _castHash
        );
    }

    function setInitialClankerBuyAmount(uint256 amount) external onlyOwner {
        initialClankerBuyAmount = amount;
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

        ILocker(tokenInfo.locker).collectFees(tokenInfo.wethPositionId);
        ILocker(tokenInfo.locker).collectFees(tokenInfo.clankerPositionId);
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
