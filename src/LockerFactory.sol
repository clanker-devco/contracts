// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LpLocker} from "./LpLocker.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LockerFactory is Ownable(msg.sender) {
    address public feeRecipient;

    constructor() {
        feeRecipient = msg.sender;
    }

    function deploy(
        address beneficiary,
        uint256 fees
    ) public returns (address) {
        return address(new LpLocker(beneficiary, fees, feeRecipient));
    }

    function setFeeRecipient(address _feeRecipient) public onlyOwner {
        feeRecipient = _feeRecipient;
    }
}
