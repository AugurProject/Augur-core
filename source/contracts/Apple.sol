pragma solidity ^0.4.13;

import 'ROOT/Controlled.sol';


contract Apple is Controlled {
    function getTypeName() public constant returns (bytes32) {
        return "Apple";
    }
}
