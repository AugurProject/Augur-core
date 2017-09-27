pragma solidity ^0.4.13;

import 'reporting/IReputationToken.sol';
import 'libraries/DelegationTarget.sol';
import 'libraries/Typed.sol';
import 'libraries/Initializable.sol';
import 'libraries/token/StandardToken.sol';
import 'libraries/token/ERC20.sol';
import 'reporting/IBranch.sol';
import 'reporting/IMarket.sol';
import 'libraries/math/SafeMathUint256.sol';


contract ReputationToken is DelegationTarget, Typed, Initializable, StandardToken, IReputationToken {
    using SafeMathUint256 for uint256;

    //FIXME: Delegated contracts cannot currently use string values, so we will need to find a workaround if this hasn't been fixed before we release
    string constant public name = "Reputation";
    string constant public symbol = "REP";
    uint256 constant public decimals = 18;
    IBranch private branch;
    IReputationToken private topMigrationDestination;

    function initialize(IBranch _branch) public beforeInitialized returns (bool) {
        endInitialization();
        require(_branch != address(0));
        branch = _branch;
        return true;
    }

    // AUDIT: check for reentrancy issues here, _destination will be called as contracts during validation
    function migrateOut(IReputationToken _destination, address _reporter, uint256 _attotokens) public afterInitialized returns (bool) {
        assertReputationTokenIsLegit(_destination);
        if (msg.sender != _reporter) {
            allowed[_reporter][msg.sender] = allowed[_reporter][msg.sender].sub(_attotokens);
        }
        balances[_reporter] = balances[_reporter].sub(_attotokens);
        supply = supply.sub(_attotokens);
        _destination.migrateIn(_reporter, _attotokens);
        if (topMigrationDestination == address(0) || _destination.totalSupply() > topMigrationDestination.totalSupply()) {
            topMigrationDestination = _destination;
        }
        return true;
    }

    function migrateIn(address _reporter, uint256 _attotokens) public afterInitialized returns (bool) {
        require(ReputationToken(msg.sender) == branch.getParentBranch().getReputationToken());
        balances[_reporter] = balances[_reporter].add(_attotokens);
        supply = supply.add(_attotokens);
        return true;
    }

    function migrateFromLegacyRepContract() public afterInitialized returns (bool) {
        var _legacyRepToken = ERC20(controller.lookup("LegacyRepContract"));
        var _legacyBalance = _legacyRepToken.balanceOf(msg.sender);
        _legacyRepToken.transferFrom(msg.sender, address(0), _legacyBalance);
        balances[msg.sender] = balances[msg.sender].add(_legacyBalance);
        supply = supply.add(_legacyBalance);
        return true;
    }

    // AUDIT: check for reentrancy issues here, _source and _destination will be called as contracts during validation
    function trustedTransfer(address _source, address _destination, uint256 _attotokens) public afterInitialized returns (bool) {
        Typed _caller = Typed(msg.sender);
        require(branch.isContainerForReportingWindow(_caller) || branch.isContainerForRegistrationToken(_caller) || branch.isContainerForMarket(_caller) || branch.isContainerForReportingToken(_caller));
        balances[_source] = balances[_source].sub(_attotokens);
        balances[_destination] = balances[_destination].add(_attotokens);
        supply = supply.add(_attotokens);
        Transfer(_source, _destination, _attotokens);
        return true;
    }

    function assertReputationTokenIsLegit(IReputationToken _shadyReputationToken) private returns (bool) {
        var _shadyBranch = _shadyReputationToken.getBranch();
        require(branch.isParentOf(_shadyBranch));
        var _legitBranch = _shadyBranch;
        require(_legitBranch.getReputationToken() == _shadyReputationToken);
        return true;
    }

    function getTypeName() constant returns (bytes32) {
        return "ReputationToken";
    }

    function getBranch() constant returns (IBranch) {
        return branch;
    }

    function getTopMigrationDestination() constant returns (IReputationToken) {
        return topMigrationDestination;
    }
}
