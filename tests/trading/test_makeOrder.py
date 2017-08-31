#!/usr/bin/env python

from ethereum.tools import tester
from ethereum.tools.tester import TransactionFailed
from pytest import raises, fixture
from utils import bytesToLong, longTo32Bytes, longToHexString, bytesToHexString, fix, unfix, captureFilteredLogs
from uuid import uuid4

tester.STARTGAS = long(6.7 * 10**6)

YES = 1
NO = 0

BID = 1
ASK = 2

ATTOSHARES = 0
DISPLAY_PRICE = 1
OWNER = 2
TOKENS_ESCROWED = 3
SHARES_ESCROWED = 4
BETTER_ORDER_ID = 5
WORSE_ORDER_ID = 6
GAS_PRICE = 7

def test_publicMakeOrder_bid(contractsFixture):
    cash = contractsFixture.cash
    market = contractsFixture.binaryMarket
    ordersFetcher = contractsFixture.contracts['OrdersFetcher']
    makeOrder = contractsFixture.contracts['makeOrder']
    cash.depositEther(value = 10**17)
    cash.approve(makeOrder.address, 10**17)

    orderID = makeOrder.publicMakeOrder(BID, 10**18, 10**17, market.address, 1, longTo32Bytes(0), longTo32Bytes(0), 7)
    assert orderID

    order = ordersFetcher.getOrder(orderID, BID, market.address, 1)
    assert order[ATTOSHARES] == 10**18
    assert order[DISPLAY_PRICE] == 10**17
    assert order[OWNER] == bytesToHexString(tester.a0)
    assert order[TOKENS_ESCROWED] == 10**17
    assert order[SHARES_ESCROWED] == 0
    assert order[BETTER_ORDER_ID] == bytearray(32)
    assert order[WORSE_ORDER_ID] == bytearray(32)
    assert order[GAS_PRICE] == 0

def test_publicMakeOrder_ask(contractsFixture):
    cash = contractsFixture.cash
    market = contractsFixture.binaryMarket
    ordersFetcher = contractsFixture.contracts['OrdersFetcher']
    makeOrder = contractsFixture.contracts['makeOrder']
    cash.depositEther(value = 10**18)
    cash.approve(makeOrder.address, 10**18)

    orderID = makeOrder.publicMakeOrder(ASK, 10**18, 10**17, market.address, 0, longTo32Bytes(0), longTo32Bytes(0), 7)

    order = ordersFetcher.getOrder(orderID, ASK, market.address, 0)
    assert order[ATTOSHARES] == 10**18
    assert order[DISPLAY_PRICE] == 10**17
    assert order[OWNER] == bytesToHexString(tester.a0)
    assert order[TOKENS_ESCROWED] == 10**18 - 10**17
    assert order[SHARES_ESCROWED] == 0
    assert order[BETTER_ORDER_ID] == bytearray(32)
    assert order[WORSE_ORDER_ID] == bytearray(32)
    assert order[GAS_PRICE] == 0
    assert cash.balanceOf(market.address) == 10**18 - 10**17

def test_publicMakeOrder_bid2(contractsFixture):
    cash = contractsFixture.cash
    market = contractsFixture.binaryMarket
    orders = contractsFixture.contracts['Orders']
    ordersFetcher = contractsFixture.contracts['OrdersFetcher']
    makeOrder = contractsFixture.contracts['makeOrder']
    logs = []

    orderType = BID
    fxpAmount = fix('1')
    fxpPrice = fix('0.6')
    outcome = 0
    tradeGroupID = 42

    assert cash.depositEther(value = fix('10'), sender = tester.k1) == 1, "Deposit cash"
    assert cash.approve(makeOrder.address, fix('10'), sender = tester.k1) == 1, "Approve makeOrder contract to spend cash"
    makerInitialCash = cash.balanceOf(tester.a1)
    marketInitialCash = cash.balanceOf(market.address)
    captureFilteredLogs(contractsFixture.chain.head_state, orders, logs)
    orderID = makeOrder.publicMakeOrder(orderType, fxpAmount, fxpPrice, market.address, outcome, longTo32Bytes(0), longTo32Bytes(0), tradeGroupID, sender=tester.k1)
    assert orderID != bytearray(32), "Order ID should be non-zero"
    order = ordersFetcher.getOrder(orderID, orderType, market.address, outcome)
    assert len(order) == 8, "Order array length should be 8"
    assert order[ATTOSHARES] == fxpAmount, "order[ATTOSHARES] should be the amount of the order"
    assert order[DISPLAY_PRICE] == fxpPrice, "order[DISPLAY_PRICE] should be the order's price"
    assert order[OWNER] == bytesToHexString(tester.a1), "order[OWNER] should be the sender's address"
    assert order[TOKENS_ESCROWED] == 0.6 * 10**18, "order[TOKENS_ESCROWED] should be the amount of money escrowed"
    assert order[SHARES_ESCROWED] == 0, "order[SHARES_ESCROWED] should be the number of shares escrowed"
    assert makerInitialCash - cash.balanceOf(tester.a1) == order[TOKENS_ESCROWED], "Decrease in maker's cash balance should equal money escrowed"
    assert cash.balanceOf(market.address) - marketInitialCash == order[TOKENS_ESCROWED], "Increase in market's cash balance should equal money escrowed"
    assert logs == [
        {
            "_event_type": "MakeOrder",
            "tradeGroupId": tradeGroupID,
            "fxpAmount": order[ATTOSHARES],
            "fxpPrice": order[DISPLAY_PRICE],
            "fxpMoneyEscrowed": order[TOKENS_ESCROWED],
            "fxpSharesEscrowed": order[SHARES_ESCROWED],
            "orderId": orderID,
            "outcome": outcome,
            "market": market.address,
            "sender": bytesToHexString(tester.a1),
            "orderType": BID,
        }
    ]

def test_makeOrder_failure(contractsFixture):
    branch = contractsFixture.branch
    cash = contractsFixture.cash
    market = contractsFixture.binaryMarket
    orders = contractsFixture.contracts['Orders']
    makeOrder = contractsFixture.contracts['makeOrder']
    takeOrder = contractsFixture.contracts['takeOrder']
    completeSets = contractsFixture.contracts['completeSets']
    yesShareToken = contractsFixture.applySignature('shareToken', market.getShareToken(YES))
    noShareToken = contractsFixture.applySignature('shareToken', market.getShareToken(NO))

    with raises(TransactionFailed):
        makeOrder.makeOrder(tester.a1, ASK, fix('1'), fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)
    with raises(TransactionFailed):
        makeOrder.placeAsk(tester.a1, fix('1'), fix('0.6'), market.address, YES, sender=tester.k1)
    with raises(TransactionFailed):
        makeOrder.placeBid(tester.a1, fix('1'), fix('0.6'), market.address, YES, sender=tester.k1)

    # makeOrder exceptions (pre-placeBid/placeAsk)
    with raises(TransactionFailed):
        makeOrder.publicMakeOrder(3, fix('1'), fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)

    # placeBid exceptions
    with raises(TransactionFailed):
        makeOrder.publicMakeOrder(BID, fix('1'), fix('3'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)
    with raises(TransactionFailed):
        makeOrder.publicMakeOrder(BID, 1, fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)

    # placeAsk exceptions
    with raises(TransactionFailed):
        makeOrder.publicMakeOrder(ASK, fix('1'), 1, market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)
    with raises(TransactionFailed):
        makeOrder.publicMakeOrder(ASK, 1, fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)
    assert cash.depositEther(value=fix('2'), sender=tester.k1)
    assert cash.approve(completeSets.address, fix('2'), sender=tester.k1)
    assert completeSets.publicBuyCompleteSets(market.address, fix('2'), sender=tester.k1)
    with raises(TransactionFailed):
        makeOrder.publicMakeOrder(ASK, fix('1'), fix('3'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)
    with raises(TransactionFailed):
        makeOrder.publicMakeOrder(ASK, 1, fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)

    assert cash.approve(makeOrder.address, fix('100'), sender=tester.k1) == 1, "Approve makeOrder contract to spend cash from account 1"
    assert yesShareToken.approve(makeOrder.address, fix('12'), sender=tester.k1) == 1, "Approve makeOrder contract to spend shares from the user's account (account 1)"
    assert yesShareToken.allowance(tester.a1, makeOrder.address) == fix('12'), "makeOrder contract's allowance should be equal to the amount approved"

    with raises(TransactionFailed):
        makeOrder.publicMakeOrder(ASK, fix('1'), fix('0.6'), tester.a1, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)

    assert makeOrder.publicMakeOrder(ASK, fix('1'), fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1) != 0, "Order ID should be non-zero"

    # makeOrder exceptions (post-placeBid/Ask)
    with raises(TransactionFailed):
        makeOrder.publicMakeOrder(ASK, fix('1'), fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)

def test_ask_withPartialShares(contractsFixture):
    branch = contractsFixture.branch
    cash = contractsFixture.cash
    market = contractsFixture.binaryMarket
    orders = contractsFixture.contracts['Orders']
    ordersFetcher = contractsFixture.contracts['OrdersFetcher']
    makeOrder = contractsFixture.contracts['makeOrder']
    takeOrder = contractsFixture.contracts['takeOrder']
    completeSets = contractsFixture.contracts['completeSets']
    yesShareToken = contractsFixture.applySignature('shareToken', market.getShareToken(YES))
    noShareToken = contractsFixture.applySignature('shareToken', market.getShareToken(NO))
    logs = []

    # buy 1.2 complete sets
    assert cash.depositEther(value=fix('1.2'), sender = tester.k1)
    assert cash.approve(completeSets.address, fix('1.2'), sender = tester.k1)
    assert completeSets.publicBuyCompleteSets(market.address, fix('1.2'), sender = tester.k1)
    assert cash.balanceOf(tester.a1) == fix('0')
    assert yesShareToken.balanceOf(tester.a1) == fix('1.2')
    assert noShareToken.balanceOf(tester.a1) == fix('1.2')

    # get enough cash to cover shorting 0.8 more shares
    assert cash.depositEther(value=fix('0.8', '0.4'), sender = tester.k1)
    assert cash.balanceOf(tester.a1) == fix('0.32')

    # create ASK order for 2 shares with a mix of shares and cash
    assert yesShareToken.approve(makeOrder.address, fix('1.2'), sender = tester.k1)
    assert cash.approve(makeOrder.address, fix('0.32'), sender = tester.k1)
    captureFilteredLogs(contractsFixture.chain.head_state, orders, logs)
    orderID = makeOrder.publicMakeOrder(ASK, fix('2'), fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), 42, sender=tester.k1)
    assert cash.balanceOf(tester.a1) == fix('0')
    assert yesShareToken.balanceOf(tester.a1) == fix('0')
    assert noShareToken.balanceOf(tester.a1) == fix('1.2')

    # validate the order contains expected results
    assert orderID != bytearray(32), "Order ID should be non-zero"
    order = ordersFetcher.getOrder(orderID, ASK, market.address, YES)
    assert len(order) == 8, "Order array length should be 13"
    assert order[ATTOSHARES] == fix('2'), "order[ATTOSHARES] should be the amount of the order"
    assert order[DISPLAY_PRICE] == fix('0.6'), "order[DISPLAY_PRICE] should be the order's price"
    assert order[OWNER] == bytesToHexString(tester.a1), "order[OWNER] should be the sender's address"
    assert order[TOKENS_ESCROWED] == fix('0.32'), "order[TOKENS_ESCROWED] should be the amount of money escrowed"
    assert order[SHARES_ESCROWED] == fix('1.2'), "order[SHARES_ESCROWED] should be the number of shares escrowed"

    # validate the log output of the order
    assert logs == [
        {
            "_event_type": "MakeOrder",
            "tradeGroupId": 42,
            "fxpAmount": order[ATTOSHARES],
            "fxpPrice": order[DISPLAY_PRICE],
            "fxpMoneyEscrowed": order[TOKENS_ESCROWED],
            "fxpSharesEscrowed": order[SHARES_ESCROWED],
            "orderId": orderID,
            "orderType": ASK,
            "outcome": YES,
            "market": market.address,
            "sender": bytesToHexString(tester.a1),
            "orderType": ASK,
        }
    ]
