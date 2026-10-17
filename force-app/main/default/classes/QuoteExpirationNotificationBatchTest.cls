@IsTest
private class QuoteExpirationNotificationBatchTest {

    @TestSetup
    static void setupData() {
        Profile profile = [
            SELECT Id
            FROM Profile
            WHERE Name = 'Standard User'
            LIMIT 1
        ];

        User testUser = new User(
            FirstName = 'Test',
            LastName = 'Quote Owner',
            Alias = 'qowner',
            Email = 'quote.owner@test.com',
            Username = 'quote.owner.' + DateTime.now().getTime() + '@test.com',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'Asia/Kolkata',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert testUser;

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

        Quote reminderQuote = new Quote(
            Name = 'Reminder Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            ExpirationDate = Date.today().addDays(7),
            OwnerId = testUser.Id
        );

        Quote expiredQuote = new Quote(
            Name = 'Expired Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            ExpirationDate = Date.today().addDays(-1),
            OwnerId = testUser.Id
        );

        insert new List<Quote>{
            reminderQuote,
            expiredQuote
        };
    }

    @IsTest
    static void testBatchExecution() {
        List<Quote> quotes = [
            SELECT Id, QuoteNumber, Account.Name, OwnerId, Owner.Email, ExpirationDate, Status
            FROM Quote
        ];

        System.assertEquals(
            2,
            quotes.size(),
            'Two test quotes should exist.'
        );

        System.assertEquals(
            'quote.owner@test.com',
            quotes[0].Owner.Email,
            'Quotes should be owned by the test user.'
        );

        Test.startTest();

        Database.executeBatch(
            new QuoteExpirationNotificationBatch(),
            200
        );

        Test.stopTest();

        Quote expiredQuote = [
            SELECT Id, Status, ExpirationDate
            FROM Quote
            WHERE ExpirationDate = :Date.today().addDays(-1)
            LIMIT 1
        ];

        System.assertEquals(
            'Expired',
            expiredQuote.Status,
            'Quote with an expiration date of yesterday should be marked as Expired.'
        );
    }

    @IsTest
    static void testStartMethod() {
        QuoteExpirationNotificationBatch batch =
            new QuoteExpirationNotificationBatch();

        Test.startTest();

        Database.QueryLocator queryLocator = batch.start(null);

        Test.stopTest();

        System.assertNotEquals(
            null,
            queryLocator,
            'The start method should return a QueryLocator.'
        );
    }

    @IsTest
    static void testSchedulableExecute() {
        Test.startTest();

        String jobId = System.schedule(
            'Quote Expiration Notification Test',
            '0 0 12 * * ?',
            new QuoteExpirationNotificationBatch()
        );

        Test.stopTest();

        System.assertNotEquals(
            null,
            jobId,
            'The scheduled job should be created successfully.'
        );
    }

    @IsTest
    static void testFinish() {
        QuoteExpirationNotificationBatch batch =
            new QuoteExpirationNotificationBatch();

        Test.startTest();

        batch.finish(null);

        Test.stopTest();

        System.assert(true, 'Finish method should execute without errors.');
    }
}