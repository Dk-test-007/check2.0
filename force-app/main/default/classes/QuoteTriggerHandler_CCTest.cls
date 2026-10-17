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
            BillingState = 'Test State',
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
            ShippingState = 'Test State',
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
        System.assertEquals('Test State', insertedQuote.ShippingState);
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

        System.assertEquals(false, result.isSuccess());
        System.assertEquals(
            'A Primary Site needs to be added to the Opportunity for creating Quote',
            result.getErrors()[0].getMessage()
        );
    }
}