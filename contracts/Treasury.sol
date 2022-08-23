//SPDX-License-Identifier: MIT
pragma solidity >= 0.8.12;

import "./interfaces/ISeed.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ITreasury.sol";

contract Treasury is ITreasury {
    //A valid deployer of the contract
    address public owner;

    //A valid caller of the contract;
    address public caller;

    // The Treasury contract enables the token casting capability, which is disabled by default;
    bool public callable;

    address public seedToken;

    //Due to the use of integer shift halving, the precision of the last bit may be lost in the future,
    //so one cycle is approximately 23.1 million tokens to be minted;
    uint256 MAX_MINTABLE_AMOUNT_IN_CYCLE = 23100000_000000000000000000;

    //The initial amount distributed to users will be halved every cycle;
    uint256 GENESIS_MINTABLE_AMOUNT_FOR_USER = 2100_000000000000000000;

    //The amount of tokens issued to the treasury contract along with the user's issuing behavior;
    //bytes: 10110110001001010101110111110101111101010000000010000000000000000000
    uint256 GENESIS_MINTABLE_AMOUNT_FOR_TREASURE = 210_000000000000000000;

    //Used to mark which minting cycle is currently in
    uint16  public cycle= 0;

    constructor(address _seed) {
        seedToken = _seed;
        owner = msg.sender;
        callable = false;
    }

    modifier onlyOwner {
        require(msg.sender==owner, "Treasury: only owner can do");
        _;
    }

    function setCaller(address _caller) onlyOwner public {
        caller = _caller;
        callable = true;
    }

    modifier mintable {
        require(callable == true, "Treasury: caller is invalid");
        require(msg.sender==caller, "Treasury: only caller can do");
        _;
    }

    function mint(address receiver) public mintable override returns(bool){
        //calculate which cycle is currently in BY totalSupply;
        uint256 totalSupply = IERC20(seedToken).totalSupply();

        // If the current cycle is different from the calculated one,
       // it means that the next token cycle is entered, and the value of cycle is updated at this time
        if(totalSupply/MAX_MINTABLE_AMOUNT_IN_CYCLE>cycle){
            cycle = cycle+1;
        }

        require(GENESIS_MINTABLE_AMOUNT_FOR_TREASURE>>cycle > 0, "Treasury: mint stop");

        ISeed(seedToken).mint(address(this), GENESIS_MINTABLE_AMOUNT_FOR_TREASURE>>cycle);

        ISeed(seedToken).mint(receiver, GENESIS_MINTABLE_AMOUNT_FOR_USER>>cycle);
        return true;
    }

     receive() external payable {}

    function withdraw(address receiver, address tokenAddress, uint256 amount) external onlyOwner returns(bool){
        require(receiver!=address(0) && tokenAddress!=address(0), "Treasury: ZERO ADDRESS");
        IERC20(tokenAddress).transfer(receiver, amount);
        return true;
    }

    function withdrawETH(address payable receiver, uint256 amount) external onlyOwner returns(bool){
        receiver.transfer(amount);
        return true;
    }

    function transferOwnership(address newOwner) onlyOwner external {
        require(newOwner!=address(0), "Treasury: ZERO ADDRESS");
        owner = newOwner;
    }
}
