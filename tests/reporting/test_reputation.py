from ethereum.tools import tester

def test_decimals(contractsFixture):
    reputationTokenFactory = contractsFixture.contracts['ReputationTokenFactory']
    assert reputationTokenFactory
    reputationTokenAddress = reputationTokenFactory.createReputationToken(contractsFixture.controller.address, contractsFixture.branch.address)
    reputationToken = contractsFixture.applySignature('ReputationToken', reputationTokenAddress)

    assert reputationToken.decimals() == 18

def test_redeem_legacy_rep(contractsFixture):
    branch = contractsFixture.branch
    reputationToken = contractsFixture.applySignature('ReputationToken', branch.getReputationToken())
    legacyRepContract = contractsFixture.contracts['LegacyRepContract']
    legacyRepContract.faucet(long(11 * 10**6 * 10**18))
    legacyRepContract.approve(reputationToken.address, 11 * 10**6 * 10**18)
    reputationToken.migrateFromLegacyRepContract()
    balance = reputationToken.balanceOf(tester.a0)

    assert balance == 11 * 10**6 * 10**18
