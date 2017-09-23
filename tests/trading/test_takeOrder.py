#!/usr/bin/env python

from ethereum.tools import tester
from utils import fix, bytesToHexString, captureFilteredLogs, longTo32Bytes, longToHexString
from constants import BID, ASK, YES, NO


def test_publicTakeOrder_bid(contractsFixture):
    cash = contractsFixture.cash
    makeOrder = contractsFixture.contracts['MakeOrder']
    takeOrder = contractsFixture.contracts['TakeOrder']
    orders = contractsFixture.contracts['Orders']
    ordersFetcher = contractsFixture.contracts['OrdersFetcher']
    market = contractsFixture.binaryMarket
    tradeGroupID = 42
    logs = []

    initialMakerETH = contractsFixture.utils.getETHBalance(tester.a1)
    initialTakerETH = contractsFixture.utils.getETHBalance(tester.a2)
    makerCost = fix('2', '0.6')
    takerCost = fix('2', '0.4')

    # create order
    orderID = makeOrder.publicMakeOrder(BID, 2, fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), tradeGroupID, sender = tester.k1, value=makerCost)

    # take best order
    captureFilteredLogs(contractsFixture.chain.head_state, orders, logs)
    fillOrderID = takeOrder.publicTakeOrder(orderID, 2, tradeGroupID, sender = tester.k2, value=takerCost)

    # assert
    assert logs == [
        {
            "_event_type": "BuyCompleteSets",
            "sender": takeOrder.address,
            "amount": 2,
            "numOutcomes": 2,
            "market": market.address,
        },
        {
            "_event_type": "TakeOrder",
            "market": market.address,
            "outcome": YES,
            "orderType": BID,
            "orderId": orderID,
            "price": int(fix('0.6')),
            "maker": bytesToHexString(tester.a1),
            "taker": bytesToHexString(tester.a2),
            "makerShares": 0,
            "makerTokens": int(makerCost),
            "takerShares": 0,
            "takerTokens": int(takerCost),
            "tradeGroupId": 42,
        },
    ]

    assert contractsFixture.utils.getETHBalance(tester.a1) == initialMakerETH - makerCost
    assert contractsFixture.utils.getETHBalance(tester.a2) == initialTakerETH - takerCost
    assert ordersFetcher.getOrder(orderID) == [0, 0, longToHexString(0), 0, 0, longTo32Bytes(0), longTo32Bytes(0), 0]
    assert fillOrderID == 0

def test_publicTakeOrder_ask(contractsFixture):
    cash = contractsFixture.cash
    makeOrder = contractsFixture.contracts['MakeOrder']
    takeOrder = contractsFixture.contracts['TakeOrder']
    orders = contractsFixture.contracts['Orders']
    ordersFetcher = contractsFixture.contracts['OrdersFetcher']
    market = contractsFixture.binaryMarket
    tradeGroupID = 42
    logs = []

    initialMakerETH = contractsFixture.utils.getETHBalance(tester.a1)
    initialTakerETH = contractsFixture.utils.getETHBalance(tester.a2)
    makerCost = fix('2', '0.4')
    takerCost = fix('2', '0.6')

    # create order
    orderID = makeOrder.publicMakeOrder(ASK, 2, fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), tradeGroupID, sender = tester.k1, value=makerCost)

    # take best order
    captureFilteredLogs(contractsFixture.chain.head_state, orders, logs)
    fillOrderID = takeOrder.publicTakeOrder(orderID, 2, tradeGroupID, sender = tester.k2, value=takerCost)

    # assert
    assert logs == [
        {
            "_event_type": "BuyCompleteSets",
            "sender": takeOrder.address,
            "amount": 2,
            "numOutcomes": 2,
            "market": market.address
        },
        {
            "_event_type": "TakeOrder",
            "market": market.address,
            "outcome": YES,
            "orderType": ASK,
            "orderId": orderID,
            "price": fix('0.6'),
            "maker": bytesToHexString(tester.a1),
            "taker": bytesToHexString(tester.a2),
            "makerShares": 0,
            "makerTokens": makerCost,
            "takerShares": 0,
            "takerTokens": takerCost,
            "tradeGroupId": tradeGroupID
        },
    ]

    assert contractsFixture.utils.getETHBalance(tester.a1) == initialMakerETH - makerCost
    assert contractsFixture.utils.getETHBalance(tester.a2) == initialTakerETH - takerCost
    assert ordersFetcher.getOrder(orderID) == [0, 0, longToHexString(0), 0, 0, longTo32Bytes(0), longTo32Bytes(0), 0]
    assert fillOrderID == 0

def test_publicTakeOrder_bid_scalar(contractsFixture):
    cash = contractsFixture.cash
    makeOrder = contractsFixture.contracts['MakeOrder']
    takeOrder = contractsFixture.contracts['TakeOrder']
    orders = contractsFixture.contracts['Orders']
    ordersFetcher = contractsFixture.contracts['OrdersFetcher']
    # We're testing the scalar market because it has a different marketDenominator than 10**18 as the other do. In particular it's marketDenominator is 40*18**18
    market = contractsFixture.scalarMarket
    tradeGroupID = 42
    logs = []

    initialMakerETH = contractsFixture.utils.getETHBalance(tester.a1)
    initialTakerETH = contractsFixture.utils.getETHBalance(tester.a2)
    makerCost = fix('2', '0.6')
    takerCost = fix('2', '39.4')

    # create order
    orderID = makeOrder.publicMakeOrder(BID, 2, fix('0.6'), market.address, YES, longTo32Bytes(0), longTo32Bytes(0), tradeGroupID, sender = tester.k1, value=makerCost)

    # take best order
    captureFilteredLogs(contractsFixture.chain.head_state, orders, logs)
    fillOrderID = takeOrder.publicTakeOrder(orderID, 2, tradeGroupID, sender = tester.k2, value=takerCost)

    # assert
    assert logs == [
        {
            "_event_type": "BuyCompleteSets",
            "sender": takeOrder.address,
            "amount": 2,
            "numOutcomes": 2,
            "market": market.address,
        },
        {
            "_event_type": "TakeOrder",
            "market": market.address,
            "outcome": YES,
            "orderType": BID,
            "orderId": orderID,
            "price": int(fix('0.6')),
            "maker": bytesToHexString(tester.a1),
            "taker": bytesToHexString(tester.a2),
            "makerShares": 0,
            "makerTokens": int(makerCost),
            "takerShares": 0,
            "takerTokens": int(takerCost),
            "tradeGroupId": 42,
        },
    ]

    assert contractsFixture.utils.getETHBalance(tester.a1) == initialMakerETH - makerCost
    assert contractsFixture.utils.getETHBalance(tester.a2) == initialTakerETH - takerCost
    assert ordersFetcher.getOrder(orderID) == [0, 0, longToHexString(0), 0, 0, longTo32Bytes(0), longTo32Bytes(0), 0]
    assert fillOrderID == 0
