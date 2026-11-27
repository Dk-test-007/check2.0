/**
 * =============================================================================
 * Class Name    : QuoteTriggerHandler_CCTest
 * Description   : Unit test class for QuoteTriggerHandler. Covers Quote
 *                 creation scenarios with and without a Primary Opportunity Site.
 *
 * Author        : Nipun Jain
 * Created Date  : Sept 2026
 * =============================================================================
 */

@IsTest
private class QuoteTriggerHandler_CCTest {

    @TestSetup
    static void setupData() {
        Id entityId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Entity').getRecordTypeId();
        Id siteId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Site').getRecordTypeId();

        Account entity = new Account(
            Name = 'Entity',
            RecordTypeId = entityId,
            BillingStreet = '123 Test Street',
            BillingCity = 'Test City',
            BillingState = 'New York',
            BillingPostalCode = '12345',
            BillingCountry = 'United States'

        );
        insert entity;

        Account site = new Account(
            Name = 'Site',
            ParentId = entity.Id,
            RecordTypeId = siteId,
            ShippingStreet = '123 Test Street',
            ShippingCity = 'Test City',
            ShippingState = 'New York',
            ShippingPostalCode = '12345',
            ShippingCountry = 'United States'
        );
        insert site;

        Account siteWithoutAddress = new Account(
            Name = 'Site Without Address',
            ParentId = entity.Id,
            RecordTypeId = siteId
        );
        insert siteWithoutAddress;

        // Entity without a billing address (with a valid Site). All Sites are created here because Sites
        // created inside test methods reuse auto-numbers already taken in setup (unique Site_Code_CC__c).
        Account entityWithoutBilling = new Account(Name = 'Entity No Billing', RecordTypeId = entityId);
        insert entityWithoutBilling;
        Account siteForNoBilling = new Account(
            Name = 'Site For No Billing',
            ParentId = entityWithoutBilling.Id,
            RecordTypeId = siteId,
            ShippingStreet = '123 Test Street',
            ShippingCity = 'Test City',
            ShippingState = 'New York',
            ShippingPostalCode = '12345',
            ShippingCountry = 'United States'
        );
        insert siteForNoBilling;

        Opportunity oppWithPrimarySite = new Opportunity(
            Name = 'Opportunity With Primary Site',
            AccountId = entity.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert oppWithPrimarySite;

        Opportunity oppWithoutPrimarySite = new Opportunity(
            Name = 'Opportunity Without Primary Site',
            AccountId = entity.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert oppWithoutPrimarySite;

        Opportunity_Site__c primarySite = new Opportunity_Site__c(
            Opportunity__c = oppWithPrimarySite.Id,
            Site__c = site.Id,
            Primary__c = true
        );
        insert primarySite;
    }

    @IsTest
    static void testQuoteInsertWithPrimarySite() {
        Opportunity opp = [
            SELECT Id
            FROM Opportunity
            WHERE Name = 'Opportunity With Primary Site'
            LIMIT 1
        ];

        Test.startTest();

        Quote quote = new Quote(
            Name = 'Quote With Primary Site',
            OpportunityId = opp.Id
        );

        insert quote;

        Test.stopTest();

        Quote insertedQuote = [
            SELECT ShippingStreet,
                   ShippingCity,
                   ShippingState,
                   ShippingPostalCode,
                   ShippingCountry
            FROM Quote
            WHERE Id = :quote.Id
        ];

        System.assertEquals('123 Test Street', insertedQuote.ShippingStreet);
        System.assertEquals('Test City', insertedQuote.ShippingCity);
        System.assertEquals('New York', insertedQuote.ShippingState);
        System.assertEquals('12345', insertedQuote.ShippingPostalCode);
        System.assertEquals('United States', insertedQuote.ShippingCountry);
    }

    @IsTest
    static void testQuoteInsertWithoutPrimarySite() {
        Opportunity opp = [
            SELECT Id
            FROM Opportunity
            WHERE Name = 'Opportunity Without Primary Site'
            LIMIT 1
        ];

        Quote quote = new Quote(
            Name = 'Quote Without Primary Site',
            OpportunityId = opp.Id
        );

        Test.startTest();

        Database.SaveResult result = Database.insert(quote, false);

        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'A Quote may be drafted before its primary Site is selected');
        Id insertedId = result.getId();
        Assert.isNull([SELECT Ship_to_Site_CC__c FROM Quote WHERE Id = :insertedId WITH SYSTEM_MODE].Ship_to_Site_CC__c);
    }

    // -------------------------------------------------------------------------
    // Added during 2026-10 coverage remediation
    // -------------------------------------------------------------------------

    private static Opportunity primarySiteOpportunity() {
        return [SELECT Id FROM Opportunity WHERE Name = 'Opportunity With Primary Site' LIMIT 1];
    }

    /**
     * Verifies a draft Quote can be created before the Entity billing address is complete.
     */
    @IsTest
    static void testQuoteInsertWithoutBillingAddress() {
        Account entityWithoutBilling = [SELECT Id FROM Account WHERE Name = 'Entity No Billing' LIMIT 1];
        Account site = [SELECT Id FROM Account WHERE Name = 'Site For No Billing' LIMIT 1];
        Opportunity opp = TestDataFactory_CC.createOpportunity(entityWithoutBilling.Id, 'New_Business', true);
        TestDataFactory_CC.createOpportunitySite(opp.Id, site.Id, true, true);

        Test.startTest();
        Database.SaveResult result = Database.insert(TestDataFactory_CC.createQuote(opp.Id, false), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'A draft Quote can be created without an Entity billing address');
        Id insertedId = result.getId();
        Assert.isNull([SELECT BillingStreet FROM Quote WHERE Id = :insertedId].BillingStreet);
    }

    /**
     * Verifies a draft Quote can be created before the primary Site shipping address is complete.
     */
    @IsTest
    static void testQuoteInsertWithoutShippingAddress() {
        Account entity = [SELECT Id FROM Account WHERE Name = 'Entity' LIMIT 1];
        Account siteWithoutAddress = [SELECT Id FROM Account WHERE Name = 'Site Without Address' LIMIT 1];
        Opportunity opp = TestDataFactory_CC.createOpportunity(entity.Id, 'New_Business', true);
        TestDataFactory_CC.createOpportunitySite(opp.Id, siteWithoutAddress.Id, true, true);

        Test.startTest();
        Database.SaveResult result = Database.insert(TestDataFactory_CC.createQuote(opp.Id, false), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'A draft Quote can be created without a Site shipping address');
        Id insertedId = result.getId();
        Assert.isNull([SELECT ShippingStreet FROM Quote WHERE Id = :insertedId].ShippingStreet);
    }

    /**
     * Verifies inserting a second Quote makes it the Latest Quote and clears the flag on the previous one.
     */
    @IsTest
    static void testNewQuoteBecomesLatest() {
        Opportunity opp = primarySiteOpportunity();
        Quote first = TestDataFactory_CC.createQuote(opp.Id, true);

        Test.startTest();
        Quote second = TestDataFactory_CC.createQuote(opp.Id, true);
        Test.stopTest();

        Map<Id, Quote> quotes = new Map<Id, Quote>([SELECT Id, Latest_Quote__c FROM Quote WHERE OpportunityId = :opp.Id]);
        Assert.isFalse(quotes.get(first.Id).Latest_Quote__c, 'The previous Quote should no longer be the Latest Quote');
        Assert.isTrue(quotes.get(second.Id).Latest_Quote__c, 'The newly inserted Quote should be the Latest Quote');
    }

    /**
     * Verifies a Quote cannot be manually flagged Latest when another Latest Quote exists on the Opportunity.
     */
    @IsTest
    static void testSecondLatestQuoteIsBlocked() {
        Opportunity opp = primarySiteOpportunity();
        Quote first = TestDataFactory_CC.createQuote(opp.Id, true);
        TestDataFactory_CC.createQuote(opp.Id, true);   // becomes Latest, first is cleared

        Test.startTest();
        Database.SaveResult result = Database.update(new Quote(Id = first.Id, Latest_Quote__c = true), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Flagging a second Latest Quote should fail');
        Assert.areEqual('A Latest Quote already exists for this Opportunity.',
            result.getErrors()[0].getMessage(), 'Latest Quote conflict error expected');
    }

    /**
     * Verifies status transitions stamp Start/Expiration dates (Presented), Accepted date and Cancelled date,
     * and that changing the validity period recalculates the expiration date.
     */
    @IsTest
    static void testStatusTransitionsStampDates() {
        Quote qt = TestDataFactory_CC.createQuote(primarySiteOpportunity().Id, true);
        Quote acceptedQt = TestDataFactory_CC.createQuote(primarySiteOpportunity().Id, true);

        Test.startTest();
        update new Quote(Id = qt.Id, Status = 'Presented');
        Quote presented = [SELECT StartDate, Validity_Period_Days__c, ExpirationDate FROM Quote WHERE Id = :qt.Id];

        update new Quote(Id = qt.Id, Validity_Period_Days__c = 10);
        Quote revalidated = [SELECT ExpirationDate FROM Quote WHERE Id = :qt.Id];

        update new Quote(Id = qt.Id, Status = 'Cancelled');
        update new Quote(Id = acceptedQt.Id, Status = 'Accepted');
        Test.stopTest();

        Assert.areEqual(Date.today(), presented.StartDate, 'Presented should stamp the start date');
        Assert.areEqual(30, presented.Validity_Period_Days__c, 'Validity should default to 30 days');
        Assert.areEqual(Date.today().addDays(30), presented.ExpirationDate, 'Expiration should be start + validity');
        Assert.areEqual(Date.today().addDays(10), revalidated.ExpirationDate, 'Expiration should follow the new validity period');
        Assert.areEqual(Date.today(), [SELECT Cancelled_Date__c FROM Quote WHERE Id = :qt.Id].Cancelled_Date__c,
            'Cancelled should stamp the cancelled date');
        Assert.areEqual(Date.today(), [SELECT Quote_Accepted_Date__c FROM Quote WHERE Id = :acceptedQt.Id].Quote_Accepted_Date__c,
            'Accepted should stamp the accepted date');
    }

    /**
     * Verifies a New Business Opportunity with an Accepted Quote cannot receive another Quote.
     */
    @IsTest
    static void testAcceptedQuoteBlocksNewQuoteOnNewBusiness() {
        Account entity = [SELECT Id FROM Account WHERE Name = 'Entity' LIMIT 1];
        Account site = [SELECT Id FROM Account WHERE Name = 'Site' LIMIT 1];
        Opportunity opp = TestDataFactory_CC.createOpportunity(entity.Id, 'New_Business', true);
        TestDataFactory_CC.createOpportunitySite(opp.Id, site.Id, true, true);
        Quote accepted = TestDataFactory_CC.createQuote(opp.Id, true);
        update new Quote(Id = accepted.Id, Status = 'Accepted');

        Test.startTest();
        Database.SaveResult result = Database.insert(TestDataFactory_CC.createQuote(opp.Id, false), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'A second Quote should be blocked once one is Accepted');
        Assert.areEqual('An Accepted Quote already exists for this Opportunity',
            result.getErrors()[0].getMessage(), 'Accepted Quote error expected');
    }

    /**
     * Verifies a bulk insert of 200 Quotes succeeds and copies billing/shipping addresses to every Quote.
     */
    @IsTest
    static void testBulkQuoteInsertCopiesAddresses() {
        Id oppId = primarySiteOpportunity().Id;
        List<Quote> quotes = new List<Quote>();
        for (Integer i = 0; i < 200; i++) {
            quotes.add(TestDataFactory_CC.createQuote(oppId, false));
        }

        Test.startTest();
        insert quotes;
        Test.stopTest();

        Integer withAddresses = [SELECT COUNT() FROM Quote
                                 WHERE OpportunityId = :oppId AND ShippingCity = 'Test City' AND BillingCity = 'Test City'];
        Assert.areEqual(200, withAddresses, 'Every bulk-inserted Quote should receive billing and shipping addresses');
    }
}