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
    IUniswapV3Factory public uniswapV3Factory;
    INonfungiblePositionManager public positionManager;
    address public swapRouter;

    bool public deprecated;
    bool public bundleFeeSwitch;

    mapping(address => bool) public admins;

    struct DeploymentInfo {
        address token;
        uint256 lpNftId;
        address locker;
    }

    mapping(address => DeploymentInfo[]) public tokensDeployedByUsers;

    event TokenCreated(
        address tokenAddress,
        uint256 lpNftId,
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
        returns (ClankerToken token, uint256 tokenId)
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

        // Makes sure that the token address is less than the WETH address. This is so that the token
        // is first in the pool. Just makes things consistent.
        require(address(token) < weth, "Invalid salt");

        uint160 sqrtPriceX96 = _initialTick.getSqrtRatioAtTick();
        address pool = uniswapV3Factory.createPool(address(token), weth, _fee);
        IUniswapV3Factory(pool).initialize(sqrtPriceX96);

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams(
                address(token),
                weth,
                _fee,
                _initialTick,
                maxUsableTick(tickSpacing),
                _supply,
                0,
                0,
                0,
                address(this),
                block.timestamp
            );

        token.approve(address(positionManager), _supply);
        (tokenId, , , ) = positionManager.mint(params);

        address lockerAddress = liquidityLocker.deploy(
            address(positionManager),
            _deployer,
            defaultLockingPeriod,
            tokenId,
            lpFeesCut
        );

        positionManager.safeTransferFrom(address(this), lockerAddress, tokenId);

        ILocker(lockerAddress).initializer(tokenId);

        if (msg.value > 0) {
            uint256 remainingFundsToBuyTokens = msg.value;
            if (bundleFeeSwitch) {
                uint256 protocolFees = (msg.value * taxRate) / 1000;
                remainingFundsToBuyTokens = msg.value - protocolFees;

                (bool success, ) = payable(taxCollector).call{
                    value: protocolFees
                }("");

                if (!success) {
                    revert("Failed to send protocol fees");
                }
            }

            ExactInputSingleParams memory swapParams = ExactInputSingleParams({
                tokenIn: weth, // The token we are exchanging from (ETH wrapped as WETH)
                tokenOut: address(token), // The token we are exchanging to
                fee: _fee, // The pool fee
                recipient: _deployer, // The recipient address
                amountIn: remainingFundsToBuyTokens, // The amount of ETH (WETH) to be swapped
                amountOutMinimum: 0, // Minimum amount to receive
                sqrtPriceLimitX96: 0 // No price limit
            });

            // The call to `exactInputSingle` executes the swap.
            ISwapRouter(swapRouter).exactInputSingle{
                value: remainingFundsToBuyTokens
            }(swapParams);
        }

        tokensDeployedByUsers[_deployer].push(
            DeploymentInfo({
                token: address(token),
                lpNftId: tokenId,
                locker: lockerAddress
            })
        );

        emit TokenCreated(
            address(token),
            tokenId,
            _deployer,
            _fid,
            _name,
            _symbol,
            _supply,
            lockerAddress,
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

        ILocker(tokenInfo.locker).collectFees(msg.sender, tokenInfo.lpNftId);
    }

    function toggleBundleFeeSwitch(bool _enabled) external onlyOwner {
        bundleFeeSwitch = _enabled;
    }

    function setDeprecated(bool _deprecated) external onlyOwner {
        deprecated = _deprecated;
    }

    function updateTaxCollector(address newCollector) external onlyOwner {
        taxCollector = newCollector;
    }

    function updateLiquidityLocker(address newLocker) external onlyOwner {
        liquidityLocker = ILockerFactory(newLocker);
    }

    function updateDefaultLockingPeriod(uint64 newPeriod) external onlyOwner {
        defaultLockingPeriod = newPeriod;
    }

    function updateProtocolFees(uint8 newFee) external onlyOwner {
        lpFeesCut = newFee;
    }

    function updateTaxRate(uint8 newRate) external onlyOwner {
        taxRate = newRate;
    }
}

/// @notice Given a tickSpacing, compute the maximum usable tick
function maxUsableTick(int24 tickSpacing) pure returns (int24) {
    unchecked {
        return (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
    }
}
