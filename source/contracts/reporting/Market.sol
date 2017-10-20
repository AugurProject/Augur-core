pragma solidity 0.4.17;


import 'reporting/IMarket.sol';
import 'libraries/DelegationTarget.sol';
import 'libraries/ITyped.sol';
import 'libraries/Initializable.sol';
import 'libraries/Ownable.sol';
import 'libraries/collections/Map.sol';
import 'reporting/IUniverse.sol';
import 'reporting/IStakeToken.sol';
import 'reporting/IReputationToken.sol';
import 'reporting/IDisputeBond.sol';
import 'trading/ICash.sol';
import 'trading/IShareToken.sol';
import 'extensions/MarketExtensions.sol';
import 'factories/ShareTokenFactory.sol';
import 'factories/StakeTokenFactory.sol';
import 'factories/DisputeBondTokenFactory.sol';
import 'factories/MapFactory.sol';
import 'libraries/token/ERC20Basic.sol';
import 'libraries/math/SafeMathUint256.sol';
import 'libraries/math/SafeMathInt256.sol';
import 'reporting/Reporting.sol';


contract Market is DelegationTarget, ITyped, Initializable, Ownable, IMarket {
    using SafeMathUint256 for uint256;
    using SafeMathInt256 for int256;

    uint256 private numTicks;
    uint256 private feeDivisor;

    uint256 private constant MAX_FEE_PER_ETH_IN_ATTOETH = 1 ether / 2;
    uint256 private constant APPROVAL_AMOUNT = 2**256-1;
    address private constant NULL_ADDRESS = address(0);

    IReportingWindow private reportingWindow;
    uint256 private endTime;
    uint8 private numOutcomes;
    uint256 private marketCreationBlock;
    address private designatedReporterAddress;
    Map private stakeTokens;
    ICash private cash;
    IShareToken[] private shareTokens;
    uint256 private finalizationTime;
    uint256 private designatedReportReceivedTime;
    bytes32 private designatedReportPayoutHash;
    bytes32 private tentativeWinningPayoutDistributionHash;
    // We keep track of the second place winning payout hash since when a dispute bond is placed it counts negatively toward stake and we can't otherwise figure out which outcome to promote. Since we only store two hashes it may be the case that if promotion occurs this value is not actually second place, but there is only one case where promotion occurs in a market's lifetime, so it will no longer be relevant at that point.
    bytes32 private bestGuessSecondPlaceTentativeWinningPayoutDistributionHash;
    bytes32 private finalPayoutDistributionHash;
    IDisputeBond private designatedReporterDisputeBondToken;
    IDisputeBond private round1ReportersDisputeBondToken;
    IDisputeBond private round2ReportersDisputeBondToken;
    uint256 private validityBondAttoeth;
    uint256 private reporterGasCostsFeeAttoeth;
    uint256 private totalStake;

    /**
     * @dev Makes the function trigger a migration before execution
     */
    modifier triggersMigration() {
        migrateThroughAllForks();
        _;
    }

    function initialize(IReportingWindow _reportingWindow, uint256 _endTime, uint8 _numOutcomes, uint256 _numTicks, uint256 _feePerEthInAttoeth, ICash _cash, address _creator, address _designatedReporterAddress) public payable beforeInitialized returns (bool _success) {
        endInitialization();
        require(2 <= _numOutcomes && _numOutcomes <= 8);
        require((_numTicks.isMultipleOf(_numOutcomes)));
        require(_feePerEthInAttoeth <= MAX_FEE_PER_ETH_IN_ATTOETH);
        require(_creator != NULL_ADDRESS);
        require(_cash.getTypeName() == "Cash");
        require(_designatedReporterAddress != NULL_ADDRESS);
        reportingWindow = _reportingWindow;
        require(address(getForkingMarket()) == NULL_ADDRESS);
        owner = _creator;
        assessFees();
        endTime = _endTime;
        numOutcomes = _numOutcomes;
        numTicks = _numTicks;
        feeDivisor = 1 ether / _feePerEthInAttoeth;
        marketCreationBlock = block.number;
        designatedReporterAddress = _designatedReporterAddress;
        cash = _cash;
        stakeTokens = MapFactory(controller.lookup("MapFactory")).createMap(controller, this);
        for (uint8 _outcome = 0; _outcome < numOutcomes; _outcome++) {
            shareTokens.push(createShareToken(_outcome));
        }
        approveSpenders();
        // If the value was not at least equal to the sum of these fees this will throw
        uint256 _refund = msg.value.sub(reporterGasCostsFeeAttoeth.add(validityBondAttoeth));
        if (_refund > 0) {
            require(owner.call.value(_refund)());
        }
        return true;
    }

    function assessFees() private returns (bool) {
        IUniverse _universe = getUniverse();
        require(reportingWindow.getReputationToken().balanceOf(this) == _universe.getDesignatedReportNoShowBond());
        reporterGasCostsFeeAttoeth = _universe.getTargetReporterGasCosts();
        validityBondAttoeth = _universe.getValidityBond();
        return true;
    }

    function createShareToken(uint8 _outcome) private returns (IShareToken) {
        return ShareTokenFactory(controller.lookup("ShareTokenFactory")).createShareToken(controller, this, _outcome);
    }

    // This will need to be called manually for each open market if a spender contract is updated
    function approveSpenders() private returns (bool) {
        bytes32[5] memory _names = [bytes32("CancelOrder"), bytes32("CompleteSets"), bytes32("FillOrder"), bytes32("TradingEscapeHatch"), bytes32("ClaimProceeds")];
        for (uint8 i = 0; i < _names.length; i++) {
            cash.approve(controller.lookup(_names[i]), APPROVAL_AMOUNT);
        }
        for (uint8 j = 0; j < numOutcomes; j++) {
            shareTokens[j].approve(controller.lookup("FillOrder"), APPROVAL_AMOUNT);
        }
        return true;
    }

    function decreaseMarketCreatorSettlementFeeInAttoethPerEth(uint256 _newFeePerEthInWei) public onlyOwner returns (bool) {
        uint256 _newFeeDivisor = 1 ether / _newFeePerEthInWei;
        require(_newFeeDivisor > feeDivisor);
        feeDivisor = _newFeeDivisor;
        return true;
    }

    function designatedReport() public triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.DESIGNATED_REPORTING);
        IStakeToken _shadyStakeToken = IStakeToken(msg.sender);
        require(isContainerForStakeToken(_shadyStakeToken));
        IStakeToken _stakeToken = _shadyStakeToken;
        designatedReportReceivedTime = block.timestamp;
        tentativeWinningPayoutDistributionHash = _stakeToken.getPayoutDistributionHash();
        designatedReportPayoutHash = tentativeWinningPayoutDistributionHash;
        reportingWindow.updateMarketPhase();
        IReputationToken _reputationToken = reportingWindow.getReputationToken();
        // The owner gets the no-show REP bond
        _reputationToken.transfer(owner, _reputationToken.balanceOf(this));
        // The owner gets the reporter gas costs
        require(getOwner().call.value(reporterGasCostsFeeAttoeth)());
        return true;
    }

    function disputeDesignatedReport(uint256[] _payoutNumerators, uint256 _attotokens, bool _invalid) public triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.DESIGNATED_DISPUTE);
        uint256 _bondAmount = Reporting.designatedReporterDisputeBondAmount();
        designatedReporterDisputeBondToken = DisputeBondTokenFactory(controller.lookup("DisputeBondTokenFactory")).createDisputeBondToken(controller, this, msg.sender, _bondAmount, tentativeWinningPayoutDistributionHash);
        getUniverse().increaseExtraDisputeBondRemainingToBePaidOut(_bondAmount);
        this.increaseTotalStake(_bondAmount);
        reportingWindow.getReputationToken().trustedTransfer(msg.sender, designatedReporterDisputeBondToken, _bondAmount);
        if (_attotokens > 0) {
            IStakeToken _stakeToken = getStakeToken(_payoutNumerators, _invalid);
            _stakeToken.trustedBuy(msg.sender, _attotokens);
        } else {
            updateTentativeWinningPayoutDistributionHash(tentativeWinningPayoutDistributionHash);
        }
        reportingWindow.updateMarketPhase();
        return true;
    }

    function disputeRound1Reporters(uint256[] _payoutNumerators, uint256 _attotokens, bool _invalid) public triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.FIRST_DISPUTE);
        uint256 _bondAmount = Reporting.round1ReportersDisputeBondAmount();
        round1ReportersDisputeBondToken = DisputeBondTokenFactory(controller.lookup("DisputeBondTokenFactory")).createDisputeBondToken(controller, this, msg.sender, _bondAmount, tentativeWinningPayoutDistributionHash);
        getUniverse().increaseExtraDisputeBondRemainingToBePaidOut(_bondAmount);
        this.increaseTotalStake(_bondAmount);
        reportingWindow.getReputationToken().trustedTransfer(msg.sender, round1ReportersDisputeBondToken, _bondAmount);
        IReportingWindow _newReportingWindow = getUniverse().getNextReportingWindow();
        migrateReportingWindow(_newReportingWindow);
        if (_attotokens > 0) {
            require(derivePayoutDistributionHash(_payoutNumerators, _invalid) != tentativeWinningPayoutDistributionHash);
            IStakeToken _stakeToken = getStakeToken(_payoutNumerators, _invalid);
            _stakeToken.trustedBuy(msg.sender, _attotokens);
        } else {
            updateTentativeWinningPayoutDistributionHash(tentativeWinningPayoutDistributionHash);
        }
        return true;
    }

    function disputeRound2Reporters() public triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.LAST_DISPUTE);
        uint256 _bondAmount = Reporting.round2ReportersDisputeBondAmount();
        round2ReportersDisputeBondToken = DisputeBondTokenFactory(controller.lookup("DisputeBondTokenFactory")).createDisputeBondToken(controller, this, msg.sender, _bondAmount, tentativeWinningPayoutDistributionHash);
        getUniverse().increaseExtraDisputeBondRemainingToBePaidOut(_bondAmount);
        this.increaseTotalStake(_bondAmount);
        reportingWindow.getReputationToken().trustedTransfer(msg.sender, round2ReportersDisputeBondToken, _bondAmount);
        reportingWindow.getUniverse().fork();
        IReportingWindow _newReportingWindow = getUniverse().getReportingWindowForForkEndTime();
        return migrateReportingWindow(_newReportingWindow);
    }

    function updateTentativeWinningPayoutDistributionHash(bytes32 _payoutDistributionHash) public returns (bool) {
        var (_firstPlaceHash, _secondPlaceHash) = MarketExtensions(controller.lookup("MarketExtensions")).getOrderedWinningPayoutDistributionHashes(this, _payoutDistributionHash);

        require(_firstPlaceHash != bytes32(0));
        require(_firstPlaceHash != _secondPlaceHash);
        tentativeWinningPayoutDistributionHash = _firstPlaceHash;
        bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = _secondPlaceHash;

        return true;
    }

    function tryFinalize() public returns (bool) {
        if (getReportingState() != ReportingState.AWAITING_FINALIZATION) {
            return false;
        }

        if (getForkingMarket() == this) {
            tentativeWinningPayoutDistributionHash = getWinningPayoutDistributionHashFromFork();
        }

        finalPayoutDistributionHash = tentativeWinningPayoutDistributionHash;
        finalizationTime = block.timestamp;
        transferIncorrectDisputeBondsToWinningStakeToken();
        // The validity bond is paid to the owner in any valid outcome and the reporting window otherwise
        doFeePayout(isValid(), validityBondAttoeth);
        reportingWindow.updateMarketPhase();
        return true;
    }

    function migrateReportingWindow(IReportingWindow _newReportingWindow) private afterInitialized returns (bool) {
        _newReportingWindow.migrateMarketInFromSibling();
        reportingWindow.removeMarket();
        reportingWindow = _newReportingWindow;
        reportingWindow.updateMarketPhase();
        return true;
    }

    function migrateDueToNoReports() public returns (bool) {
        require(getReportingState() == ReportingState.AWAITING_NO_REPORT_MIGRATION);
        IReportingWindow _newReportingWindow = getUniverse().getNextReportingWindow();
        migrateReportingWindow(_newReportingWindow);
        return false;
    }

    function migrateThroughAllForks() public returns (bool) {
        // this will loop until we run out of gas, follow forks until there are no more, or have reached an active fork (which will throw)
        while (migrateThroughOneFork()) {
            continue;
        }
        return true;
    }

    // returns 0 if no move occurs, 1 if move occurred, throws if a fork not yet resolved
    function migrateThroughOneFork() public returns (bool) {
        if (getReportingState() != ReportingState.AWAITING_FORK_MIGRATION) {
            return false;
        }
        // only proceed if the forking market is finalized
        require(reportingWindow.isForkingMarketFinalized());
        IUniverse _currentUniverse = getUniverse();
        // follow the forking market to its universe and then attach to the next reporting window on that universe
        bytes32 _winningForkPayoutDistributionHash = _currentUniverse.getForkingMarket().getFinalPayoutDistributionHash();
        IUniverse _destinationUniverse = _currentUniverse.getOrCreateChildUniverse(_winningForkPayoutDistributionHash);
        // This will put us in the designated dispute phase
        endTime = block.timestamp - Reporting.designatedReportingDurationSeconds();
        totalStake = 0;
        IReportingWindow _newReportingWindow = _destinationUniverse.getReportingWindowByMarketEndTime(endTime);
        _newReportingWindow.migrateMarketInFromNibling();
        reportingWindow.removeMarket();
        reportingWindow = _newReportingWindow;
        reportingWindow.updateMarketPhase();
        round1ReportersDisputeBondToken = IDisputeBond(0);
        round2ReportersDisputeBondToken = IDisputeBond(0);
        tentativeWinningPayoutDistributionHash = designatedReportPayoutHash;
        if (designatedReportReceivedTime != 0) {
            designatedReportReceivedTime = block.timestamp - 1;
        }
        stakeTokens = MapFactory(controller.lookup("MapFactory")).createMap(controller, this);
        return true;
    }

    //
    // Helpers
    //

    function disavowTokens() public returns (bool) {
        require(getReportingState() == ReportingState.AWAITING_FORK_MIGRATION);
        require(stakeTokens.getCount() > 0);
        stakeTokens = MapFactory(controller.lookup("MapFactory")).createMap(controller, this);
        return true;
    }

    function getStakeToken(uint256[] _payoutNumerators, bool _invalid) public returns (IStakeToken) {
        bytes32 _payoutDistributionHash = derivePayoutDistributionHash(_payoutNumerators, _invalid);
        IStakeToken _stakeToken = IStakeToken(stakeTokens.getAsAddressOrZero(_payoutDistributionHash));
        if (address(_stakeToken) == NULL_ADDRESS) {
            _stakeToken = StakeTokenFactory(controller.lookup("StakeTokenFactory")).createStakeToken(controller, this, _payoutNumerators, _invalid);
            stakeTokens.add(_payoutDistributionHash, _stakeToken);
        }
        return _stakeToken;
    }

    function transferIncorrectDisputeBondsToWinningStakeToken() private returns (bool) {
        require(getReportingState() == ReportingState.FINALIZED);
        IReputationToken _reputationToken = reportingWindow.getReputationToken();
        if (getForkingMarket() == this) {
            return true;
        }
        if (address(designatedReporterDisputeBondToken) != NULL_ADDRESS && designatedReporterDisputeBondToken.getDisputedPayoutDistributionHash() == finalPayoutDistributionHash) {
            _reputationToken.trustedTransfer(designatedReporterDisputeBondToken, getFinalWinningStakeToken(), _reputationToken.balanceOf(designatedReporterDisputeBondToken));
        }
        if (address(round1ReportersDisputeBondToken) != NULL_ADDRESS && round1ReportersDisputeBondToken.getDisputedPayoutDistributionHash() == finalPayoutDistributionHash) {
            _reputationToken.trustedTransfer(round1ReportersDisputeBondToken, getFinalWinningStakeToken(), _reputationToken.balanceOf(round1ReportersDisputeBondToken));
        }
        return true;
    }

    function doFeePayout(bool _toOwner, uint256 _amount) private returns (bool) {
        if (_toOwner) {
            require(getOwner().call.value(_amount)());
        } else {
            cash.depositEtherFor.value(_amount)(getReportingWindow());
        }
        return true;
    }

    // AUDIT: This is called at the beginning of StakeToken:buy. Look for reentrancy issues
    function round1ReporterCompensationCheck(address _reporter) public returns (uint256) {
        require(isContainerForStakeToken(ITyped(msg.sender)));
        if (getReportingState() == ReportingState.DESIGNATED_REPORTING) {
            return 0;
        } else if (tentativeWinningPayoutDistributionHash == bytes32(0)) {
            IReputationToken _reputationToken = reportingWindow.getReputationToken();
            uint256 _repBalance = _reputationToken.balanceOf(this);
            // The first reporter gets the no-show REP bond
            _reputationToken.transfer(_reporter, _repBalance);
            // The first reporter gets the reporter gas costs
            require(_reporter.call.value(reporterGasCostsFeeAttoeth)());
            return _repBalance;
        } else {
            return 0;
        }
    }

    function increaseTotalStake(uint256 _amount) public returns (bool) {
        require(msg.sender == address(this) || isContainerForStakeToken(ITyped(msg.sender)));
        totalStake = totalStake.add(_amount);
        reportingWindow.increaseTotalStake(_amount);
        return true;
    }

    function derivePayoutDistributionHash(uint256[] _payoutNumerators, bool _invalid) public view returns (bytes32) {
        uint256 _sum = 0;
        for (uint8 i = 0; i < _payoutNumerators.length; i++) {
            _sum = _sum.add(_payoutNumerators[i]);
        }
        require(_sum == numTicks);
        return keccak256(_payoutNumerators, _invalid);
    }

    function getStakeTokenOrZeroByPayoutDistributionHash(bytes32 _payoutDistributionHash) public view returns (IStakeToken) {
        return IStakeToken(stakeTokens.getAsAddressOrZero(_payoutDistributionHash));
    }

    //
    //Getters
    //

    function getTypeName() public view returns (bytes32) {
        return "Market";
    }

    function getReportingWindow() public view returns (IReportingWindow) {
        return reportingWindow;
    }

    function getUniverse() public view returns (IUniverse) {
        return reportingWindow.getUniverse();
    }

    function getDesignatedReporter() public view returns (address) {
        return designatedReporterAddress;
    }

    function getDesignatedReporterDisputeBondToken() public view returns (IDisputeBond) {
        return designatedReporterDisputeBondToken;
    }

    function getRound1ReportersDisputeBondToken() public view returns (IDisputeBond) {
        return round1ReportersDisputeBondToken;
    }

    function getRound2ReportersDisputeBondToken() public view returns (IDisputeBond) {
        return round2ReportersDisputeBondToken;
    }

    function getNumberOfOutcomes() public view returns (uint8) {
        return numOutcomes;
    }

    function getEndTime() public view returns (uint256) {
        return endTime;
    }

    function getTentativeWinningPayoutDistributionHash() public view returns (bytes32) {
        return tentativeWinningPayoutDistributionHash;
    }

    function getBestGuessSecondPlaceTentativeWinningPayoutDistributionHash() public view returns (bytes32) {
        return bestGuessSecondPlaceTentativeWinningPayoutDistributionHash;
    }

    function getFinalWinningStakeToken() public view returns (IStakeToken) {
        return IStakeToken(stakeTokens.getAsAddressOrZero(finalPayoutDistributionHash));
    }

    function getShareToken(uint8 _outcome)  public view returns (IShareToken) {
        return shareTokens[_outcome];
    }

    function getFinalPayoutDistributionHash() public view returns (bytes32) {
        return finalPayoutDistributionHash;
    }

    function getDesignatedReportPayoutHash() public view returns (bytes32) {
        return designatedReportPayoutHash;
    }

    function getNumTicks() public view returns (uint256) {
        return numTicks;
    }

    function getDenominationToken() public view returns (ICash) {
        return cash;
    }

    function getMarketCreatorSettlementFeeDivisor() public view returns (uint256) {
        return feeDivisor;
    }

    function getFinalizationTime() public view returns (uint256) {
        return finalizationTime;
    }

    function getForkingMarket() public view returns (IMarket _market) {
        return getUniverse().getForkingMarket();
    }

    function getTotalStake() public view returns (uint256) {
        return totalStake;
    }

    function getTotalWinningDisputeBondStake() public view returns (uint256) {
        uint256 _totalDisputeBondStake = 0;

        if (address(designatedReporterDisputeBondToken) != address(0)) {
            if (designatedReporterDisputeBondToken.getDisputedPayoutDistributionHash() != finalPayoutDistributionHash) {
                _totalDisputeBondStake += Reporting.designatedReporterDisputeBondAmount();
            }
        }
        if (address(round1ReportersDisputeBondToken) != address(0)) {
            if (round1ReportersDisputeBondToken.getDisputedPayoutDistributionHash() != finalPayoutDistributionHash) {
                _totalDisputeBondStake += Reporting.round1ReportersDisputeBondAmount();
            }
        }
        if (address(round2ReportersDisputeBondToken) != address(0)) {
            if (round2ReportersDisputeBondToken.getDisputedPayoutDistributionHash() != finalPayoutDistributionHash) {
                _totalDisputeBondStake += Reporting.round2ReportersDisputeBondAmount();
            }
        }

        return _totalDisputeBondStake;
    }

    function isContainerForStakeToken(ITyped _shadyTarget) public view returns (bool) {
        if (_shadyTarget.getTypeName() != "StakeToken") {
            return false;
        }
        IStakeToken _shadyStakeToken = IStakeToken(_shadyTarget);
        bytes32 _shadyId = _shadyStakeToken.getPayoutDistributionHash();
        IStakeToken _stakeToken = IStakeToken(stakeTokens.getAsAddressOrZero(_shadyId));
        return _stakeToken == _shadyStakeToken;
    }

    function isContainerForShareToken(ITyped _shadyTarget) public view returns (bool) {
        if (_shadyTarget.getTypeName() != "ShareToken") {
            return false;
        }
        IShareToken _shadyShareToken = IShareToken(_shadyTarget);
        return getShareToken(_shadyShareToken.getOutcome()) == _shadyShareToken;
    }

    function isContainerForDisputeBondToken(ITyped _shadyTarget) public view returns (bool) {
        if (_shadyTarget.getTypeName() != "DisputeBondToken") {
            return false;
        }
        IDisputeBond _shadyDisputeBond = IDisputeBond(_shadyTarget);
        if (designatedReporterDisputeBondToken == _shadyDisputeBond) {
            return true;
        }
        if (round1ReportersDisputeBondToken == _shadyDisputeBond) {
            return true;
        }
        if (round2ReportersDisputeBondToken == _shadyDisputeBond) {
            return true;
        }
        return false;
    }

    // CONSIDER: Would it be helpful to add modifiers for this contract like "onlyAfterFinalized" that could protect a function such as this?
    function isValid() public view returns (bool) {
        IStakeToken _winningStakeToken = getFinalWinningStakeToken();
        return _winningStakeToken.isValid();
    }

    function getDesignatedReportDueTimestamp() public view returns (uint256) {
        if (designatedReportReceivedTime != 0) {
            return designatedReportReceivedTime;
        }
        return endTime + Reporting.designatedReportingDurationSeconds();
    }

    function getDesignatedReportReceivedTime() public view returns (uint256) {
        return designatedReportReceivedTime;
    }

    function getDesignatedReportDisputeDueTimestamp() public view returns (uint256) {
        return getDesignatedReportDueTimestamp() + Reporting.designatedReportingDisputeDurationSeconds();
    }

    function getReportingState() public view returns (ReportingState) {
        return MarketExtensions(controller.lookup("MarketExtensions")).getMarketReportingState(this);
    }

    function getWinningPayoutDistributionHashFromFork() private view returns (bytes32) {
        return MarketExtensions(controller.lookup("MarketExtensions")).getWinningPayoutDistributionHashFromFork(this);
    }
}
