/**
 * Tests for LeadOutcomeBannerController_CC. Field history rows are not written in Apex tests, so the query path
 * is tested for "not recorded" and the matching rule is tested directly.
 */
@isTest
private class LeadOutcomeBannerController_CC_Test {

    @isTest
    static void noRecordedHistory_ReturnsNullRatherThanAGuess() {
        Lead leadRecord = new Lead(LastName = 'Banner', Company = 'Banner Co', Status = 'Qualify',
            City = 'Chicago', PostalCode = '60601', CountryCode = 'US');
        insert leadRecord;

        Test.startTest();
        Datetime since = LeadOutcomeBannerController_CC.getStatusSince(leadRecord.Id, 'Qualify', '2026-10-29T10:00:00.000Z');
        Test.stopTest();

        Assert.isNull(since, 'Without a history row the banner must show no date');
    }

    @isTest
    static void missingInputs_ReturnNull() {
        Assert.isNull(LeadOutcomeBannerController_CC.getStatusSince(null, 'Disqualified', null), 'No Lead, no date');
        Assert.isNull(LeadOutcomeBannerController_CC.getStatusSince(UserInfo.getUserId(), ' ', null), 'No Status, no date');
    }

    @isTest
    static void latestChange_CountsOnlyWhenItIsToTheShownStatus() {
        Datetime changedAt = Datetime.newInstanceGmt(2026, 10, 28, 9, 0, 0);
        Assert.areEqual(changedAt, LeadOutcomeBannerController_CC.sinceIfMatching('Disqualified', changedAt, 'Disqualified'),
            'Matching latest change gives its date');
        Assert.isNull(LeadOutcomeBannerController_CC.sinceIfMatching('Engage', changedAt, 'Disqualified'),
            'A later change to another Status must not be shown as the outcome date');
        Assert.isNull(LeadOutcomeBannerController_CC.sinceIfMatching(null, changedAt, 'Re-Nurture'), 'Blank value gives no date');
    }
}