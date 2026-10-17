@IsTest
private class QuoteDuplicateLineItemController_CCTest {

    @TestSetup
    static void setupData() {
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

        Opportunity opportunity = new Opportunity(
            Name = 'Test Opportunity',
            AccountId = entity.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        
        Opportunity_Site__c primarySite = new Opportunity_Site__c(
            Opportunity__c = opportunity.Id,
            Site__c = site.Id,
            Primary__c = true
        );
        insert primarySite;


        Quote quote = new Quote(
            Name = 'Test Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert quote;

        Product2 productA = new Product2(
            Name = 'Product ABC',
            IsActive = true
        );

        Product2 productB = new Product2(
            Name = 'Product XYZ',
            IsActive = true
        );

        insert new List<Product2>{
            productA,
            productB
        };

        Id standardPricebookId = Test.getStandardPricebookId();

        List<PricebookEntry> pricebookEntries = new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = productA.Id,
                UnitPrice = 100,
                IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = productB.Id,
                UnitPrice = 200,
                IsActive = true
            )
        };

        insert pricebookEntries;

        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = pricebookEntries[0].Id,
                Quantity = 1,
                UnitPrice = 100
            ),
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = pricebookEntries[0].Id,
                Quantity = 2,
                UnitPrice = 100
            ),
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = pricebookEntries[1].Id,
                Quantity = 1,
                UnitPrice = 200
            )
        };
    }

    @IsTest
    static void testGetDuplicateProductNames() {
        Quote quote = [SELECT Id FROM Quote LIMIT 1];

        Test.startTest();

        List<String> duplicateProductNames = QuoteDuplicateLineItemController_CC.getDuplicateProductNames(quote.Id);

        Test.stopTest();

        System.assertEquals(1, duplicateProductNames.size(), 'Only one product should have duplicate Quote Line Items.');

        System.assertEquals('Product ABC', duplicateProductNames[0], 'Product ABC should be identified as a duplicate.');
    }

    @IsTest
    static void testNoDuplicateProducts() {
        Quote quote = [SELECT Id FROM Quote LIMIT 1];

        delete [SELECT Id FROM QuoteLineItem WHERE QuoteId = :quote.Id AND Product2.Name = 'Product ABC' LIMIT 1];
        Test.startTest();

        List<String> duplicateProductNames = QuoteDuplicateLineItemController_CC.getDuplicateProductNames(quote.Id);
        Boolean hasNegative = QuoteDuplicateLineItemController_CC.hasNegativeMargin(quote.Id);

        Test.stopTest();

        System.assertEquals( 0, duplicateProductNames.size(), 'There should be no duplicate products.');
    }

    @IsTest
    static void testNullQuoteId() {
        Test.startTest();

        List<String> duplicateProductNames = QuoteDuplicateLineItemController_CC.getDuplicateProductNames(null);

        Test.stopTest();

        System.assertEquals(0, duplicateProductNames.size(), 'Null Quote Id should return an empty list.');
    }
}