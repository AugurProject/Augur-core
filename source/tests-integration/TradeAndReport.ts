// Create market, make a trade on it, designated reporter reports, market is finalized, traders settle shares, reporters redeem tokens.

import BN = require('bn.js');
import { expect } from "chai";
import { stringTo32ByteHex } from "../libraries/HelperFunctions";
import { TestFixture } from './TestFixture';
import { ReportingUtils } from './ReportingUtils';

describe("TradeAndReport", () => {
    let fixture: TestFixture;
    before(async () => {
        fixture = await TestFixture.create();
    });
    it("#tradeAndReport", async () => {
        await fixture.approveCentralAuthority();

        // Create a market
        const market = await fixture.createReasonableMarket(fixture.universe, fixture.cash.address, [stringTo32ByteHex(" "), stringTo32ByteHex(" ")]);
        const actualTypeName = await market.getTypeName_();
        const expectedTypeName = stringTo32ByteHex("Market");
        expect(actualTypeName).to.equal(expectedTypeName);

        // Place an order
        let type = new BN(0); // BID
        let outcome = new BN(0);
        let numShares = new BN(10000000000000);
        let price = new BN(2150);

        await fixture.placeOrder(market.address, type, numShares, price, outcome, stringTo32ByteHex(""), stringTo32ByteHex(""), stringTo32ByteHex("42"));

        const orderID = await fixture.getBestOrderId(type, market.address, outcome)

        const orderPrice = await fixture.getOrderPrice(orderID);
        expect(orderPrice.toNumber()).to.equal(price.toNumber());

        // Buy complete sets
        await fixture.buyCompleteSets(market, numShares);
        const numOwnedShares = await fixture.getNumSharesInMarket(market, outcome);
        expect(numOwnedShares.toNumber()).to.equal(numShares.toNumber());

        // Cancel the original rest of order
        await fixture.cancelOrder(orderID);
        const remainingAmount = await fixture.getOrderAmount(orderID);
        expect(remainingAmount.toNumber()).to.equal(0);

        // Proceed to reporting
        const reportingUtils = new ReportingUtils();
        await reportingUtils.proceedToFork(fixture, market);

        const isForking = await fixture.isForking();
        expect(isForking).to.be.true;

        const numTicks = await market.getNumTicks_();
        const reputationToken = await fixture.getReputationToken();
        const payoutDistributionHash = await fixture.derivePayoutDistributionHash(market, [numTicks, new BN(0)], false);
        const childUniverseReputationToken = await fixture.getChildUniverseReputationToken(payoutDistributionHash);
        const initialRepTotalMigrated = await childUniverseReputationToken.getTotalMigrated_();
        const repAmountToMigrate = new BN(9000000).mul(new BN(10).pow(new BN(18)));
        await fixture.migrateOutByPayout(reputationToken, [numTicks, new BN(0)], false, repAmountToMigrate);
        const finalRepTotalMigrated = await childUniverseReputationToken.getTotalMigrated_();
        expect(finalRepTotalMigrated.sub(initialRepTotalMigrated).toString(10)).to.equal(repAmountToMigrate.toString(10));

        let isFinalized = await market.isFinalized_();
        expect(isFinalized).to.be.true;
    });
});
