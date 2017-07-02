#!/usr/bin/env python

# Test the functions in src/functions/controller.se
# Uses tests/controller_test.se as a helper (to set the controller, etc.)

from ethereum import tester
from ethereum.tester import TransactionFailed
from os import path
from pytest import raises, fixture
from utils import bytesToLong

def test_whitelists(controller):
    assert controller.assertIsWhitelisted(tester.a0, sender = tester.k2)
    with raises(TransactionFailed): controller.addToWhitelist(tester.a1, sender = tester.k1)
    with raises(TransactionFailed): controller.addToWhitelist(tester.a1, sender = tester.k2)
    assert controller.addToWhitelist(tester.a1, sender = tester.k0)
    assert controller.assertIsWhitelisted(tester.a1, sender = tester.k2)
    with raises(TransactionFailed): controller.assertIsWhitelisted(tester.a2, sender = tester.k2)
    with raises(TransactionFailed): controller.removeFromWhitelist(tester.a1, sender = tester.k2)
    assert controller.removeFromWhitelist(tester.a1, sender = tester.k1)
    with raises(TransactionFailed): controller.assertIsWhitelisted(tester.a1, sender = tester.k0)

def test_registry(controller, decentralizedController):
    key1 = 'abc'.ljust(32, '\x00')
    key2 = 'foo'.ljust(32, '\x00')
    with raises(TransactionFailed): controller.setValue(key1, 123, sender = tester.k2)
    assert controller.lookup(key1, sender = tester.k2) == 0
    assert controller.addToWhitelist(tester.a1, sender = tester.k0)
    assert controller.setValue(key1, 123, sender = tester.k1)
    assert controller.lookup(key1, sender = tester.k2) == 123
    with raises(TransactionFailed): controller.assertOnlySpecifiedCaller(tester.a1, key2, sender = tester.k2)
    assert controller.setValue(key2, tester.a1, sender = tester.k0)
    assert controller.assertOnlySpecifiedCaller(tester.a1, key2, sender = tester.k2)
    # dev mode special
    assert controller.assertOnlySpecifiedCaller(tester.a1, key2, sender = tester.k0)
    with raises(TransactionFailed): decentralizedController.assertOnlySpecifiedCaller(tester.a2, key2, sender = tester.k0)
    with raises(TransactionFailed): controller.assertOnlySpecifiedCaller(tester.a2, key2, sender = tester.k2)

def test_suicide(controller, decentralizedController, controllerUser):
    with raises(TransactionFailed): controller.suicide(controllerUser.address, tester.a0, sender = tester.k2)
    with raises(TransactionFailed): decentralizedController.suicide(controllerUser.address, tester.a0, sender = tester.k0)
    assert controller.suicide(controllerUser.address, tester.a0, sender = tester.k0)
    assert controllerUser.getSuicideFundsDestination() == bytesToLong(tester.a0)

def test_updateController(controller, decentralizedController, controllerUser):
    with raises(TransactionFailed): controller.updateController(controllerUser.address, tester.a0, sender = tester.k2)
    with raises(TransactionFailed): decentralizedController.updateController(controllerUser.address, tester.a0, sender = tester.k0)
    assert controller.updateController(controllerUser.address, tester.a0, sender = tester.k0)
    assert controllerUser.getUpdatedController() == bytesToLong(tester.a0)

def test_transferOwnership(controller, decentralizedController):
    with raises(TransactionFailed): controller.transferOwnership(tester.a1, sender = tester.k2)
    assert controller.transferOwnership(tester.a1, sender = tester.k0)
    with raises(TransactionFailed): controller.assertIsWhitelisted(tester.a0, sender = tester.k2)
    assert controller.assertIsWhitelisted(tester.a1, sender = tester.k2)
    assert controller.getOwner() == bytesToLong(tester.a1)

    assert decentralizedController.transferOwnership(tester.a1, sender = tester.k0)
    with raises(TransactionFailed): decentralizedController.assertIsWhitelisted(tester.a0, sender = tester.k2)
    with raises(TransactionFailed): decentralizedController.assertIsWhitelisted(tester.a1, sender = tester.k2)
    assert decentralizedController.getOwner() == bytesToLong(tester.a1)

def test_emergencyStop(controller):
    with raises(TransactionFailed): controller.emergencyStop(sender = tester.k2)
    with raises(TransactionFailed): controller.release(sender = tester.k2)
    assert controller.stopInEmergency(sender = tester.k2)
    with raises(TransactionFailed): controller.onlyInEmergency(sender = tester.k2)
    assert controller.emergencyStop(sender = tester.k0)
    assert controller.onlyInEmergency(sender = tester.k2)
    with raises(TransactionFailed): controller.stopInEmergency(sender = tester.k2)
    assert controller.release(sender = tester.k0)
    assert controller.stopInEmergency(sender = tester.k2)
    with raises(TransactionFailed): controller.onlyInEmergency(sender = tester.k2)

def test_switchModeSoOnlyEmergencyStopsAndEscapeHatchesCanBeUsed_failures(controller):
    with raises(TransactionFailed): controller.switchModeSoOnlyEmergencyStopsAndEscapeHatchesCanBeUsed(sender = tester.k2)

class Fixture:
    def __init__(self):
        THIS_FILE_DIRECTORY_PATH = path.dirname(path.realpath(__file__))
        self.state = tester.state()
        self.controller = self.state.abi_contract(path.join(THIS_FILE_DIRECTORY_PATH, "../src/controller.se"))
        self.decentralizedController = self.state.abi_contract(path.join(THIS_FILE_DIRECTORY_PATH, "../src/controller.se"))
        self.controllerUser = self.state.abi_contract(path.join(THIS_FILE_DIRECTORY_PATH, "serpent_test_helpers/controllerUser.se"))
        self.decentralizedController.switchModeSoOnlyEmergencyStopsAndEscapeHatchesCanBeUsed(sender = tester.k0)
        self.state.mine(1)
        self.snapshot = self.state.snapshot()

@fixture(scope="session")
def sessionFixture():
    return Fixture()

@fixture
def localFixture(sessionFixture):
    sessionFixture.state.revert(sessionFixture.snapshot)
    return sessionFixture

@fixture
def controller(localFixture):
    return localFixture.controller

@fixture
def controllerUser(localFixture):
    return localFixture.controllerUser

@fixture
def decentralizedController(localFixture):
    return localFixture.decentralizedController
