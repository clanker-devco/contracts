// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface LPLocker {
    function collectFees(address _recipient, uint256 _tokenId) external;
}
