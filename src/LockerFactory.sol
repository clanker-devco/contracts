// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LpLocker} from "./LpLocker.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LockerFactory is Ownable(msg.sender) {
    event deployed(
        address indexed lockerAddress,
        address indexed owner,
        uint256 tokenId,
        uint256 lockingPeriod
    );

    address public feeRecipient;

    constructor() {
        feeRecipient = msg.sender;
    }

    function deploy(
        address token,
        address beneficiary,
        uint64 durationSeconds,
        uint256 tokenId,
        uint256 fees
    ) public payable returns (address) {
        address newLockerAddress = address(
            new LpLocker(
                token,
                beneficiary,
                durationSeconds,
                fees,
                feeRecipient
            )
        );

        if (newLockerAddress == address(0)) {
            revert("Invalid address");
        }

        emit deployed(newLockerAddress, beneficiary, tokenId, durationSeconds);

        return newLockerAddress;
    }

    function setFeeRecipient(address _feeRecipient) public onlyOwner {
        feeRecipient = _feeRecipient;
    }
}
