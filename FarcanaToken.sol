// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract FarcanaToken is ERC20, Ownable2Step {

    uint256 private constant DECIMALS = 18;
    uint256 private constant INITIAL_SUPPLY = 5000000000;

    /**
     * @dev Constructor that gives msg.sender all of existing tokens.
     * @param _name The name of the token
     * @param _symbol The symbol of the token
     */
    constructor(
        string memory _name, 
        string memory _symbol
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY * 10 ** DECIMALS);
    }

    /**
     * @dev Burns a specific amount of tokens.
     * @param _value The amount of token to be burned.
     */
    function burn(uint256 _value) public {
        require(_value > 0, "Amount must be greater than 0");
        _burn(msg.sender, _value);        
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     */
    function decimals() public pure override returns (uint8) {
        return uint8(DECIMALS);
    }
}