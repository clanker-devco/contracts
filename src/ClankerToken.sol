// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import { IERC7802 } from "@contracts-bedrock/interfaces/L2/IERC7802.sol";
import { Predeploys } from "@contracts-bedrock/src/libraries/Predeploys.sol";
import { Unauthorized } from "@contracts-bedrock/src/libraries/errors/CommonErrors.sol";

contract ClankerToken is ERC20, ERC20Permit, ERC20Votes, ERC20Burnable, IERC7802 {
    error NotDeployer();

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    address private _deployer;
    uint256 private _fid;
    string private _image;
    string private _castHash;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address deployer_,
        uint256 fid_,
        string memory image_,
        string memory castHash_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        _deployer = deployer_;
        _fid = fid_;
        _image = image_;
        _castHash = castHash_;
        _mint(msg.sender, maxSupply_);
    }

    function updateImage(string memory image_) public {
        if (msg.sender != _deployer) {
            revert NotDeployer();
        }
        _image = image_;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(
        address owner
    ) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function fid() public view returns (uint256) {
        return _fid;
    }

    function deployer() public view returns (address) {
        return _deployer;
    }

    function image() public view returns (string memory) {
        return _image;
    }

    function castHash() public view returns (string memory) {
        return _castHash;
    }

    function crosschainMint(address _to, uint256 _amount) external {
        // Only the `SuperchainTokenBridge` has permissions to mint tokens during crosschain transfers.
        if (msg.sender != Predeploys.SUPERCHAIN_TOKEN_BRIDGE) revert Unauthorized();
        
        // Mint tokens to the `_to` account's balance.
        _mint(_to, _amount);

        // Emit the CrosschainMint event included on IERC7802 for tracking token mints associated with cross chain transfers.
        emit CrosschainMint(_to, _amount, msg.sender);
    }

    function crosschainBurn(address _from, uint256 _amount) external {
        // Only the `SuperchainTokenBridge` has permissions to burn tokens during crosschain transfers.
        if (msg.sender != Predeploys.SUPERCHAIN_TOKEN_BRIDGE) revert Unauthorized();

        // Burn the tokens from the `_from` account's balance.
        _burn(_from, _amount);

        // Emit the CrosschainBurn event included on IERC7802 for tracking token burns associated with cross chain transfers.
        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    function supportsInterface(bytes4 _interfaceId) public pure returns (bool) {
        return _interfaceId == type(IERC7802).interfaceId || _interfaceId == type(IERC20).interfaceId
            || _interfaceId == type(IERC165).interfaceId;
    }
}
