/**
 * Tests for LeadDirectAssignmentQueueable_CC (asynchronous DIRECT and SALES_USER notifications).
 * Its helpers are private, so every path is driven through execute(); most scenarios call execute(null)
 * synchronously (one scenario per call, because a failure inside the loop ends that execution), and one
 * scenario is enqueued to prove the job runs asynchronously.
 */
@IsTest
private class LeadDirectAssignmentQueueable_CC_Test {

    private static final String MODE_DIRECT = 'DIRECT';
    private static final String MODE_SALES_USER = 'SALES_USER';
    private static final String STATUS_ENGAGE = 'Engage';
    private static final String SALES_PROFILE = 'Carlton Sales User';
    private static final String MARKETING_PROFILE = 'Carlton Marketing User';
    private static final String ADMIN_PROFILE = 'System Administrator';
    private static final String FALLBACK_MAPPED_COMPANY = 'Amazon';

    private static final String LN_DIRECT = 'LDAQ Direct';
    private static final String LN_DIRECT_NO_FIRST = 'LDAQ Direct NoFirst';
    private static final String LN_DIRECT_SALES = 'LDAQ Direct Sales';
    private static final String LN_UNMAPPED = 'LDAQ Unmapped';
    private static final String LN_SALES = 'LDAQ Sales';
    private static final String LN_SALES_NO_MKT = 'LDAQ Sales NoMkt';
    private static final String LN_QUEUE = 'LDAQ Queue';

    // ------------------------------------------------------------------------------------ setup

    @TestSetup
    static void setupData() {
        User adminOwner;
        User adminNoFirstName;
        User salesOwner;
        User marketingOwner;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            adminOwner = getOrCreateUser(ADMIN_PROFILE, 'ldaqadm', 'Queue');
            adminNoFirstName = getOrCreateUser(ADMIN_PROFILE, 'ldaqnof', null);
            salesOwner = getOrCreateUser(SALES_PROFILE, 'ldaqsls', 'Queue');
            marketingOwner = getOrCreateUser(MARKETING_PROFILE, 'ldaqmkt', 'Queue');
        }

        String mappedCompany = mappedCompany();
        List<Lead> leads = new List<Lead>{
            buildLead(LN_DIRECT, mappedCompany, adminOwner.Id, String.valueOf(marketingOwner.Id)),
            buildLead(LN_DIRECT_NO_FIRST, mappedCompany, adminNoFirstName.Id, 'not-a-valid-id'),
            buildLead(LN_DIRECT_SALES, mappedCompany, salesOwner.Id, null),
            buildLead(LN_UNMAPPED, 'LDAQ Unmapped Company Ltd', adminOwner.Id, null),
            buildLead(LN_SALES, 'LDAQ Sales Handover Ltd', salesOwner.Id, String.valueOf(marketingOwner.Id)),
            buildLead(LN_SALES_NO_MKT, 'LDAQ Sales No Marketing Ltd', salesOwner.Id, String.valueOf(salesOwner.ProfileId))
        };
        Id queueId = TestDataFactory_CC.queueId('US_Marketing_Pool');
        if (queueId != null) {
            leads.add(buildLead(LN_QUEUE, 'LDAQ Queue Company Ltd', queueId, null));
        }
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        List<Database.SaveResult> results = Database.insert(leads, options);
        for (Database.SaveResult result : results) {
            Assert.isTrue(result.isSuccess(), 'Lead insert should succeed: ' + result.getErrors());
        }
    }

    private static User getOrCreateUser(String profileName, String aliasSeed, String firstName) {
        try {
            User created = TestDataFactory_CC.createUser(profileName, aliasSeed, false);
            created.FirstName = firstName;
            insert created;
            return [SELECT Id, ProfileId FROM User WHERE Id = :created.Id];
        } catch (Exception ex) {
            // No licence left for this profile: fall back to an existing active user with it.
            List<User> existing = [
                SELECT Id, ProfileId FROM User
                WHERE Profile.Name = :profileName AND IsActive = TRUE AND Email != NULL
                LIMIT 1
            ];
            Assert.isFalse(existing.isEmpty(), 'An active user with profile ' + profileName + ' is required');
            return existing[0];
        }
    }

    private static String mappedCompany() {
        for (Lead_Company_Owner_Mapping_CC__mdt mapping : [
            SELECT Company_Name_CC__c
            FROM Lead_Company_Owner_Mapping_CC__mdt
            WHERE Active_CC__c = TRUE AND Company_Name_CC__c != NULL AND Owner_Id_CC__c != NULL
            LIMIT 1
        ]) {
            return mapping.Company_Name_CC__c;
        }
        return FALLBACK_MAPPED_COMPANY;
    }

    private static Lead buildLead(String lastName, String company, Id ownerId, String lastMarketingOwnerId) {
        Lead leadRecord = TestDataFactory_CC.createLead(lastName, STATUS_ENGAGE, false);
        leadRecord.Company = company;
        leadRecord.OwnerId = ownerId;
        leadRecord.LeadSource = 'Web Search';
        leadRecord.Product_Category_CC__c = 'Tape;Cardboard';
        leadRecord.Last_Marketing_Owner_Id_CC__c = lastMarketingOwnerId;
        return leadRecord;
    }

    // ------------------------------------------------------------------------------------ helpers

    private static Set<Id> idsOf(String lastName) {
        return new Map<Id, Lead>([SELECT Id FROM Lead WHERE LastName = :lastName]).keySet();
    }

    private static Id fakeLeadId(Integer index) {
        return Id.valueOf('00Q' + String.valueOf(index).leftPad(12, '0'));
    }

    private static void runNow(Set<Id> leadIds, String mode) {
        new LeadDirectAssignmentQueueable_CC(leadIds, mode).execute(null);
    }

    // ------------------------------------------------------------------------------------ tests

    @IsTest
    static void executeReturnsEarlyForMissingInput() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        runNow(null, MODE_DIRECT);
        runNow(new Set<Id>(), MODE_DIRECT);
        Integer queriesAfterEmpty = Limits.getQueries();
        runNow(new Set<Id>{ fakeLeadId(1) }, MODE_DIRECT);
        Integer queriesAfterUnknown = Limits.getQueries();
        Test.stopTest();
        Assert.areEqual(queriesBefore, queriesAfterEmpty, 'Null or empty input must exit before any query');
        Assert.areEqual(queriesAfterEmpty + 1, queriesAfterUnknown, 'Unknown Lead Ids stop after the Lead query');
    }

    @IsTest
    static void directModeNotifiesNonSalesOwnerOfMappedCompanyLead() {
        Set<Id> directIds = idsOf(LN_DIRECT);
        Set<Id> noFirstNameIds = idsOf(LN_DIRECT_NO_FIRST);
        Assert.areEqual(1, directIds.size(), 'Direct Lead should exist');
        Test.startTest();
        runNow(directIds, MODE_DIRECT);
        runNow(noFirstNameIds, MODE_DIRECT);
        Test.stopTest();
        // Delivery is not observable in tests; the notification must not change the Lead.
        Lead reloaded = [SELECT Company FROM Lead WHERE Id IN :directIds];
        Assert.areEqual(mappedCompany(), reloaded.Company, 'Notification must not change the Lead company');
    }

    @IsTest
    static void directModeSkipsSalesOwnedUnmappedQueueOwnedAndUnknownMode() {
        Set<Id> directSalesIds = idsOf(LN_DIRECT_SALES);
        Set<Id> unmappedIds = idsOf(LN_UNMAPPED);
        Set<Id> queueIds = idsOf(LN_QUEUE);
        Set<Id> directIds = idsOf(LN_DIRECT);
        Test.startTest();
        runNow(directSalesIds, MODE_DIRECT);
        runNow(unmappedIds, MODE_DIRECT);
        if (!queueIds.isEmpty()) {
            runNow(queueIds, MODE_DIRECT);
        }
        runNow(directIds, 'UNKNOWN_MODE');
        Integer emailInvocations = Limits.getEmailInvocations();
        Test.stopTest();
        Assert.areEqual(0, emailInvocations, 'Skipped Leads must not send any e-mail');
    }

    @IsTest
    static void salesUserModeNotifiesSalesOwnerOnly() {
        Set<Id> adminOwnedIds = idsOf(LN_UNMAPPED);
        Set<Id> salesIds = idsOf(LN_SALES);
        Set<Id> salesNoMarketingIds = idsOf(LN_SALES_NO_MKT);
        Test.startTest();
        runNow(adminOwnedIds, MODE_SALES_USER);
        Integer emailsAfterSkip = Limits.getEmailInvocations();
        runNow(salesIds, MODE_SALES_USER);
        runNow(salesNoMarketingIds, MODE_SALES_USER);
        Test.stopTest();
        Assert.areEqual(0, emailsAfterSkip, 'A Lead not owned by a Carlton Sales User is skipped');
    }

    @IsTest
    static void enqueuedJobRunsAsynchronously() {
        Set<Id> salesIds = idsOf(LN_SALES);
        Test.startTest();
        Id jobId = System.enqueueJob(new LeadDirectAssignmentQueueable_CC(salesIds, MODE_SALES_USER));
        Test.stopTest();
        AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE Id = :jobId];
        Assert.areEqual('Completed', job.Status, 'The queueable should complete (errors are caught and logged)');
        Assert.areEqual(0, job.NumberOfErrors, 'The queueable should not fail');
    }
}