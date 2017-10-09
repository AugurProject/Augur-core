#!/usr/bin/env python

from datetime import timedelta
from ethereum.tools import tester
from ethereum.tools.tester import TransactionFailed
from pytest import raises, fixture
from utils import fix
from constants import YES, NO


def captureLog(contract, logs, message):
    translated = contract.translator.listen(message)
    if not translated: return
    logs.append(translated)

def acquireLongShares(fundedRepFixture, market, outcome, amount, approvalAddress, sender):
    if amount == 0: return

    cash = fundedRepFixture.cash
    shareToken = fundedRepFixture.applySignature('ShareToken', market.getShareToken(outcome))
    completeSets = fundedRepFixture.contracts['CompleteSets']
    createOrder = fundedRepFixture.contracts['CreateOrder']
    fillOrder = fundedRepFixture.contracts['FillOrder']
    cost = amount * market.getNumTicks()

    assert completeSets.publicBuyCompleteSets(market.address, amount, sender = sender, value = cost)
    assert shareToken.approve(approvalAddress, amount, sender = sender)
    for otherOutcome in range(0, market.getNumberOfOutcomes()):
        if otherOutcome == outcome: continue
        otherShareToken = fundedRepFixture.applySignature('ShareToken', market.getShareToken(otherOutcome))
        assert otherShareToken.transfer(0, amount, sender = sender)

def acquireShortShareSet(fundedRepFixture, market, outcome, amount, approvalAddress, sender):
    if amount == 0: return
    cost = amount * market.getNumTicks()

    cash = fundedRepFixture.cash
    shareToken = fundedRepFixture.applySignature('ShareToken', market.getShareToken(outcome))
    completeSets = fundedRepFixture.contracts['CompleteSets']
    createOrder = fundedRepFixture.contracts['CreateOrder']
    fillOrder = fundedRepFixture.contracts['FillOrder']

    assert completeSets.publicBuyCompleteSets(market.address, amount, sender = sender, value = cost)
    assert shareToken.transfer(0, amount, sender = sender)
    for otherOutcome in range(0, market.getNumberOfOutcomes()):
        if otherOutcome == outcome: continue
        otherShareToken = fundedRepFixture.applySignature('ShareToken', market.getShareToken(otherOutcome))
        assert otherShareToken.approve(approvalAddress, amount, sender = sender)

def finalizeMarket(fixture, market, payoutNumerators):
    # set timestamp to after market end
    fixture.chain.head_state.timestamp = market.getEndTime() + 1
    # have tester.a0 submit designated report
    fixture.designatedReport(market, payoutNumerators, tester.k0)
    # set timestamp to after designated dispute end
    fixture.chain.head_state.timestamp = market.getDesignatedReportDisputeDueTimestamp() + 1
    # finalize the market
    assert market.tryFinalize()
    # set timestamp to 3 days later (waiting period)
    fixture.chain.head_state.timestamp += long(timedelta(days = 3, seconds = 1).total_seconds())

def test_helpers(fundedRepFixture):
    market = fundedRepFixture.scalarMarket
    claimProceeds = fundedRepFixture.contracts['ClaimProceeds']
    finalizeMarket(fundedRepFixture, market, [0,40*10**18])

    assert claimProceeds.calculateCreatorFee(market.address, fix('3')) == fix('0.03')
    assert claimProceeds.calculateReportingFee(market.address, fix('5')) == fix('0.0005')
    assert claimProceeds.calculateProceeds(market.getFinalWinningReportingToken(), YES, 7) == 7 * market.getNumTicks()
    assert claimProceeds.calculateProceeds(market.getFinalWinningReportingToken(), NO, fix('11')) == fix('0')
    (proceeds, shareholderShare, creatorShare, reporterShare) = claimProceeds.divideUpWinnings(market.address, market.getFinalWinningReportingToken(), YES, 13)
    assert proceeds == 13.0 * market.getNumTicks()
    assert reporterShare == 13.0 * market.getNumTicks() * 0.0001
    assert creatorShare == 13.0 * market.getNumTicks() * .01
    assert shareholderShare == 13.0 * market.getNumTicks() * 0.9899

def test_redeem_shares_in_binary_market(fundedRepFixture):
    cash = fundedRepFixture.cash
    market = fundedRepFixture.binaryMarket
    universe = fundedRepFixture.universe
    claimProceeds = fundedRepFixture.contracts['ClaimProceeds']
    yesShareToken = fundedRepFixture.applySignature('ShareToken', market.getShareToken(YES))
    noShareToken = fundedRepFixture.applySignature('ShareToken', market.getShareToken(NO))
    expectedValue = 1 * market.getNumTicks()
    expectedSettlementFees = expectedValue * 0.0101
    expectedPayout = long(expectedValue - expectedSettlementFees)

    assert universe.getOpenInterestInAttoEth() == 0

    # get YES shares with a1
    acquireLongShares(fundedRepFixture, market, YES, 1, claimProceeds.address, sender = tester.k1)
    assert universe.getOpenInterestInAttoEth() == 1 * market.getNumTicks()
    # get NO shares with a2
    acquireShortShareSet(fundedRepFixture, market, YES, 1, claimProceeds.address, sender = tester.k2)
    assert universe.getOpenInterestInAttoEth() == 2 * market.getNumTicks()
    finalizeMarket(fundedRepFixture, market, [0,10**18])

    # redeem shares with a1
    initialLongHolderETH = fundedRepFixture.utils.getETHBalance(tester.a1)
    claimProceeds.claimProceeds(market.address, sender = tester.k1)
    # redeem shares with a2
    initialShortHolderETH = fundedRepFixture.utils.getETHBalance(tester.a2)
    claimProceeds.claimProceeds(market.address, sender = tester.k2)

    # assert a1 ends up with cash (minus fees) and a2 does not
    assert fundedRepFixture.utils.getETHBalance(tester.a1) == initialLongHolderETH + expectedPayout
    assert fundedRepFixture.utils.getETHBalance(tester.a2) == initialShortHolderETH
    assert yesShareToken.balanceOf(tester.a1) == 0
    assert yesShareToken.balanceOf(tester.a2) == 0
    assert noShareToken.balanceOf(tester.a1) == 0
    assert noShareToken.balanceOf(tester.a2) == 0
    assert universe.getOpenInterestInAttoEth() == 1 * market.getNumTicks() # The corresponding share for tester2's complete set has not been redeemed

def test_redeem_shares_in_categorical_market(fundedRepFixture):
    cash = fundedRepFixture.cash
    market = fundedRepFixture.categoricalMarket
    universe = fundedRepFixture.universe
    claimProceeds = fundedRepFixture.contracts['ClaimProceeds']
    shareToken2 = fundedRepFixture.applySignature('ShareToken', market.getShareToken(2))
    shareToken1 = fundedRepFixture.applySignature('ShareToken', market.getShareToken(1))
    shareToken0 = fundedRepFixture.applySignature('ShareToken', market.getShareToken(0))
    expectedValue = 1 * market.getNumTicks()
    expectedSettlementFees = expectedValue * 0.0101
    expectedPayout = long(expectedValue - expectedSettlementFees)

    assert universe.getOpenInterestInAttoEth() == 0

    # get long shares with a1
    acquireLongShares(fundedRepFixture, market, 2, 1, claimProceeds.address, sender = tester.k1)
    assert universe.getOpenInterestInAttoEth() == 1 * market.getNumTicks()
    # get short shares with a2
    acquireShortShareSet(fundedRepFixture, market, 2, 1, claimProceeds.address, sender = tester.k2)
    assert universe.getOpenInterestInAttoEth() == 2 * market.getNumTicks()
    finalizeMarket(fundedRepFixture, market, [0, 0, 3 * 10 ** 17])

    # redeem shares with a1
    initialLongHolderETH = fundedRepFixture.utils.getETHBalance(tester.a1)
    claimProceeds.claimProceeds(market.address, sender = tester.k1)
    # redeem shares with a2
    initialShortHolderETH = fundedRepFixture.utils.getETHBalance(tester.a2)
    claimProceeds.claimProceeds(market.address, sender = tester.k2)

    # assert a1 ends up with cash (minus fees) and a2 does not
    assert fundedRepFixture.utils.getETHBalance(tester.a1) == initialLongHolderETH + expectedPayout
    assert fundedRepFixture.utils.getETHBalance(tester.a2) == initialShortHolderETH
    assert shareToken2.balanceOf(tester.a1) == 0
    assert shareToken2.balanceOf(tester.a2) == 0
    assert shareToken1.balanceOf(tester.a1) == 0
    assert shareToken1.balanceOf(tester.a2) == 0
    assert shareToken0.balanceOf(tester.a1) == 0
    assert shareToken0.balanceOf(tester.a2) == 0
    assert universe.getOpenInterestInAttoEth() == 1 * market.getNumTicks()

def test_redeem_shares_in_scalar_market(fundedRepFixture):
    cash = fundedRepFixture.cash
    market = fundedRepFixture.scalarMarket
    universe = fundedRepFixture.universe
    claimProceeds = fundedRepFixture.contracts['ClaimProceeds']
    yesShareToken = fundedRepFixture.applySignature('ShareToken', market.getShareToken(YES))
    noShareToken = fundedRepFixture.applySignature('ShareToken', market.getShareToken(NO))
    expectedValue = 1 * market.getNumTicks()
    expectedSettlementFees = expectedValue * 0.0101
    expectedPayout = long(expectedValue - expectedSettlementFees)

    assert universe.getOpenInterestInAttoEth() == 0

    # get YES shares with a1
    acquireLongShares(fundedRepFixture, market, YES, 1, claimProceeds.address, sender = tester.k1)
    assert universe.getOpenInterestInAttoEth() == 1 * market.getNumTicks()
    # get NO shares with a2
    acquireShortShareSet(fundedRepFixture, market, YES, 1, claimProceeds.address, sender = tester.k2)
    assert universe.getOpenInterestInAttoEth() == 2 * market.getNumTicks()
    finalizeMarket(fundedRepFixture, market, [10**19, 3*10**19])

    # redeem shares with a1
    initialLongHolderETH = fundedRepFixture.utils.getETHBalance(tester.a1)
    claimProceeds.claimProceeds(market.address, sender = tester.k1)
    # redeem shares with a2
    initialShortHolderETH = fundedRepFixture.utils.getETHBalance(tester.a2)
    claimProceeds.claimProceeds(market.address, sender = tester.k2)

    # assert a1 ends up with cash (minus fees) and a2 does not
    assert fundedRepFixture.utils.getETHBalance(tester.a1) == initialLongHolderETH + expectedPayout * 3 / 4
    assert fundedRepFixture.utils.getETHBalance(tester.a2) == initialShortHolderETH + expectedPayout * 1 / 4
    assert yesShareToken.balanceOf(tester.a1) == 0
    assert yesShareToken.balanceOf(tester.a2) == 0
    assert noShareToken.balanceOf(tester.a1) == 0
    assert noShareToken.balanceOf(tester.a2) == 0
    assert universe.getOpenInterestInAttoEth() == 1 * market.getNumTicks()

def test_reedem_failure(fundedRepFixture):
    cash = fundedRepFixture.cash
    market = fundedRepFixture.binaryMarket
    claimProceeds = fundedRepFixture.contracts['ClaimProceeds']

    # get YES shares with a1
    acquireLongShares(fundedRepFixture, market, YES, 1, claimProceeds.address, sender = tester.k1)
    # get NO shares with a2
    acquireShortShareSet(fundedRepFixture, market, YES, 1, claimProceeds.address, sender = tester.k2)
    # set timestamp to after market end
    fundedRepFixture.chain.head_state.timestamp = market.getEndTime() + 1
    # have tester.a0 subimt designated report (75% high, 25% low, range -10*10^18 to 30*10^18)
    fundedRepFixture.designatedReport(market, [0, 10**18], tester.k0)
    # set timestamp to after designated dispute end
    fundedRepFixture.chain.head_state.timestamp = market.getDesignatedReportDisputeDueTimestamp() + 1

    # market not finalized
    with raises(TransactionFailed):
        claimProceeds.claimProceeds(market.address, sender = tester.k1)
    # finalize the market
    assert market.tryFinalize()
    # waiting period not over
    with raises(TransactionFailed):
        claimProceeds.claimProceeds(market.address, sender = tester.k1)

    # set timestamp to 3 days later (waiting period)
    fundedRepFixture.chain.head_state.timestamp += long(timedelta(days = 3, seconds = 1).total_seconds())
    # validate that everything else is OK
    assert claimProceeds.claimProceeds(market.address, sender = tester.k1)
