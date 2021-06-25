// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import './owner/Operator.sol';

contract FiftyKeeper is Context, ERC20, Operator {
    constructor() public ERC20('50 Keeper', '50K') {
        _mint(msg.sender, 200001 ether);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlySecondOperator {
        _token.transfer(_to, _amount);
    }
}

