/**
 * =============================================================================
 * Class Name    : QuoteCloneController_CCTest
 * Description   : Test class for QuoteCloneController_CC.
 *
 * Author        : Nipun Jain
 * Created Date  : Oct 2026
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Provides unit test coverage for Quote cloning functionality, including
 * Quote Line Item cloning and validation scenarios.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

@IsTest
private class QuoteCloneController_CCTest {

    @testSetup
    static void setupData() {
        Id entityId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Entity').getRecordTypeId();
        Id siteId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Site').getRecordTypeId();

        Account acc = new Account(
            Name = 'Test Account',
            RecordTypeId = entityId,
            BillingStreet = '123 Test Street',
            BillingCity = 'Test City',
            BillingState = 'Test State',
            BillingPostalCode = '12345',
            BillingCountry = 'United States'
        );
        insert acc;

        Account site = new Account(
            Name = 'Site',
            ParentId = acc.Id,
            RecordTypeId = siteId,
            ShippingStreet = '123 Test Street',
            ShippingCity = 'Test City',
            ShippingState = 'Test State',
            ShippingPostalCode = '12345',
            ShippingCountry = 'United States'
        );
        insert site;

        RecordType oppRecordType = [SELECT Id FROM RecordType WHERE SObjectType = 'Opportunity' AND DeveloperName = 'New_Business' LIMIT 1];

        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            RecordTypeId = oppRecordType.Id
        );
        insert opp;

        Opportunity_Site__c primarySite = new Opportunity_Site__c(
            Opportunity__c = opp.Id,
            Site__c = site.Id,
            Primary__c = true
        );
        insert primarySite;

        Id standardPricebookId = Test.getStandardPricebookId();

        Product2 product = new Product2(
            Name = 'Test Product',
            IsActive = true
        );
        insert product;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pbe;

        Quote quote = new Quote(
            Name = 'Test Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = standardPricebookId,
            Status = 'Draft'
        );
        insert quote;

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = quote.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 2,
            UnitPrice = 100
        );
        insert qli;
    }

    @IsTest
    static void testCloneQuote() {
        Quote originalQuote = [SELECT Id, Name, OpportunityId FROM Quote WHERE Name = 'Test Quote' LIMIT 1];
        Integer originalLineCount = [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :originalQuote.Id];

        Test.startTest();
        Id clonedQuoteId = QuoteCloneController_CC.cloneQuote(originalQuote.Id);
        Test.stopTest();

        Quote clonedQuote = [SELECT Id, Name, OpportunityId, Status FROM Quote WHERE Id = :clonedQuoteId];

        System.assertNotEquals(originalQuote.Id, clonedQuote.Id, 'A new Quote should be created.');
        System.assertEquals(originalQuote.Name + ' - Copy', clonedQuote.Name, 'Cloned Quote name is incorrect.');
        System.assertEquals('Draft', clonedQuote.Status, 'Cloned Quote should be Draft.');
        System.assertEquals(originalQuote.OpportunityId, clonedQuote.OpportunityId, 'Cloned Quote should belong to the same Opportunity.');

        Integer clonedLineCount = [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :clonedQuoteId];
        System.assertEquals(originalLineCount, clonedLineCount, 'Quote Line Items should also be cloned.');
    }

    @IsTest
    static void testCloneQuoteWhenAcceptedQuoteExists() {
        Quote originalQuote = [SELECT Id, OpportunityId, Pricebook2Id FROM Quote WHERE Name = 'Test Quote' LIMIT 1];

        Quote acceptedQuote = new Quote(
            Name = 'Accepted Quote',
            OpportunityId = originalQuote.OpportunityId,
            Pricebook2Id = originalQuote.Pricebook2Id,
            Status = 'Accepted'
        );
        insert acceptedQuote;

        Test.startTest();

        try {
            QuoteCloneController_CC.cloneQuote(originalQuote.Id);
            System.assert(false, 'Expected AuraHandledException when Accepted Quote exists.');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e, 'Expected AuraHandledException.');
        }

        Test.stopTest();

        Integer quoteCount = [SELECT COUNT() FROM Quote WHERE OpportunityId = :originalQuote.OpportunityId];
        System.assertEquals(2, quoteCount, 'No additional Quote should be created.');
    }
}