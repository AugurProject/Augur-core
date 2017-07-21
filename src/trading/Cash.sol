pragma solidity ^0.4.13;

import 'ROOT/libraries/token/StandardToken.sol';
import 'ROOT/Controller.sol';

/**
 * @title SimpleToken
 * @dev Very simple ERC20 Token example, where all tokens are pre-assigned to the creator.
 * Note they can later distribute these tokens as they wish using `transfer` and other
 * `StandardToken` functions.
 */
contract Cash is StandardToken, Controlled
{
	using SafeMath for uint256;

	event DepositEther(address indexed sender, uint256 value, uint256 balance);
	event InitiateWithdrawEther(address indexed sender, uint256 value, uint256 balance);
	event WithdrawEther(address indexed sender, uint256 value, uint256 balance);
	enum WithdrawState { Failed, Withdrawn, Initiated }

	string public name = "Cash";
	string public symbol = "CASH";
	uint256 public decimals = 18;
	mapping(address => uint256) public initiated;

	function publicDepositEther() external payable returns(bool)
	{
		// TODO: add mutex
		// TODO: add emergency stop
		balances[msg.sender] = balances[msg.sender].add(msg.value);
		totalSupply = totalSupply.add(msg.value);
		DepositEther(msg.sender, msg.value, balances[msg.sender]);
		return true;
	}

	function publicWithdrawEther(address _to, uint256 _amount) external returns(WithdrawState)
	{
		require(1 <= _amount && _amount <= balances[msg.sender]);
		var _initiatedTimestamp = initiated[msg.sender];
		if(_initiatedTimestamp == 0)
		{
			initiated[msg.sender] = block.timestamp;
			InitiateWithdrawEther(msg.sender, _amount, balances[msg.sender]);
			return WithdrawState.Initiated;
		}
		else
		{
			// FIXME: attacker can initiate a withdraw of 1 unit, wait 3 days, then launch an attack and then immeadiately withdraw everything
			require(_initiatedTimestamp + 3 days <= block.timestamp);
			balances[msg.sender] = balances[msg.sender].sub(_amount);
			totalSupply = totalSupply.sub(_amount);
			initiated[msg.sender] = 0;
			msg.sender.transfer(_amount);
			WithdrawEther(msg.sender, _amount, balances[msg.sender]);
			return WithdrawState.Withdrawn;
		}
	}

	// FIXME: this is necessary until we figure out a better way to check to see if a market's denomination token is a shareToken or not.  right now this is the only other valid denomination token so this hack works, but it won't when we support arbitrary denomination tokens.
	function getMarket() external returns(bool)
	{
		return false;
	}
}
