#!/usr/bin/env python

from ethereum.tools import tester
from ethereum.tools.tester import TransactionFailed
from pytest import fixture, mark, lazy_fixture, raises
from ethereum.config import config_metropolis

#config_metropolis['BLOCK_GAS_LIMIT'] = 2**128
 
@fixture(scope="session")
def sortedLinkedListSnapshot(sessionFixture):
    int256Comparor = sessionFixture.upload('../src/libraries/ComparorUint256.sol')
    sortedLinkedList = sessionFixture.upload('../src/libraries/SortedLinkedListUint256.sol')
    sortedLinkedList.initialize(int256Comparor.address)
    return sessionFixture.chain.snapshot()

@fixture
def sortedLinkedListContractsFixture(sessionFixture, sortedLinkedListSnapshot):
    sessionFixture.chain.revert(sortedLinkedListSnapshot)
    return sessionFixture

#def test_helperComparor(sortedLinkedListContractsFixture):
#
#    int256Comparor = sortedLinkedListContractsFixture.contracts['int256Comparor']
#
#    assert int256Comparor.compare(1, 1) == 0
#    assert int256Comparor.compare(0, 1) == -1
#    assert int256Comparor.compare(1, 0) == 1

def test_sortedLinkedListInitialState(sortedLinkedListContractsFixture):

    sortedLinkedList = sortedLinkedListContractsFixture.contracts['SortedLinkedListUint256']

    # The list is empty initially
    assert sortedLinkedList.isEmpty()
    assert sortedLinkedList.getCount() == 0

    # The list is empty. Attempts to get items fail
    with raises(TransactionFailed):
        assert sortedLinkedList.getHead()
    with raises(TransactionFailed):
        assert sortedLinkedList.getTail()

def test_sortedLinkedListRequireNotZero(sortedLinkedListContractsFixture):

    sortedLinkedList = sortedLinkedListContractsFixture.contracts['SortedLinkedListUint256']

    # we don't allow adding 0
    with raises(TransactionFailed):
        sortedLinkedList.add(0)

def test_sortedLinkedListAddOneItem(sortedLinkedListContractsFixture):

    sortedLinkedList = sortedLinkedListContractsFixture.contracts['SortedLinkedListUint256']

    # We can add an item
    assert sortedLinkedList.add(42)
    assert sortedLinkedList.getCount() == 1

    # Adding the same item just removes the item and places it again.
    assert sortedLinkedList.add(42)

    # head and tail are the same node with 1 item
    assert sortedLinkedList.getHead() == 42
    assert sortedLinkedList.getTail() == 42

def test_sortedLinkedListMakeEmpty(sortedLinkedListContractsFixture):

    sortedLinkedList = sortedLinkedListContractsFixture.contracts['SortedLinkedListUint256']

    # We can add an item then remove it
    assert sortedLinkedList.add(42)
    assert sortedLinkedList.remove(42)

    # If we try to remove again we get back a failure value
    assert not sortedLinkedList.remove(42)

    assert sortedLinkedList.getCount() == 0

    # The list is empty. Attempts to get items fail
    with raises(TransactionFailed):
        assert sortedLinkedList.getHead()
    with raises(TransactionFailed):
        assert sortedLinkedList.getTail()

def test_sortedLinkedListAddTwoItems(sortedLinkedListContractsFixture):

    sortedLinkedList = sortedLinkedListContractsFixture.contracts['SortedLinkedListUint256']

    # We can add multiple items
    assert sortedLinkedList.add(42)
    assert sortedLinkedList.add(43)

    assert sortedLinkedList.getCount() == 2

    # Head and tail point to two different nodes
    assert sortedLinkedList.getHead() == 43
    assert sortedLinkedList.getTail() == 42

    # We can get the prev node value for an item
    assert sortedLinkedList.getPrev(43) == 42

    # We can get the next node value for an item
    assert sortedLinkedList.getNext(42) == 43

    # Validate order
    doOrderValidation(sortedLinkedList)

    # We can remove a specific item by value and the other remains
    assert sortedLinkedList.remove(42)
    assert sortedLinkedList.getCount() == 1

    assert sortedLinkedList.getTail() == 43
    assert sortedLinkedList.getHead() == 43

    # Validate order
    doOrderValidation(sortedLinkedList)

def test_sortedLinkedListAddMultipleItems(sortedLinkedListContractsFixture):

    sortedLinkedList = sortedLinkedListContractsFixture.contracts['SortedLinkedListUint256']

    # Let's add many items and confirm the behavior is as expected
    assert sortedLinkedList.add(42)
    assert sortedLinkedList.add(41)
    assert sortedLinkedList.add(43)

    assert sortedLinkedList.getCount() == 3

    assert sortedLinkedList.getHead() == 43
    assert sortedLinkedList.getTail() == 41

    assert sortedLinkedList.getNext(42) == 43
    assert sortedLinkedList.getPrev(42) == 41

    assert sortedLinkedList.getNext(41) == 42
    assert sortedLinkedList.getPrev(43) == 42

    assert sortedLinkedList.hasNext(43) == 0
    assert sortedLinkedList.hasPrev(41) == 0

    # Add to the ends and inbetween
    assert sortedLinkedList.add(45)
    assert sortedLinkedList.add(35)
    assert sortedLinkedList.add(40)

    # Validate order
    doOrderValidation(sortedLinkedList)

    assert sortedLinkedList.getPrev(45) == 43
    assert sortedLinkedList.getNext(35) == 40
    assert sortedLinkedList.getNext(40) == 41
    assert sortedLinkedList.getPrev(41) == 40

    assert sortedLinkedList.getTail() == 35
    assert sortedLinkedList.getHead() == 45

    assert sortedLinkedList.getCount() == 6

    # Validate order
    doOrderValidation(sortedLinkedList)

    # Remove an inbetween
    assert sortedLinkedList.remove(42)
    assert sortedLinkedList.getPrev(43) == 41
    assert sortedLinkedList.getNext(41) == 43

    # Validate order
    doOrderValidation(sortedLinkedList)

    # Remove ends
    assert sortedLinkedList.remove(35)
    assert sortedLinkedList.getTail() == 40
    assert sortedLinkedList.hasPrev(40) == 0

    # Validate order
    doOrderValidation(sortedLinkedList)

    assert sortedLinkedList.remove(45)
    assert sortedLinkedList.getHead() == 43
    assert sortedLinkedList.hasNext(43) == 0

    # Validate order
    doOrderValidation(sortedLinkedList)

def test_sortedLinkedListHints(sortedLinkedListContractsFixture):

    sortedLinkedList = sortedLinkedListContractsFixture.contracts['SortedLinkedListUint256']

    # Add two to start
    assert sortedLinkedList.add(35)
    assert sortedLinkedList.add(40)

    # We can provide hints to optimize node ordering during insertion
    # note that the optimization itself is not tested here. We're merely
    # doing code coverage
    assert sortedLinkedList.add(36, [40])

    assert sortedLinkedList.getCount() == 3
    assert sortedLinkedList.getNext(35) == 36

    # nothing bad happens if we provide invalid hints
    assert sortedLinkedList.contains(38) == 0
    assert sortedLinkedList.add(37, [38])

    assert sortedLinkedList.getCount() == 4
    assert sortedLinkedList.getNext(36) == 37

def test_sortedLinkedListMultipleHints(sortedLinkedListContractsFixture):

    sortedLinkedList = sortedLinkedListContractsFixture.contracts['SortedLinkedListUint256']

    # Add some elements to start
    assert sortedLinkedList.add(3)
    assert sortedLinkedList.add(5)
    assert sortedLinkedList.add(10)

    # We can provide multiple hints
    assert sortedLinkedList.add(2, [11,5,1])

def test_sortedLinkedListTryFunctions(sortedLinkedListContractsFixture):

    sortedLinkedList = sortedLinkedListContractsFixture.contracts['SortedLinkedListUint256']

    # Add some elements to start
    assert sortedLinkedList.add(3)
    assert sortedLinkedList.add(5)
    assert sortedLinkedList.add(10)

    # We provide "try" helper functions to safely get a prev or next node
    assert sortedLinkedList.tryGetNext(5) == 10
    assert sortedLinkedList.tryGetPrev(5) == 3

    # They return 0 when no requested node exists
    assert sortedLinkedList.tryGetNext(10) == 0
    assert sortedLinkedList.tryGetPrev(3) == 0

    # They raise an exception when we make an invalid request
    with raises(TransactionFailed):
        sortedLinkedList.tryGetNext(11)
    with raises(TransactionFailed):
        sortedLinkedList.tryGetPrev(11)

def doOrderValidation(sortedLinkedList):
    # Ordered backward
    val = sortedLinkedList.getHead()
    while (sortedLinkedList.hasPrev(val)):
        newVal = sortedLinkedList.getPrev(val)
        assert newVal < val
        val = newVal

    # Ordered forward
    val = sortedLinkedList.getTail()
    while (sortedLinkedList.hasNext(val)):
        newVal = sortedLinkedList.getNext(val)
        assert newVal > val
        val = newVal
