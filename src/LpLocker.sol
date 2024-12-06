// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {NonFungibleContract} from "./IManager.sol";

interface INonfungiblePositionManager is IERC721 {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);
}

contract LpLocker is Ownable, IERC721Receiver {
    event LockId(uint256 _id);
    event Received(address indexed from, uint256 tokenId);

    error NotOwner(address owner);

    event ClaimedFees(
        address indexed claimer,
        address indexed token0,
        address indexed token1,
        uint256 amount0,
        uint256 amount1,
        uint256 totalAmount1,
        uint256 totalAmount0
    );

    uint256 wethPositionId;
    uint256 clankerPositionId;
    address private immutable e721Token =
        0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    NonFungibleContract private positionManager;
    string public constant version = "0.0.2";
    uint256 public _clankerTeamFee;
    address public _clankerTeamRecipient;
    address public _userFeeRecipient;

    /**
     * @dev Sets the sender as the initial owner, the beneficiary as the pending owner, and the duration for the lock
     * vesting duration of the vesting wallet.
     */
    constructor(
        address beneficiary,
        uint256 clankerTeamFee,
        address clankerTeamRecipient
    ) Ownable(clankerTeamRecipient) {
        _clankerTeamFee = clankerTeamFee;
        _clankerTeamRecipient = clankerTeamRecipient;
        _userFeeRecipient = beneficiary;
    }

    function initializer(
        uint256 _wethPositionId,
        uint256 _clankerPositionId
    ) public {
        wethPositionId = _wethPositionId;
        clankerPositionId = _clankerPositionId;
        positionManager = NonFungibleContract(e721Token);

        if (positionManager.ownerOf(wethPositionId) != address(this)) {
            IERC721(e721Token).transferFrom(
                owner(),
                address(this),
                wethPositionId
            );
        }
        if (positionManager.ownerOf(clankerPositionId) != address(this)) {
            IERC721(e721Token).transferFrom(
                owner(),
                address(this),
                clankerPositionId
            );
        }

        emit LockId(wethPositionId);
        emit LockId(clankerPositionId);
    }

    receive() external payable virtual {}

    // Withdraw ETH from the contract
    function withdrawETH(address recipient) public onlyOwner {
        payable(recipient).transfer(address(this).balance);
    }

    // Withdraw ERC20 tokens from the contract
    function withdrawERC20(address _token, address recipient) public onlyOwner {
        IERC20 IToken = IERC20(_token);
        IToken.transfer(recipient, IToken.balanceOf(address(this)));
    }

    function withdrawERC20(address _token) public {
        require(owner() == msg.sender, "only owner can call");
        IERC20 IToken = IERC20(_token);
        IToken.transferFrom(address(this), owner(), IToken.balanceOf(owner()));
    }

    //Use collect fees to collect the fees
    function collectFees(uint256 _tokenId) public {
        INonfungiblePositionManager nonfungiblePositionManager = INonfungiblePositionManager(
                e721Token
            );

        (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                tokenId: _tokenId
            })
        );

        (, , address token0, address token1, , , , , , , , ) = positionManager
            .positions(_tokenId);

        IERC20 feeToken0 = IERC20(token0);
        IERC20 feeToken1 = IERC20(token1);

        uint256 protocolFee0 = (amount0 * _clankerTeamFee) / 100;
        uint256 protocolFee1 = (amount1 * _clankerTeamFee) / 100;

        uint256 recipientFee0 = amount0 - protocolFee0;
        uint256 recipientFee1 = amount1 - protocolFee1;

        feeToken0.transfer(_userFeeRecipient, recipientFee0);
        feeToken1.transfer(_userFeeRecipient, recipientFee1);

        feeToken0.transfer(_clankerTeamRecipient, protocolFee0);
        feeToken1.transfer(_clankerTeamRecipient, protocolFee1);

        emit ClaimedFees(
            _userFeeRecipient,
            token0,
            token1,
            recipientFee0,
            recipientFee1,
            amount0,
            amount1
        );
    }

    function onERC721Received(
        address,
        address from,
        uint256 id,
        bytes calldata
    ) external override returns (bytes4) {
        emit Received(from, id);

        return IERC721Receiver.onERC721Received.selector;
    }
}
