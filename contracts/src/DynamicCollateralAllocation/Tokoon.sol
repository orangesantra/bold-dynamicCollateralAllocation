// SPDX-License-Identifier: MIT
 // OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.24;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract Tokoon is ERC20 {  
    constructor (string memory name, string memory
     symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000000 * 10 ** decimals());
    }
}