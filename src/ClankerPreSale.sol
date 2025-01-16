// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ClankerToken} from "./ClankerToken.sol";

interface IClankerFactory {
    struct PreSalePurchase {
        uint256 bpsBought;
        address user;
    }

    struct PoolConfig {
        int24 tick;
        address pairedToken;
        uint24 devBuyFee;
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

    struct PreSaleConfig {
        uint256 bpsAvailable; // maximum 100%
        uint256 ethPerBps; // how much eth per bps
        uint256 endTime; // when it ends (in epoch seconds)
        uint256 bpsSold; // how many bps have been sold so far
        address tokenAddress; // the deployed token address
    }

    function deployToken(
        PreSaleTokenConfig memory preSaleTokenConfig,
        uint256 preSaleId,
        PreSalePurchase[] memory preSalePurchases,
        PreSaleConfig memory preSaleConfig
    ) external payable returns (address tokenAddress, uint256 positionId);
}

contract ClankerPreSale is Ownable, ReentrancyGuard {
    error InvalidConfig();
    error NotAdmin(address user);
    error PreSaleNotFound(uint256 preSaleId);
    error PreSaleEnded(uint256 preSaleId);
    error PreSaleNotEnded(uint256 preSaleId);
    error AlreadyRefunded(uint256 preSaleId);

    address public clankerFactory;

    string public constant version = "0.0.1";

    mapping(address => bool) public admins;

    mapping(uint256 => IClankerFactory.PreSaleConfig) public preSaleConfigs;
    mapping(uint256 => IClankerFactory.PreSaleTokenConfig)
        public preSaleTokenConfigs;
    mapping(uint256 => IClankerFactory.PreSalePurchase[])
        public preSalePurchases;

    mapping(uint256 => mapping(address => IClankerFactory.PreSalePurchase[]))
        public preSalePurchasesForUser;

    mapping(uint256 => bool) public preSaleRefunded;

    event PreSaleCreated(
        uint256 preSaleId,
        uint256 bpsAvailable,
        uint256 ethPerBps,
        uint256 endTime,
        address deployer,
        uint256 fid,
        string name,
        string symbol,
        uint256 supply,
        string castHash
    );

    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner() && !admins[msg.sender])
            revert NotAdmin(msg.sender);
        _;
    }

    constructor(address clankerFactory_, address owner_) Ownable(owner_) {
        clankerFactory = clankerFactory_;
    }

    function getPreSalePurchases(
        uint256 preSaleId
    ) external view returns (IClankerFactory.PreSalePurchase[] memory) {
        return preSalePurchases[preSaleId];
    }

    function getPreSalePurchasesForUser(
        uint256 preSaleId,
        address user
    ) external view returns (IClankerFactory.PreSalePurchase[] memory) {
        IClankerFactory.PreSalePurchase[]
            memory _preSalePurchasesForUser = new IClankerFactory.PreSalePurchase[](
                preSalePurchasesForUser[preSaleId][user].length
            );
        for (
            uint256 i = 0;
            i < preSalePurchasesForUser[preSaleId][user].length;
            i++
        ) {
            _preSalePurchasesForUser[i] = preSalePurchasesForUser[preSaleId][
                user
            ][i];
        }
        return _preSalePurchasesForUser;
    }

    function refundPreSale(uint256 preSaleId) external nonReentrant {
        if (preSaleRefunded[preSaleId]) revert AlreadyRefunded(preSaleId);
        IClankerFactory.PreSaleConfig memory preSaleConfig = preSaleConfigs[
            preSaleId
        ];

        if (preSaleConfig.bpsAvailable == 0) revert PreSaleNotFound(preSaleId);

        // Must be after the period and only if not sold out
        if (preSaleConfig.bpsSold >= preSaleConfig.bpsAvailable)
            revert PreSaleEnded(preSaleId);

        if (block.timestamp < preSaleConfig.endTime)
            revert PreSaleNotEnded(preSaleId);

        for (uint256 i = 0; i < preSalePurchases[preSaleId].length; i++) {
            IClankerFactory.PreSalePurchase memory purchase = preSalePurchases[
                preSaleId
            ][i];
            // Refund user
            payable(purchase.user).transfer(
                (preSaleConfig.ethPerBps * purchase.bpsBought)
            );
        }

        preSaleRefunded[preSaleId] = true;
    }

    function buyIntoPreSale(uint256 preSaleId) external payable nonReentrant {
        IClankerFactory.PreSaleConfig memory preSaleConfig = preSaleConfigs[
            preSaleId
        ];

        if (preSaleConfig.bpsAvailable == 0) revert PreSaleNotFound(preSaleId);
        if (block.timestamp > preSaleConfig.endTime)
            revert PreSaleEnded(preSaleId);
        if (preSaleConfig.bpsSold >= preSaleConfig.bpsAvailable)
            revert PreSaleEnded(preSaleId);

        uint256 bpsToBuy = msg.value / preSaleConfig.ethPerBps;
        uint256 bpsRemaining = preSaleConfig.bpsAvailable -
            preSaleConfig.bpsSold;

        uint256 ethSpent;

        if (bpsToBuy > bpsRemaining) {
            bpsToBuy = bpsRemaining;
            ethSpent = bpsRemaining * preSaleConfig.ethPerBps;
        } else {
            ethSpent = bpsToBuy * preSaleConfig.ethPerBps;
        }

        uint256 ethRefund = msg.value - ethSpent;

        preSaleConfig.bpsSold += bpsToBuy;
        preSaleConfigs[preSaleId] = preSaleConfig;

        preSalePurchases[preSaleId].push(
            IClankerFactory.PreSalePurchase({
                bpsBought: bpsToBuy,
                user: msg.sender
            })
        );

        preSalePurchasesForUser[preSaleId][msg.sender].push(
            IClankerFactory.PreSalePurchase({
                bpsBought: bpsToBuy,
                user: msg.sender
            })
        );

        if (ethRefund > 0) {
            payable(msg.sender).transfer(ethRefund);
        }

        // If the pre sale is sold out, deploy the token
        if (preSaleConfig.bpsSold >= preSaleConfig.bpsAvailable) {
            IClankerFactory.PreSaleTokenConfig
                memory preSaleTokenConfig = preSaleTokenConfigs[preSaleId];
            IClankerFactory.PreSalePurchase[]
                memory preSalePurchasesForDeploy = preSalePurchases[preSaleId];
            IClankerFactory.PreSaleConfig
                memory preSaleConfigForDeploy = preSaleConfigs[preSaleId];

            preSaleConfigForDeploy.bpsSold = preSaleConfig.bpsSold;
            (address tokenAddress, ) = IClankerFactory(
                clankerFactory
            ).deployToken{value: preSaleConfig.bpsSold * preSaleConfig.ethPerBps}(
                preSaleTokenConfig,
                preSaleId,
                preSalePurchasesForDeploy,
                preSaleConfigForDeploy
            );

            preSaleConfigForDeploy.tokenAddress = tokenAddress;
            preSaleConfigs[preSaleId] = preSaleConfigForDeploy;
        }
    }

    function createPreSaleToken(
        IClankerFactory.PreSaleConfig memory _preSaleConfig,
        uint256 _preSaleId,
        IClankerFactory.PreSaleTokenConfig memory _preSaleTokenConfig
    ) external onlyOwnerOrAdmin {
        IClankerFactory.PreSaleConfig memory preSaleConfig = preSaleConfigs[
            _preSaleId
        ];

        if (_preSaleId == 0) revert InvalidConfig();
        if (preSaleConfig.bpsAvailable != 0) revert InvalidConfig();
        if (_preSaleConfig.bpsAvailable >= 10000) revert InvalidConfig();

        preSaleConfigs[_preSaleId] = _preSaleConfig;
        preSaleTokenConfigs[_preSaleId] = _preSaleTokenConfig;

        emit PreSaleCreated(
            _preSaleId,
            _preSaleConfig.bpsAvailable,
            _preSaleConfig.ethPerBps,
            _preSaleConfig.endTime,
            _preSaleTokenConfig._deployer,
            _preSaleTokenConfig._fid,
            _preSaleTokenConfig._name,
            _preSaleTokenConfig._symbol,
            _preSaleTokenConfig._supply,
            _preSaleTokenConfig._castHash
        );
    }

    function setAdmin(address admin, bool isAdmin) external onlyOwner {
        admins[admin] = isAdmin;
    }

    /**
     * @notice Withdraws ETH from the contract to the specified address (emergencies only)
     */
    function withdraw(address to, uint256 amount) external onlyOwner {
        payable(to).transfer(amount);
    }

    function setClankerFactory(address _clankerFactory) external onlyOwner {
        clankerFactory = _clankerFactory;
    }
}
