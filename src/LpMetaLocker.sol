// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {NonFungibleContract} from "./IManager.sol";

contract LpMetaLocker is Ownable, IERC721Receiver {
    event Received(address indexed from, uint256 tokenId);

    error NotOwner(address owner);
    error InvalidTokenId(uint256 tokenId);

    event ClaimedFees(
        address indexed claimer,
        address indexed token0,
        address indexed token1,
        uint256 amount0,
        uint256 amount1,
        uint256 totalAmount1,
        uint256 totalAmount0
    );

    IERC721 private SafeERC721;
    address private immutable e721Token;
    address public positionManager = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    string public constant version = "0.0.1";
    uint256 public _clankerTeamFee;
    address public _clankerTeamRecipient;

    struct UserFeeRecipient {
        address recipient;
        uint256 lpTokenId;
    }

    struct TeamFeeRecipient {
        address recipient;
        uint256 fee;
        uint256 lpTokenId;
    }

    UserFeeRecipient[] public _userFeeRecipients;
    mapping(uint256 => UserFeeRecipient) public _userFeeRecipientForToken;
    mapping(uint256 => TeamFeeRecipient)
        public _teamOverrideFeeRecipientForToken;

    mapping(address => uint256[]) public _userTokenIds;

    constructor(
        address token, // Address of the ERC721 Uniswap V3 LP NFT
        address clankerTeamRecipient, // clanker team address to receive portion of the fees
        uint256 clankerTeamFee // clanker team fee percentage
    ) payable Ownable(clankerTeamRecipient) {
        SafeERC721 = IERC721(token);
        e721Token = token;
        _clankerTeamFee = clankerTeamFee;
        _clankerTeamRecipient = clankerTeamRecipient;
    }

    function setOverrideTeamFeesForToken(
        uint256 tokenId,
        address newTeamRecipient,
        uint256 newTeamFee
    ) public onlyOwner {
        _teamOverrideFeeRecipientForToken[tokenId] = TeamFeeRecipient({
            recipient: newTeamRecipient,
            fee: newTeamFee,
            lpTokenId: tokenId
        });
    }

    // Update the clanker team fee
    function updateClankerTeamFee(uint256 newFee) public onlyOwner {
        _clankerTeamFee = newFee;
    }

    // Update the clanker team recipient
    function updateClankerTeamRecipient(address newRecipient) public onlyOwner {
        _clankerTeamRecipient = newRecipient;
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

    //Use collect fees to collect the fees
    function collectFees(uint256 _tokenId) public {
        // Get the _userFeeRecipients for the tokenId
        UserFeeRecipient memory userFeeRecipient = _userFeeRecipientForToken[
            _tokenId
        ];

        address _recipient = userFeeRecipient.recipient;

        if (_recipient == address(0)) {
            revert InvalidTokenId(_tokenId);
        }

        NonFungibleContract nonfungiblePositionManager = NonFungibleContract(
            positionManager
        );

        (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.collect(
            NonFungibleContract.CollectParams({
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                tokenId: _tokenId
            })
        );

        (
            ,
            ,
            address token0,
            address token1,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(_tokenId);

        IERC20 feeToken0 = IERC20(token0);
        IERC20 feeToken1 = IERC20(token1);

        address teamRecipient = _clankerTeamRecipient;
        uint256 teamFee = _clankerTeamFee;

        TeamFeeRecipient
            memory overrideFeeRecipient = _teamOverrideFeeRecipientForToken[
                _tokenId
            ];

        if (overrideFeeRecipient.recipient != address(0)) {
            teamRecipient = overrideFeeRecipient.recipient;
            teamFee = overrideFeeRecipient.fee;
        }

        uint256 protocolFee0 = (amount0 * teamFee) / 100;
        uint256 protocolFee1 = (amount1 * teamFee) / 100;

        uint256 recipientFee0 = amount0 - protocolFee0;
        uint256 recipientFee1 = amount1 - protocolFee1;

        feeToken0.transfer(_recipient, recipientFee0);
        feeToken1.transfer(_recipient, recipientFee1);

        feeToken0.transfer(teamRecipient, protocolFee0);
        feeToken1.transfer(teamRecipient, protocolFee1);

        emit ClaimedFees(
            _recipient,
            token0,
            token1,
            recipientFee0,
            recipientFee1,
            amount0,
            amount1
        );
    }

    function getLpTokenIdsForUser(
        address user
    ) public view returns (uint256[] memory) {
        return _userTokenIds[user];
    }

    function setUserFeeRecipients(
        UserFeeRecipient[] memory recipients
    ) public onlyOwner {
        _userFeeRecipients = recipients;
        for (uint256 i = 0; i < recipients.length; i++) {
            _userFeeRecipientForToken[recipients[i].lpTokenId] = recipients[i];
            _userTokenIds[recipients[i].recipient].push(
                recipients[i].lpTokenId
            );
        }
    }

    function addUserFeeRecipient(
        UserFeeRecipient memory recipient
    ) public onlyOwner {
        _userFeeRecipients.push(recipient);
        _userFeeRecipientForToken[recipient.lpTokenId] = recipient;
        _userTokenIds[recipient.recipient].push(recipient.lpTokenId);
    }

    function onERC721Received(
        address,
        address from,
        uint256 id,
        bytes calldata
    ) external override returns (bytes4) {
        // Only clanker team EOA can send the NFT here
        if (from != _clankerTeamRecipient) {
            revert NotOwner(from);
        }

        emit Received(from, id);
        return IERC721Receiver.onERC721Received.selector;
    }
}
