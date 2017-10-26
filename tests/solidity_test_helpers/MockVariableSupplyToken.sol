pragma solidity ^0.4.17;

import 'libraries/token/StandardToken.sol';


contract MockVariableSupplyToken is StandardToken {
    uint256 private setBalanceOfValue;
    address private transferToValue;
    uint256 private transferValueValue;
    uint256[] private transferAmounts;
    address[] private transferAddresses;
    uint256[] private balanceOfAmounts;
    address[] private balanceOfAddresses;

    event Mint(address indexed target, uint256 value);
    event Burn(address indexed target, uint256 value);

    function setBalanceOf(uint256 _balance) public {
        setBalanceOfValue = _balance;
    }
    
    function getTransferToValue() public returns(address) {
        return transferToValue;
    }
    
    function getTransferValueValue() public returns(uint256) {
        return transferValueValue;
    }
    
    function resetBalanceOfValues() public {
        setBalanceOfValue = 0;
        balanceOfAmounts = [0];
        balanceOfAddresses = [0];
    }

    function resetTransferToValues() public {
        transferToValue = address(0);
        transferValueValue = 0;
        transferAmounts = [0];
        transferAddresses = [0];
    }
    
    function getTransferValueFor(address _to) public returns(uint256) {
       for (uint8 j = 0; j < transferAddresses.length; j++) {
            if (transferAddresses[j] == _to) {
                return transferAmounts[j];
            }
        }
        return 0;
    }
    
    function setBalanceOfValueFor(address _to, uint256 _value) public returns(uint256) {
        balanceOfAmounts.push(_value);
        balanceOfAddresses.push(_to);
    }

    function mint(address _target, uint256 _amount) internal returns (bool) {
        return true;
    }

    function burn(address _target, uint256 _amount) internal returns (bool) {
        return true;
    }

    function balanceOf(address _owner) public view returns (uint256) {
       for (uint8 j = 0; j < balanceOfAddresses.length; j++) {
            if (balanceOfAddresses[j] == _owner) {
                return balanceOfAmounts[j];
            }
        }
        return setBalanceOfValue;
    }
    
    function transfer(address _to, uint256 _value) public returns (bool) {
        transferToValue = _to;
        transferValueValue = _value;
        transferAmounts.push(_value);
        transferAddresses.push(_to);
        return true;
    }
}