@isTest
private class QuotePdfServiceTest {
    @isTest
    static void savesPdfToQuote() {
        Id entityId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Entity').getRecordTypeId();
        Id siteId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Site').getRecordTypeId();

        Account entity = new Account(
            Name = 'Entity',
            RecordTypeId = entityId
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

        Opportunity opp = new Opportunity(
            Name = 'Test Opp', AccountId = entity.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30)
        );
        insert opp;
        
        Opportunity_Site__c primarySite = new Opportunity_Site__c(
            Opportunity__c = opp.Id,
            Site__c = site.Id,
            Primary__c = true
        );
        insert primarySite;

        Quote q = new Quote(Name = 'Test Quote', OpportunityId = opp.Id);
        insert q;

        Test.startTest();
        Id docId = QuotePdfService.saveToQuote(q.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'QuoteDocument should be created');
    }
}