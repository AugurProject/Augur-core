// Copyright (C) 2015 Forecast Foundation OU, full GPL notice in LICENSE

pragma solidity 0.4.17;


import 'reporting/IReportingWindow.sol';
import 'libraries/DelegationTarget.sol';
import 'libraries/ITyped.sol';
import 'libraries/Initializable.sol';
import 'libraries/collections/Set.sol';
import 'reporting/IUniverse.sol';
import 'reporting/IReputationToken.sol';
import 'reporting/IMarket.sol';
import 'reporting/IStakeToken.sol';
import 'reporting/IDisputeBond.sol';
import 'trading/ICash.sol';
import 'factories/MarketFactory.sol';
import 'reporting/Reporting.sol';
import 'libraries/math/SafeMathUint256.sol';
import 'libraries/math/RunningAverage.sol';
import 'reporting/IReportingAttendanceToken.sol';
import 'factories/ReportingAttendanceTokenFactory.sol';


contract ReportingWindow is DelegationTarget, ITyped, Initializable, IReportingWindow {
    using SafeMathUint256 for uint256;
    using Set for Set.Data;
    using RunningAverage for RunningAverage.Data;

    IUniverse private universe;
    uint256 private startTime;
    Set.Data private markets;
    Set.Data private round1ReporterMarkets;
    Set.Data private round2ReporterMarkets;
    Set.Data private finalizedMarkets;
    uint256 private invalidMarketCount;
    uint256 private incorrectDesignatedReportMarketCount;
    uint256 private designatedReportNoShows;
    uint256 private constant BASE_MINIMUM_REPORTERS_PER_MARKET = 7;
    RunningAverage.Data private reportingGasPrice;
    uint256 private totalWinningStake;
    uint256 private totalStake;
    IReportingAttendanceToken private reportingAttendanceToken;

    function initialize(IUniverse _universe, uint256 _reportingWindowId) public beforeInitialized returns (bool) {
        endInitialization();
        universe = _universe;
        startTime = _reportingWindowId * universe.getReportingPeriodDurationInSeconds();
        // Initialize this to some reasonable value to handle the first market ever created without branching code
        reportingGasPrice.record(Reporting.defaultReportingGasPrice());
        reportingAttendanceToken = ReportingAttendanceTokenFactory(controller.lookup("ReportingAttendanceTokenFactory")).createReportingAttendanceToken(controller, this);
        return true;
    }

    function createMarket(uint256 _endTime, uint8 _numOutcomes, uint256 _numTicks, uint256 _feePerEthInWei, ICash _denominationToken, address _designatedReporterAddress) public afterInitialized payable returns (IMarket _newMarket) {
        require(block.timestamp < startTime);
        require(universe.getReportingWindowByMarketEndTime(_endTime) == this);
        MarketFactory _marketFactory = MarketFactory(controller.lookup("MarketFactory"));
        getReputationToken().trustedTransfer(msg.sender, _marketFactory, universe.getDesignatedReportNoShowBond());
        _newMarket = _marketFactory.createMarket.value(msg.value)(controller, this, _endTime, _numOutcomes, _numTicks, _feePerEthInWei, _denominationToken, msg.sender, _designatedReporterAddress);
        markets.add(_newMarket);
        round1ReporterMarkets.add(_newMarket);
        return _newMarket;
    }

    function migrateMarketInFromSibling() public afterInitialized returns (bool) {
        IMarket _market = IMarket(msg.sender);
        IReportingWindow _shadyReportingWindow = _market.getReportingWindow();
        require(universe.isContainerForReportingWindow(_shadyReportingWindow));
        IReportingWindow _originalReportingWindow = _shadyReportingWindow;
        require(_originalReportingWindow.isContainerForMarket(_market));
        _originalReportingWindow.migrateFeesDueToMarketMigration(_market);
        privateAddMarket(_market);
        return true;
    }

    function migrateMarketInFromNibling() public afterInitialized returns (bool) {
        IMarket _shadyMarket = IMarket(msg.sender);
        IUniverse _shadyUniverse = _shadyMarket.getUniverse();
        require(_shadyUniverse == universe.getParentUniverse());
        IUniverse _originalUniverse = _shadyUniverse;
        IReportingWindow _shadyReportingWindow = _shadyMarket.getReportingWindow();
        require(_originalUniverse.isContainerForReportingWindow(_shadyReportingWindow));
        IReportingWindow _originalReportingWindow = _shadyReportingWindow;
        require(_originalReportingWindow.isContainerForMarket(_shadyMarket));
        IMarket _legitMarket = _shadyMarket;
        _originalReportingWindow.migrateFeesDueToFork();
        privateAddMarket(_legitMarket);
        return true;
    }

    function removeMarket() public afterInitialized returns (bool) {
        IMarket _market = IMarket(msg.sender);
        require(markets.contains(_market));
        totalStake = totalStake.sub(_market.getTotalStake());
        markets.remove(_market);
        round1ReporterMarkets.remove(_market);
        round2ReporterMarkets.remove(_market);
        return true;
    }

    function updateMarketPhase() public afterInitialized returns (bool) {
        IMarket _market = IMarket(msg.sender);
        require(markets.contains(_market));
        IMarket.ReportingState _state = _market.getReportingState();

        if (_state == IMarket.ReportingState.ROUND2_REPORTING) {
            round2ReporterMarkets.add(_market);
        } else {
            round2ReporterMarkets.remove(_market);
        }

        if (_state == IMarket.ReportingState.ROUND1_REPORTING) {
            round1ReporterMarkets.add(_market);
        } else {
            round1ReporterMarkets.remove(_market);
        }

        if (_state == IMarket.ReportingState.FINALIZED) {
            updateFinalizedMarket(_market);
        }

        return true;
    }

    function updateFinalizedMarket(IMarket _market) private returns (bool) {
        require(!finalizedMarkets.contains(_market));

        if (!_market.isValid()) {
            invalidMarketCount++;
        }
        if (_market.getFinalPayoutDistributionHash() != _market.getDesignatedReportPayoutHash()) {
            incorrectDesignatedReportMarketCount++;
        }
        finalizedMarkets.add(_market);
        uint256 _totalWinningStake = _market.getFinalWinningStakeToken().totalSupply();
        _totalWinningStake = _totalWinningStake.add(_market.getTotalWinningDisputeBondStake());
        totalWinningStake = totalWinningStake.add(_totalWinningStake);
    }

    function noteReportingGasPrice(IMarket _market) public afterInitialized returns (bool) {
        require(markets.contains(_market));
        require(_market.isContainerForStakeToken(ITyped(msg.sender)));
        reportingGasPrice.record(tx.gasprice);
        return true;
    }

    function getAvgReportingGasPrice() public view returns (uint256) {
        return reportingGasPrice.currentAverage();
    }

    function getTypeName() public afterInitialized view returns (bytes32) {
        return "ReportingWindow";
    }

    function getUniverse() public afterInitialized view returns (IUniverse) {
        return universe;
    }

    function getReputationToken() public afterInitialized view returns (IReputationToken) {
        return universe.getReputationToken();
    }

    function getStartTime() public afterInitialized view returns (uint256) {
        return startTime;
    }

    function getEndTime() public afterInitialized view returns (uint256) {
        return getDisputeEndTime();
    }

    function getNumMarkets() public afterInitialized view returns (uint256) {
        return markets.count;
    }

    function getNumInvalidMarkets() public afterInitialized view returns (uint256) {
        return invalidMarketCount;
    }

    function getNumIncorrectDesignatedReportMarkets() public view returns (uint256) {
        return incorrectDesignatedReportMarketCount;
    }

    function getNumDesignatedReportNoShows() public view returns (uint256) {
        return designatedReportNoShows;
    }

    function getReportingStartTime() public afterInitialized view returns (uint256) {
        return getStartTime();
    }

    function getReportingEndTime() public afterInitialized view returns (uint256) {
        return getStartTime() + Reporting.reportingDurationSeconds();
    }

    function getDisputeStartTime() public afterInitialized view returns (uint256) {
        return getReportingEndTime();
    }

    function getDisputeEndTime() public afterInitialized view returns (uint256) {
        return getDisputeStartTime() + Reporting.reportingDisputeDurationSeconds();
    }

    function getNextReportingWindow() public returns (IReportingWindow) {
        uint256 _nextTimestamp = getEndTime() + 1;
        return getUniverse().getReportingWindowByTimestamp(_nextTimestamp);
    }

    function getPreviousReportingWindow() public returns (IReportingWindow) {
        uint256 _previousTimestamp = getStartTime() - 1;
        return getUniverse().getReportingWindowByTimestamp(_previousTimestamp);
    }

    function getTotalStake() public view returns (uint256) {
        return totalStake;
    }

    function getTotalWinningStake() public view returns (uint256) {
        return totalWinningStake;
    }

    function getReportingAttendanceToken() public view returns (IReportingAttendanceToken) {
        return reportingAttendanceToken;
    }

    function allMarketsFinalized() constant public returns (bool) {
        return markets.count == finalizedMarkets.count;
    }

    function collectReportingFees(address _reporterAddress, uint256 _attoStake, bool _forgoFees) public returns (bool) {
        ITyped _shadyCaller = ITyped(msg.sender);
        require(isContainerForStakeToken(_shadyCaller) ||
                isContainerForDisputeBond(_shadyCaller) ||
                msg.sender == address(reportingAttendanceToken));
        bool _eligibleForFees = isOver() && allMarketsFinalized();
        if (!_forgoFees) {
            require(_eligibleForFees);
        } else {
            require(!_eligibleForFees);
        }
        // NOTE: Will need to handle other denominations when that is implemented
        ICash _cash = ICash(controller.lookup("Cash"));
        uint256 _balance = _cash.balanceOf(this);
        uint256 _feePayoutShare = _balance.mul(_attoStake).div(totalWinningStake);
        totalStake = totalStake.sub(_attoStake);
        totalWinningStake = totalWinningStake.sub(_attoStake);
        if (!_forgoFees && _feePayoutShare > 0) {
            _cash.withdrawEtherTo(_reporterAddress, _feePayoutShare);
        }
        return true;
    }

    function migrateFeesDueToMarketMigration(IMarket _market) public afterInitialized returns (bool) {
        if (totalStake == 0) {
            return false;
        }
        IReportingWindow _shadyReportingWindow = IReportingWindow(msg.sender);
        require(universe.isContainerForReportingWindow(_shadyReportingWindow));
        IReportingWindow _destinationReportingWindow = _shadyReportingWindow;
        // NOTE: Will need to figure out a way to transfer other denominations when that is implemented
        ICash _cash = ICash(controller.lookup("Cash"));
        uint256 _balance = _cash.balanceOf(this);
        uint256 _amountToTransfer = _balance.mul(_market.getTotalStake()).div(totalStake);
        if (_amountToTransfer == 0) {
            return false;
        }
        _cash.transfer(_destinationReportingWindow, _amountToTransfer);
        return true;
    }

    // This exists as an edge case handler for when a ReportingWindow has no markets but we want to migrate fees to a new universe. If a market exists it should be migrated and that will trigger a fee migration. Otherwise calling this on the desitnation reporting window in the forked universe with the old reporting window as an argument will trigger a fee migration manaully
    function triggerMigrateFeesDueToFork(IReportingWindow _reportingWindow) public afterInitialized returns (bool) {
        require(_reportingWindow.getNumMarkets() == 0);
        _reportingWindow.migrateFeesDueToFork();
    }

    function migrateFeesDueToFork() public afterInitialized returns (bool) {
        require(isForkingMarketFinalized());
        // NOTE: Will need to figure out a way to transfer other denominations when that is implemented
        ICash _cash = ICash(controller.lookup("Cash"));
        uint256 _balance = _cash.balanceOf(this);
        if (_balance == 0) {
            return false;
        }
        IReportingWindow _shadyReportingWindow = IReportingWindow(msg.sender);
        IUniverse _shadyUniverse = _shadyReportingWindow.getUniverse();
        require(_shadyUniverse.isContainerForReportingWindow(_shadyReportingWindow));
        require(universe.isParentOf(_shadyUniverse));
        IUniverse _destinationUniverse = _shadyUniverse;
        IReportingWindow _destinationReportingWindow = _shadyReportingWindow;
        bytes32 _winningForkPayoutDistributionHash = universe.getForkingMarket().getFinalPayoutDistributionHash();
        require(_destinationUniverse == universe.getChildUniverse(_winningForkPayoutDistributionHash));
        _cash.transfer(_destinationReportingWindow, _balance);
        return true;
    }

    function increaseTotalStake(uint256 _amount) public returns (bool) {
        require(isContainerForMarket(ITyped(msg.sender)));
        totalStake = totalStake.add(_amount);
    }

    function increaseTotalWinningStake(uint256 _amount) public returns (bool) {
        require(msg.sender == address(reportingAttendanceToken));
        totalStake = totalStake.add(_amount);
        totalWinningStake = totalWinningStake.add(_amount);
    }

    function isActive() public afterInitialized view returns (bool) {
        if (block.timestamp <= getStartTime()) {
            return false;
        }
        if (block.timestamp >= getEndTime()) {
            return false;
        }
        return true;
    }

    function isReportingActive() public afterInitialized view returns (bool) {
        if (block.timestamp <= getStartTime()) {
            return false;
        }
        if (block.timestamp >= getReportingEndTime()) {
            return false;
        }
        return true;
    }

    function isDisputeActive() public afterInitialized view returns (bool) {
        if (block.timestamp <= getDisputeStartTime()) {
            return false;
        }
        if (block.timestamp >= getEndTime()) {
            return false;
        }
        return true;
    }

    function isOver() public afterInitialized view returns (bool) {
        return block.timestamp >= getEndTime();
    }

    function getMarketsCount() public afterInitialized view returns (uint256) {
        return markets.count;
    }

    function getRound1ReporterMarketsCount() public afterInitialized view returns (uint256) {
        return round1ReporterMarkets.count;
    }

    function getRound2ReporterMarketsCount() public afterInitialized view returns (uint256) {
        return round2ReporterMarkets.count;
    }

    function isContainerForStakeToken(ITyped _shadyTarget) public afterInitialized view returns (bool) {
        if (_shadyTarget.getTypeName() != "StakeToken") {
            return false;
        }
        IStakeToken _shadyStakeToken = IStakeToken(_shadyTarget);
        IMarket _shadyMarket = _shadyStakeToken.getMarket();
        require(isContainerForMarket(_shadyMarket));
        IMarket _market = _shadyMarket;
        return _market.isContainerForStakeToken(_shadyStakeToken);
    }

    function isContainerForDisputeBond(ITyped _shadyTarget) public afterInitialized view returns (bool) {
        if (_shadyTarget.getTypeName() != "DisputeBondToken") {
            return false;
        }
        IDisputeBond _shadyDisbuteBondToken = IDisputeBond(_shadyTarget);
        IMarket _shadyMarket = _shadyDisbuteBondToken.getMarket();
        require(isContainerForMarket(_shadyMarket));
        IMarket _market = _shadyMarket;
        return _market.isContainerForDisputeBondToken(_shadyDisbuteBondToken);
    }

    function isContainerForMarket(ITyped _shadyTarget) public afterInitialized view returns (bool) {
        if (_shadyTarget.getTypeName() != "Market") {
            return false;
        }
        IMarket _shadyMarket = IMarket(_shadyTarget);
        return markets.contains(_shadyMarket);
    }

    function isContainerForReportingAttendanceToken(ITyped _shadyTarget) public afterInitialized view returns (bool) {
        if (_shadyTarget.getTypeName() != "ReportingAttendanceToken") {
            return false;
        }
        IReportingAttendanceToken _shadyReportingAttendanceToken = IReportingAttendanceToken(_shadyTarget);
        return reportingAttendanceToken == _shadyReportingAttendanceToken;
    }

    function privateAddMarket(IMarket _market) private afterInitialized returns (bool) {
        require(!markets.contains(_market));
        require(!round1ReporterMarkets.contains(_market));
        require(!round2ReporterMarkets.contains(_market));
        totalStake = totalStake.add(_market.getTotalStake());
        markets.add(_market);
        return true;
    }

    function isForkingMarketFinalized() public afterInitialized view returns (bool) {
        return getUniverse().getForkingMarket().getReportingState() == IMarket.ReportingState.FINALIZED;
    }
}
