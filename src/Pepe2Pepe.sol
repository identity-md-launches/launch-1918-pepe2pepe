// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Pepe2Pepe (P2P)
/// @notice Fixed-supply ERC-20: the deploying caller receives the entire supply once.
contract Pepe2Pepe is ERC20 {
    /// @notice One billion tokens expressed in the token's 18-decimal base units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Pepe2Pepe", "P2P") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
