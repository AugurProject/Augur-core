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
import 'factories/ShareTokenFactory.sol';
import 'factories/StakeTokenFactory.sol';
import 'factories/DisputeBondTokenFactory.sol';
import 'factories/MapFactory.sol';
import 'libraries/token/ERC20Basic.sol';
import 'libraries/math/SafeMathUint256.sol';
import 'libraries/math/SafeMathInt256.sol';
import 'reporting/Reporting.sol';
import 'Augur.sol';


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
    IDisputeBond private firstReportersDisputeBondToken;
    IDisputeBond private lastReportersDisputeBondToken;
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

    function initialize(IReportingWindow _reportingWindow, uint256 _endTime, uint8 _numOutcomes, uint256 _numTicks, uint256 _feePerEthInAttoeth, ICash _cash, address _creator, address _designatedReporterAddress) public onlyInGoodTimes payable beforeInitialized returns (bool _success) {
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

    function assessFees() private onlyInGoodTimes returns (bool) {
        IUniverse _universe = getUniverse();
        require(reportingWindow.getReputationToken().balanceOf(this) == _universe.getDesignatedReportNoShowBond());
        reporterGasCostsFeeAttoeth = _universe.getTargetReporterGasCosts();
        validityBondAttoeth = _universe.getValidityBond();
        return true;
    }

    function createShareToken(uint8 _outcome) private onlyInGoodTimes returns (IShareToken) {
        return ShareTokenFactory(controller.lookup("ShareTokenFactory")).createShareToken(controller, this, _outcome);
    }

    // This will need to be called manually for each open market if a spender contract is updated
    function approveSpenders() private onlyInGoodTimes returns (bool) {
        bytes32[5] memory _names = [bytes32("CancelOrder"), bytes32("CompleteSets"), bytes32("FillOrder"), bytes32("TradingEscapeHatch"), bytes32("ClaimProceeds")];
        for (uint8 i = 0; i < _names.length; i++) {
            cash.approve(controller.lookup(_names[i]), APPROVAL_AMOUNT);
        }
        for (uint8 j = 0; j < numOutcomes; j++) {
            shareTokens[j].approve(controller.lookup("FillOrder"), APPROVAL_AMOUNT);
        }
        return true;
    }

    function decreaseMarketCreatorSettlementFeeInAttoethPerEth(uint256 _newFeePerEthInWei) public onlyInGoodTimes onlyOwner returns (bool) {
        uint256 _newFeeDivisor = 1 ether / _newFeePerEthInWei;
        require(_newFeeDivisor > feeDivisor);
        feeDivisor = _newFeeDivisor;
        return true;
    }

    function designatedReport() public onlyInGoodTimes triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.DESIGNATED_REPORTING);
        IStakeToken _shadyStakeToken = IStakeToken(msg.sender);
        require(isContainerForStakeToken(_shadyStakeToken));
        IStakeToken _stakeToken = _shadyStakeToken;
        designatedReportReceivedTime = block.timestamp;
        tentativeWinningPayoutDistributionHash = _stakeToken.getPayoutDistributionHash();
        designatedReportPayoutHash = tentativeWinningPayoutDistributionHash;
        reportingWindow.updateMarketPhase();
        reportingWindow.noteDesignatedReport();
        IReputationToken _reputationToken = reportingWindow.getReputationToken();
        // The owner gets the no-show REP bond
        _reputationToken.transfer(owner, _reputationToken.balanceOf(this));
        // The owner gets the reporter gas costs
        require(getOwner().call.value(reporterGasCostsFeeAttoeth)());
        return true;
    }

    function disputeDesignatedReport(uint256[] _payoutNumerators, uint256 _attotokens, bool _invalid) public onlyInGoodTimes triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.DESIGNATED_DISPUTE);
        uint256 _bondAmount = Reporting.designatedReporterDisputeBondAmount();
        designatedReporterDisputeBondToken = DisputeBondTokenFactory(controller.lookup("DisputeBondTokenFactory")).createDisputeBondToken(controller, this, msg.sender, _bondAmount, tentativeWinningPayoutDistributionHash);
        getUniverse().increaseExtraDisputeBondRemainingToBePaidOut(_bondAmount);
        this.increaseTotalStake(_bondAmount);
        reportingWindow.getReputationToken().trustedMarketTransfer(msg.sender, designatedReporterDisputeBondToken, _bondAmount);
        if (_attotokens > 0) {
            IStakeToken _stakeToken = getStakeToken(_payoutNumerators, _invalid);
            _stakeToken.trustedBuy(msg.sender, _attotokens);
        } else {
            updateTentativeWinningPayoutDistributionHash(tentativeWinningPayoutDistributionHash);
        }
        reportingWindow.updateMarketPhase();
        controller.getAugur().logReportsDisputed(getUniverse(), msg.sender, this, ReportingState.DESIGNATED_DISPUTE, _bondAmount);
        return true;
    }

    function disputeFirstReporters(uint256[] _payoutNumerators, uint256 _attotokens, bool _invalid) public onlyInGoodTimes triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.FIRST_DISPUTE);
        uint256 _bondAmount = Reporting.firstReportersDisputeBondAmount();
        firstReportersDisputeBondToken = DisputeBondTokenFactory(controller.lookup("DisputeBondTokenFactory")).createDisputeBondToken(controller, this, msg.sender, _bondAmount, tentativeWinningPayoutDistributionHash);
        getUniverse().increaseExtraDisputeBondRemainingToBePaidOut(_bondAmount);
        this.increaseTotalStake(_bondAmount);
        reportingWindow.getReputationToken().trustedMarketTransfer(msg.sender, firstReportersDisputeBondToken, _bondAmount);
        IReportingWindow _newReportingWindow = getUniverse().getNextReportingWindow();
        migrateReportingWindow(_newReportingWindow);
        if (_attotokens > 0) {
            require(derivePayoutDistributionHash(_payoutNumerators, _invalid) != tentativeWinningPayoutDistributionHash);
            IStakeToken _stakeToken = getStakeToken(_payoutNumerators, _invalid);
            _stakeToken.trustedBuy(msg.sender, _attotokens);
        } else {
            updateTentativeWinningPayoutDistributionHash(tentativeWinningPayoutDistributionHash);
        }
        controller.getAugur().logReportsDisputed(getUniverse(), msg.sender, this, ReportingState.FIRST_DISPUTE, _bondAmount);
        return true;
    }

    function disputeLastReporters() public onlyInGoodTimes triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.LAST_DISPUTE);
        uint256 _bondAmount = Reporting.lastReportersDisputeBondAmount();
        lastReportersDisputeBondToken = DisputeBondTokenFactory(controller.lookup("DisputeBondTokenFactory")).createDisputeBondToken(controller, this, msg.sender, _bondAmount, tentativeWinningPayoutDistributionHash);
        getUniverse().increaseExtraDisputeBondRemainingToBePaidOut(_bondAmount);
        this.increaseTotalStake(_bondAmount);
        reportingWindow.getReputationToken().trustedMarketTransfer(msg.sender, lastReportersDisputeBondToken, _bondAmount);
        reportingWindow.getUniverse().fork();
        IReportingWindow _newReportingWindow = getUniverse().getReportingWindowForForkEndTime();
        controller.getAugur().logReportsDisputed(getUniverse(), msg.sender, this, ReportingState.LAST_DISPUTE, _bondAmount);
        return migrateReportingWindow(_newReportingWindow);
    }

    function updateTentativeWinningPayoutDistributionHash(bytes32 _payoutDistributionHash) public onlyInGoodTimes returns (bool) {
        if (_payoutDistributionHash == tentativeWinningPayoutDistributionHash || _payoutDistributionHash == bestGuessSecondPlaceTentativeWinningPayoutDistributionHash) {
            _payoutDistributionHash = bytes32(0);
        }
        int256 _tentativeWinningStake = getPayoutDistributionHashStake(tentativeWinningPayoutDistributionHash);
        int256 _secondPlaceStake = getPayoutDistributionHashStake(bestGuessSecondPlaceTentativeWinningPayoutDistributionHash);
        int256 _payoutStake = getPayoutDistributionHashStake(_payoutDistributionHash);

        if (_tentativeWinningStake >= _secondPlaceStake && _secondPlaceStake >= _payoutStake) {
            tentativeWinningPayoutDistributionHash = (_tentativeWinningStake > 0) ? tentativeWinningPayoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_secondPlaceStake > 0) ? bestGuessSecondPlaceTentativeWinningPayoutDistributionHash : bytes32(0);
        } else if (_tentativeWinningStake >= _payoutStake && _payoutStake >= _secondPlaceStake) {
            tentativeWinningPayoutDistributionHash = (_tentativeWinningStake > 0) ? tentativeWinningPayoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_payoutStake > 0) ? _payoutDistributionHash : bytes32(0);
        } else if (_secondPlaceStake >= _tentativeWinningStake && _tentativeWinningStake >= _payoutStake) {
            _payoutDistributionHash = tentativeWinningPayoutDistributionHash; // Reusing this as a temp value holder
            tentativeWinningPayoutDistributionHash = (_secondPlaceStake > 0) ? bestGuessSecondPlaceTentativeWinningPayoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_tentativeWinningStake > 0) ? _payoutDistributionHash: bytes32(0);
        } else if (_secondPlaceStake >= _payoutStake && _payoutStake >= _tentativeWinningStake) {
            tentativeWinningPayoutDistributionHash = (_secondPlaceStake > 0) ? bestGuessSecondPlaceTentativeWinningPayoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_payoutStake > 0) ? _payoutDistributionHash: bytes32(0);
        } else if (_payoutStake >= _tentativeWinningStake && _tentativeWinningStake >= _secondPlaceStake) {
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_tentativeWinningStake > 0) ? tentativeWinningPayoutDistributionHash: bytes32(0);
            tentativeWinningPayoutDistributionHash = (_payoutStake > 0) ? _payoutDistributionHash: bytes32(0);
        } else if (_payoutStake >= _secondPlaceStake && _secondPlaceStake >= _tentativeWinningStake) {
            tentativeWinningPayoutDistributionHash = (_payoutStake > 0) ? _payoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_secondPlaceStake > 0) ? bestGuessSecondPlaceTentativeWinningPayoutDistributionHash: bytes32(0);
        }

        require(tentativeWinningPayoutDistributionHash != bytes32(0));
        require(tentativeWinningPayoutDistributionHash != bestGuessSecondPlaceTentativeWinningPayoutDistributionHash);

        return true;
    }

    function getPayoutDistributionHashStake(bytes32 _payoutDistributionHash) public view returns (int256) {
        if (_payoutDistributionHash == bytes32(0)) {
            return 0;
        }

        IStakeToken _stakeToken = getStakeTokenOrZeroByPayoutDistributionHash(_payoutDistributionHash);
        if (address(_stakeToken) == address(0)) {
            return 0;
        }

        int256 _payoutStake = int256(_stakeToken.totalSupply());

        if (address(designatedReporterDisputeBondToken) != address(0)) {
            if (designatedReporterDisputeBondToken.getDisputedPayoutDistributionHash() == _payoutDistributionHash) {
                _payoutStake -= int256(Reporting.designatedReporterDisputeBondAmount());
            }
        }
        if (address(firstReportersDisputeBondToken) != address(0)) {
            if (firstReportersDisputeBondToken.getDisputedPayoutDistributionHash() == _payoutDistributionHash) {
                _payoutStake -= int256(Reporting.firstReportersDisputeBondAmount());
            }
        }
        if (address(lastReportersDisputeBondToken) != address(0)) {
            if (lastReportersDisputeBondToken.getDisputedPayoutDistributionHash() == _payoutDistributionHash) {
                _payoutStake -= int256(Reporting.lastReportersDisputeBondAmount());
            }
        }

        return _payoutStake;
    }

    function tryFinalize() public onlyInGoodTimes returns (bool) {
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
        controller.getAugur().logMarketFinalized(getUniverse(), this);
        return true;
    }

    function migrateReportingWindow(IReportingWindow _newReportingWindow) private onlyInGoodTimes afterInitialized returns (bool) {
        _newReportingWindow.migrateMarketInFromSibling();
        reportingWindow.removeMarket();
        reportingWindow = _newReportingWindow;
        reportingWindow.updateMarketPhase();
        return true;
    }

    function migrateDueToNoReports() public onlyInGoodTimes returns (bool) {
        require(getReportingState() == ReportingState.AWAITING_NO_REPORT_MIGRATION);
        IReportingWindow _newReportingWindow = getUniverse().getNextReportingWindow();
        migrateReportingWindow(_newReportingWindow);
        return false;
    }

    function migrateThroughAllForks() public onlyInGoodTimes returns (bool) {
        // this will loop until we run out of gas, follow forks until there are no more, or have reached an active fork (which will throw)
        while (migrateThroughOneFork()) {
            continue;
        }
        return true;
    }

    // returns 0 if no move occurs, 1 if move occurred, throws if a fork not yet resolved
    function migrateThroughOneFork() public onlyInGoodTimes returns (bool) {
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
        firstReportersDisputeBondToken = IDisputeBond(0);
        lastReportersDisputeBondToken = IDisputeBond(0);
        tentativeWinningPayoutDistributionHash = designatedReportPayoutHash;
        if (designatedReportReceivedTime != 0) {
            designatedReportReceivedTime = block.timestamp - 1;
        }
        stakeTokens = MapFactory(controller.lookup("MapFactory")).createMap(controller, this);
        return true;
    }

    function withdrawInEmergency() public onlyInBadTimes onlyOwner returns (bool) {
        IReputationToken _reputationToken = reportingWindow.getReputationToken();
        uint256 _repBalance = _reputationToken.balanceOf(this);
        _reputationToken.transfer(msg.sender, _repBalance);
        if (this.balance > 0) {
            require(msg.sender.call.value(this.balance)());
        }
        return true;
    }

    //
    // Helpers
    //

    function disavowTokens() public onlyInGoodTimes returns (bool) {
        require(getReportingState() == ReportingState.AWAITING_FORK_MIGRATION);
        require(stakeTokens.getCount() > 0);
        stakeTokens = MapFactory(controller.lookup("MapFactory")).createMap(controller, this);
        return true;
    }

    function getStakeToken(uint256[] _payoutNumerators, bool _invalid) public onlyInGoodTimes returns (IStakeToken) {
        bytes32 _payoutDistributionHash = derivePayoutDistributionHash(_payoutNumerators, _invalid);
        IStakeToken _stakeToken = IStakeToken(stakeTokens.getAsAddressOrZero(_payoutDistributionHash));
        if (address(_stakeToken) == NULL_ADDRESS) {
            _stakeToken = StakeTokenFactory(controller.lookup("StakeTokenFactory")).createStakeToken(controller, this, _payoutNumerators, _invalid);
            stakeTokens.add(_payoutDistributionHash, _stakeToken);
        }
        return _stakeToken;
    }

    function transferIncorrectDisputeBondsToWinningStakeToken() private onlyInGoodTimes returns (bool) {
        require(getReportingState() == ReportingState.FINALIZED);
        IReputationToken _reputationToken = reportingWindow.getReputationToken();
        if (getForkingMarket() == this) {
            return true;
        }
        if (address(designatedReporterDisputeBondToken) != NULL_ADDRESS && designatedReporterDisputeBondToken.getDisputedPayoutDistributionHash() == finalPayoutDistributionHash) {
            _reputationToken.trustedMarketTransfer(designatedReporterDisputeBondToken, getFinalWinningStakeToken(), _reputationToken.balanceOf(designatedReporterDisputeBondToken));
        }
        if (address(firstReportersDisputeBondToken) != NULL_ADDRESS && firstReportersDisputeBondToken.getDisputedPayoutDistributionHash() == finalPayoutDistributionHash) {
            _reputationToken.trustedMarketTransfer(firstReportersDisputeBondToken, getFinalWinningStakeToken(), _reputationToken.balanceOf(firstReportersDisputeBondToken));
        }
        return true;
    }

    function doFeePayout(bool _toOwner, uint256 _amount) private onlyInGoodTimes returns (bool) {
        if (_toOwner) {
            require(getOwner().call.value(_amount)());
        } else {
            cash.depositEtherFor.value(_amount)(getReportingWindow());
        }
        return true;
    }

    // AUDIT: This is called at the beginning of StakeToken:buy. Look for reentrancy issues
    function firstReporterCompensationCheck(address _reporter) public onlyInGoodTimes returns (uint256) {
        require(isContainerForStakeToken(IStakeToken(msg.sender)));
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

    function increaseTotalStake(uint256 _amount) public onlyInGoodTimes returns (bool) {
        require(msg.sender == address(this) || isContainerForStakeToken(IStakeToken(msg.sender)));
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

    function getFirstReportersDisputeBondToken() public view returns (IDisputeBond) {
        return firstReportersDisputeBondToken;
    }

    function getLastReportersDisputeBondToken() public view returns (IDisputeBond) {
        return lastReportersDisputeBondToken;
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
        if (address(firstReportersDisputeBondToken) != address(0)) {
            if (firstReportersDisputeBondToken.getDisputedPayoutDistributionHash() != finalPayoutDistributionHash) {
                _totalDisputeBondStake += Reporting.firstReportersDisputeBondAmount();
            }
        }
        if (address(lastReportersDisputeBondToken) != address(0)) {
            if (lastReportersDisputeBondToken.getDisputedPayoutDistributionHash() != finalPayoutDistributionHash) {
                _totalDisputeBondStake += Reporting.lastReportersDisputeBondAmount();
            }
        }

        return _totalDisputeBondStake;
    }

    function isContainerForStakeToken(IStakeToken _shadyStakeToken) public view returns (bool) {
        bytes32 _shadyId = _shadyStakeToken.getPayoutDistributionHash();
        IStakeToken _stakeToken = IStakeToken(stakeTokens.getAsAddressOrZero(_shadyId));
        return _stakeToken == _shadyStakeToken;
    }

    function isContainerForShareToken(IShareToken _shadyShareToken) public view returns (bool) {
        return getShareToken(_shadyShareToken.getOutcome()) == _shadyShareToken;
    }

    function isContainerForDisputeBondToken(IDisputeBond _shadyDisputeBond) public view returns (bool) {
        if (designatedReporterDisputeBondToken == _shadyDisputeBond) {
            return true;
        }
        if (firstReportersDisputeBondToken == _shadyDisputeBond) {
            return true;
        }
        if (lastReportersDisputeBondToken == _shadyDisputeBond) {
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
        // This market has been finalized
        if (finalPayoutDistributionHash != bytes32(0)) {
            return IMarket.ReportingState.FINALIZED;
        }

        // If there is an active fork we need to migrate
        IMarket _forkingMarket = getForkingMarket();
        if (address(_forkingMarket) != address(0) && _forkingMarket != this) {
            return IMarket.ReportingState.AWAITING_FORK_MIGRATION;
        }

        // Before trading in the market is finished
        if (block.timestamp < endTime) {
            return IMarket.ReportingState.PRE_REPORTING;
        }

        // Designated reporting period has not passed yet
        if (block.timestamp < getDesignatedReportDueTimestamp()) {
            return IMarket.ReportingState.DESIGNATED_REPORTING;
        }

        bool _designatedReportDisputed = address(designatedReporterDisputeBondToken) != address(0);
        bool _firstReportDisputed = address(firstReportersDisputeBondToken) != address(0);

        // If we have a designated report that hasn't been disputed it is either in the dispute window or we can finalize the market
        if (getDesignatedReportReceivedTime() != 0 && !_designatedReportDisputed) {
            bool _beforeDesignatedDisputeDue = block.timestamp < getDesignatedReportDisputeDueTimestamp();
            return _beforeDesignatedDisputeDue ? IMarket.ReportingState.DESIGNATED_DISPUTE : IMarket.ReportingState.AWAITING_FINALIZATION;
        }

        // If this market is the one forking we are in the process of migration or we're ready to finalize
        if (_forkingMarket == this) {
            if (getWinningPayoutDistributionHashFromFork() != bytes32(0)) {
                return IMarket.ReportingState.AWAITING_FINALIZATION;
            }
            return IMarket.ReportingState.FORKING;
        }

        bool _reportingWindowOver = block.timestamp > reportingWindow.getEndTime();

        if (_reportingWindowOver) {
            if (tentativeWinningPayoutDistributionHash == bytes32(0)) {
                return IMarket.ReportingState.AWAITING_NO_REPORT_MIGRATION;
            }
            return IMarket.ReportingState.AWAITING_FINALIZATION;
        }

        // If a first dispute bond has been posted we are in some phase of last reporting depending on time
        if (_firstReportDisputed) {
            if (reportingWindow.isDisputeActive()) {
                if (tentativeWinningPayoutDistributionHash == bytes32(0)) {
                    return IMarket.ReportingState.AWAITING_NO_REPORT_MIGRATION;
                } else {
                    return IMarket.ReportingState.LAST_DISPUTE;
                }
            }
            return IMarket.ReportingState.LAST_REPORTING;
        }

        // Either no designated report was made or the designated report was disputed so we are in some phase of first reporting
        if (reportingWindow.isDisputeActive()) {
            if (tentativeWinningPayoutDistributionHash == bytes32(0)) {
                return IMarket.ReportingState.AWAITING_NO_REPORT_MIGRATION;
            } else {
                return IMarket.ReportingState.FIRST_DISPUTE;
            }
        }

        return IMarket.ReportingState.FIRST_REPORTING;
    }

    function getWinningPayoutDistributionHashFromFork() private view returns (bytes32) {
        IReputationToken _winningDestination = reportingWindow.getReputationToken().getTopMigrationDestination();
        if (address(_winningDestination) == address(0)) {
            return 0;
        }
        uint256 _halfTotalSupply = 11 * 10**6 * 10**18 / 2;
        if (_winningDestination.totalSupply() < _halfTotalSupply && block.timestamp < reportingWindow.getUniverse().getForkEndTime()) {
            return 0;
        }
        return _winningDestination.getUniverse().getParentPayoutDistributionHash();
    }
}
