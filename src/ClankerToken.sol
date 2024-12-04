// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

contract ClankerToken is ERC20, ERC20Permit, ERC20Votes, ERC20Burnable {
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
}
