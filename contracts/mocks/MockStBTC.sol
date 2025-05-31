// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockStBTC is ERC20 {
    constructor(string memory name, string memory symbol, address initialHolder) ERC20(name, symbol) {
        _mint(initialHolder, 1_000_000 ether);
    }
}
