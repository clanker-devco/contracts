// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface OldLpLocker {
    function collectFees(address _recipient, uint256 _tokenId) external;

    function release() external;
}

interface LPLocker {
    function collectFees(uint256 wethPositionId) external;
}
