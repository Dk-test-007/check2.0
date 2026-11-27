/**
 * =============================================================================
 * Class Name    : ChangeOwnerOnReNurtureTest_CC
 * Description   : Unit tests for the ChangeOwnerOnReNurture_CC queueable which hands a
 *                 Re-Nurtured Lead back to Marketing (last marketing owner, otherwise the
 *                 entity's Marketing pool queue).
 *                 Leads are inserted directly in 'Re-Nurture' (admin bypasses validation
 *                 rules, and insert does not enqueue the job from the trigger) and the job is
 *                 enqueued explicitly inside Test.startTest()/stopTest().
 * =============================================================================
 */
@IsTest
private class ChangeOwnerOnReNurtureTest_CC {

    private static final String STATUS_RE_NURTURE = 'Re-Nurture';
    private static final String MARKETING_ALIAS = 'cornMkt';
    private static final String SALES_ALIAS = 'cornSls';

    @TestSetup
    static void setupData() {
        User marketingUser = TestDataFactory_CC.createUser('Carlton Marketing User', MARKETING_ALIAS, false);
        User salesUser = TestDataFactory_CC.createUser('Carlton Sales User', SALES_ALIAS, false);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{marketingUser, salesUser};
        }

        Lead revert = buildLead('RevertToMarketing', salesUser.Id);
        revert.Last_Marketing_Owner_Id_CC__c = String.valueOf(marketingUser.Id);
        Lead storedNotMarketing = buildLead('StoredNotMarketing', salesUser.Id);
        storedNotMarketing.Last_Marketing_Owner_Id_CC__c = String.valueOf(salesUser.Id);
        Lead noEntity = buildLead('NoEntity', salesUser.Id);
        noEntity.Belongs_To_CC__c = null;
        Lead notReNurture = buildLead('NotReNurture', salesUser.Id);
        notReNurture.Status = 'Engage';
        Lead noReengagementDate = buildLead('NoReengagementDate', salesUser.Id);
        noReengagementDate.Reengagement_Date_CC__c = null;

        insert new List<Lead>{
            revert,
            buildLead('FallbackUS', salesUser.Id),
            storedNotMarketing,
            buildLead('QueueOwnedSales', TestDataFactory_CC.queueId('UK_Sales_Pool')),
            noEntity,
            notReNurture,
            buildLead('MarketingOwned', marketingUser.Id),
            buildLead('MarketingQueueOwned', TestDataFactory_CC.queueId('US_Marketing_Pool')),
            noReengagementDate
        };
    }

    // ---------------------------------------------------------------- helpers

    private static Lead buildLead(String lastName, Id ownerId) {
        Lead ld = TestDataFactory_CC.createLead(lastName, STATUS_RE_NURTURE, false);
        ld.OwnerId = ownerId;
        ld.Re_Nurture_Reason_CC__c = 'Not Ready to Buy';
        ld.Reengagement_Date_CC__c = Date.today().addMonths(3);
        return ld;
    }

    private static Lead leadByName(String lastName) {
        return [SELECT Id, OwnerId, Status, Last_Marketing_Owner_Id_CC__c FROM Lead WHERE LastName = :lastName LIMIT 1];
    }

    private static User userByAlias(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias AND Email LIKE '%@carltontest.invalid' ORDER BY CreatedDate DESC LIMIT 1];
    }

    /** Enqueues the job for the named Leads (previous owner = current owner) and returns the pre-run owners. */
    private static Map<Id, Id> previousOwners(List<String> lastNames) {
        Map<Id, Id> result = new Map<Id, Id>();
        for (Lead ld : [SELECT Id, OwnerId FROM Lead WHERE LastName IN :lastNames]) {
            result.put(ld.Id, ld.OwnerId);
        }
        return result;
    }

    private static void runJob(Map<Id, Id> previousOwnerByLeadId) {
        Test.startTest();
        System.enqueueJob(new ChangeOwnerOnReNurture_CC(previousOwnerByLeadId));
        Test.stopTest();
    }

    // ---------------------------------------------------------------- tests

    // Verifies a Re-Nurtured Lead owned by Sales goes back to its stored last Marketing owner.
    @IsTest
    static void testRevertsToLastMarketingOwner() {
        User marketingUser = userByAlias(MARKETING_ALIAS);
        runJob(previousOwners(new List<String>{'RevertToMarketing'}));
        Assert.areEqual(marketingUser.Id, leadByName('RevertToMarketing').OwnerId, 'Lead should be returned to the last Marketing owner');
    }

    // Verifies INC Leads without a valid Marketing owner fall back to the US Marketing pool (user and queue owned).
    @IsTest
    static void testFallsBackToUsMarketingPool() {
        Id usPool = TestDataFactory_CC.queueId('US_Marketing_Pool');
        runJob(previousOwners(new List<String>{'FallbackUS', 'StoredNotMarketing'}));
        Assert.areEqual(usPool, leadByName('FallbackUS').OwnerId, 'No stored owner -> US Marketing pool');
        Assert.areEqual(usPool, leadByName('StoredNotMarketing').OwnerId, 'Stored non-marketing owner -> US Marketing pool');
    }

    // Verifies a Lead owned by a non-marketing queue (no user ids to resolve) is moved to the US Marketing pool.
    @IsTest
    static void testQueueOwnedLeadMovedToMarketingPool() {
        runJob(previousOwners(new List<String>{'QueueOwnedSales'}));
        Assert.areEqual(TestDataFactory_CC.queueId('US_Marketing_Pool'), leadByName('QueueOwnedSales').OwnerId,
            'Sales-pool owned Lead should move to the US Marketing pool');
    }

    // Verifies Leads that are not Re-Nurture, already Marketing owned, or have no entity keep their owner.
    @IsTest
    static void testIneligibleLeadsKeepOwner() {
        List<String> names = new List<String>{'NotReNurture', 'MarketingOwned', 'MarketingQueueOwned', 'NoEntity'};
        Map<Id, Id> before = previousOwners(names);
        runJob(before);
        for (Lead ld : [SELECT Id, LastName, OwnerId FROM Lead WHERE Id IN :before.keySet()]) {
            Assert.areEqual(before.get(ld.Id), ld.OwnerId, ld.LastName + ' should keep its owner');
        }
    }

    // Verifies null, empty and unknown-Lead inputs are ignored without errors or changes.
    @IsTest
    static void testEmptyInputsAreIgnored() {
        Lead deleted = TestDataFactory_CC.createLead('DeletedReNurture', 'Engage', true);
        Id deletedId = deleted.Id;
        delete deleted;
        Integer before = [SELECT COUNT() FROM Lead WHERE OwnerId = :TestDataFactory_CC.queueId('US_Marketing_Pool')];

        Test.startTest();
        new ChangeOwnerOnReNurture_CC(null).execute(null);
        new ChangeOwnerOnReNurture_CC(new Map<Id, Id>()).execute(null);
        new ChangeOwnerOnReNurture_CC(new Map<Id, Id>{deletedId => UserInfo.getUserId()}).execute(null);
        Test.stopTest();

        Assert.areEqual(before, [SELECT COUNT() FROM Lead WHERE OwnerId = :TestDataFactory_CC.queueId('US_Marketing_Pool')],
            'No Lead ownership should change');
    }

    // Verifies a DML failure (validation rule fires for the Sales user running the job) is caught and the owner is kept.
    @IsTest
    static void testDmlFailureIsHandled() {
        User salesUser = userByAlias(SALES_ALIAS);
        Map<Id, Id> before = previousOwners(new List<String>{'NoReengagementDate'});
        System.runAs(salesUser) {
            runJob(before);
        }
        Lead after = leadByName('NoReengagementDate');
        Assert.areEqual(salesUser.Id, after.OwnerId, 'Owner must be unchanged when the update fails');
        Assert.areEqual(STATUS_RE_NURTURE, after.Status, 'Status must be unchanged');
    }

    // Verifies a Sales user can return a Re-Nurtured Lead to the Marketing pool.
    @IsTest
    static void testSalesUserContextTransfersToMarketingPool() {
        User salesUser = userByAlias(SALES_ALIAS);
        Map<Id, Id> before = previousOwners(new List<String>{'FallbackUS'});
        System.runAs(salesUser) {
            runJob(before);
        }
        Assert.areEqual(TestDataFactory_CC.queueId('US_Marketing_Pool'), leadByName('FallbackUS').OwnerId,
            'A Sales user should be able to return a Re-Nurtured Lead to Marketing');
    }

    // Bulk: 200 Re-Nurtured Sales-owned INC Leads are all transferred to the US Marketing pool in one job.
    @IsTest
    static void testBulk200LeadsTransferred() {
        User salesUser = userByAlias(SALES_ALIAS);
        List<Lead> bulkLeads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            bulkLeads.add(buildLead('BulkRN' + i, salesUser.Id));
        }
        insert bulkLeads;
        Map<Id, Id> before = new Map<Id, Id>();
        for (Lead ld : bulkLeads) {
            before.put(ld.Id, salesUser.Id);
        }
        runJob(before);
        Id usPool = TestDataFactory_CC.queueId('US_Marketing_Pool');
        Assert.areEqual(200, [SELECT COUNT() FROM Lead WHERE Id IN :before.keySet() AND OwnerId = :usPool],
            'All 200 Leads should be transferred to the US Marketing pool');
    }
}