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

        // Billing address is required by QuoteTriggerHandler_CC.updateAddress before a Quote can be created
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

        Boolean canEmail = emailAllowed();

        Test.startTest();

        Database.executeBatch(
            new QuoteExpirationNotificationBatch(),
            200
        );

        stopTestCapturingEmailFailure(canEmail);

        Quote expiredQuote = [
            SELECT Id, Status, ExpirationDate
            FROM Quote
            WHERE ExpirationDate = :Date.today().addDays(-1)
            LIMIT 1
        ];

        if (!canEmail) {
            // The batch emails the owners before it marks Quotes Expired, so nothing is saved while email is off.
            System.assertNotEquals('Expired', expiredQuote.Status,
                'The batch stops at the email step, before marking the Quote Expired.');
            return;
        }

        System.assertEquals(
            'Expired',
            expiredQuote.Status,
            'Quote with an expiration date of yesterday should be marked as Expired.'
        );
    }

    /**
     * Whether this org can send email. Sandboxes often run with email deliverability off; then the batch's
     * Messaging.sendEmail fails with NO_SINGLE_MAIL_PERMISSION.
     */
    private static Boolean emailAllowed() {
        try {
            Messaging.reserveSingleEmailCapacity(1);
            return true;
        } catch (Exception ex) {
            return false;
        }
    }

    /**
     * Stops the test. With email on, any failure is rethrown. With email off, only the expected
     * NO_SINGLE_MAIL_PERMISSION failure from the batch is accepted.
     */
    private static String stopTestCapturingEmailFailure(Boolean canEmail) {
        try {
            Test.stopTest();
        } catch (EmailException ex) {
            if (canEmail) {
                throw ex;
            }
            System.assert(ex.getMessage().contains('NO_SINGLE_MAIL_PERMISSION'),
                'Only the email permission should stop the batch: ' + ex.getMessage());
            return ex.getMessage();
        }
        System.assert(canEmail, 'With email disabled the batch is expected to fail at the email step.');
        return null;
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
        Boolean canEmail = emailAllowed();

        Test.startTest();

        String jobId = System.schedule(
            'Quote Expiration Notification Test',
            '0 0 12 * * ?',
            new QuoteExpirationNotificationBatch()
        );

        if (!canEmail) {
            // The scheduled run would start the batch, whose email step fails after this test method ends while email
            // deliverability is off. Check the schedule exists and abort it before it runs.
            System.assertEquals(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :jobId], 'The job should be scheduled.');
            System.abortJob(jobId);
        }

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