@IsTest
private class BCBulkSiteSyncController_CC_Test {
    /** Anypoint MQ publish response, as returned for the Business Central event queue. */
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'application/json');
            response.setBody('{"status":"successful","statusDescription":"Messages published","messageIds":["7c9e6679-7425-40de-944b-e07fc1f90ae7"]}');
            return response;
        }
    }
    @TestSetup
    static void setup() {
        Account entity = OpportunityUi2TestData_CC.entity(UserInfo.getUserId(), false);
        Account site = OpportunityUi2TestData_CC.site(entity.Id, UserInfo.getUserId(), 'ZZTEST Bulk Sync Site');
        // The Site auto number restarts after @TestSetup, so a Site inserted in a test method gets the same
        // auto number as this one; move this Site off it so copying it to the unique Site Code cannot collide.
        update new Account(Id = site.Id, Site_Code_CC__c = 'ZZSETUP-' + OpportunityUi2TestData_CC.suffix());
    }

    private static Account entity() {
        return [SELECT Id, Business_Central_Customer_ID_CC__c FROM Account
            WHERE Name LIKE 'ZZUI2 Entity%' LIMIT 1];
    }

    private static Account site() {
        return [SELECT Id FROM Account WHERE Name LIKE 'ZZTEST Bulk Sync Site%' LIMIT 1];
    }

    private static void markSynced(Id entityId) {
        update new Account(Id = entityId, Business_Central_Customer_ID_CC__c = 'ZZTEST-BC-' + OpportunityUi2TestData_CC.suffix());
    }

    /** Fills every field in the Site_BC_Create Request Mapping that is not set by the test data helper. */
    private static Account completeSite(Id entityId, String name, Boolean alreadySynced) {
        Account site = OpportunityUi2TestData_CC.site(entityId, UserInfo.getUserId(), name);
        update new Account(Id = site.Id,
            Site_Code_CC__c = 'ZZSC-' + OpportunityUi2TestData_CC.suffix(),
            Tax_Area_CC__c = 'VERTEX',
            Delivery_Instructions_CC__c = 'Deliver to the rear dock',
            Warehouse_Instructions_CC__c = 'Pallets must be shrink wrapped',
            Site_Synced_CC__c = alreadySynced);
        return site;
    }

    /**
     * Whether the Site_BC_Create Integration Config (custom metadata) is deployed. The controller reads the mandatory
     * Site fields from its Request Mapping; without it every Entity is blocked with a message naming the record.
     */
    private static Boolean siteCreateConfigDeployed() {
        return [SELECT COUNT() FROM Integration_Config__mdt WHERE DeveloperName = :BCBulkSiteSyncController_CC.SITE_CREATE_CONFIG] > 0;
    }

    private static void assertBlockedForMissingConfig(BCBulkSiteSyncController_CC.SyncSummary summary) {
        Assert.isFalse(summary.canSync, 'Sites cannot be evaluated without the Site_BC_Create Integration Config');
        Assert.isTrue(summary.blockingMessage.contains(BCBulkSiteSyncController_CC.SITE_CREATE_CONFIG), summary.blockingMessage);
    }

    private static Id missingAccountId() {
        // Well-formed Account Id that does not exist, so the Entity query throws.
        return (Id) ('001' + '000000000000');
    }

    @IsTest
    static void blocksWrongRecordAndUnsyncedEntity() {
        BCBulkSiteSyncController_CC.SyncSummary missing =
            BCBulkSiteSyncController_CC.getSiteSyncSummary(null);
        Assert.isFalse(missing.canSync);
        Assert.isFalse(BCBulkSiteSyncController_CC.getSiteSyncSummary(site().Id).canSync);
        BCBulkSiteSyncController_CC.SyncSummary unsynced =
            BCBulkSiteSyncController_CC.getSiteSyncSummary(entity().Id);
        Assert.isFalse(unsynced.canSync);
        Assert.isTrue(unsynced.blockingMessage.contains('Business Central'));

        Boolean rejected = false;
        try {
            BCBulkSiteSyncController_CC.syncSites(entity().Id, new List<Id>());
        } catch (AuraHandledException expected) {
            rejected = true;
        }
        Assert.isTrue(rejected, 'At least one Site must be selected');
    }

    @IsTest
    static void listsIncompleteSitesWithoutSendingThem() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Account parent = entity();
        update new Account(Id = parent.Id, Business_Central_Customer_ID_CC__c = 'ZZTEST-BC-100');
        BCBulkSiteSyncController_CC.SyncSummary summary =
            BCBulkSiteSyncController_CC.getSiteSyncSummary(parent.Id);
        if (!siteCreateConfigDeployed()) {
            assertBlockedForMissingConfig(summary);
            return;
        }
        Assert.isTrue(summary.canSync, 'The synced Entity should allow site evaluation');
        Assert.areEqual(1, summary.totalSites);
        Assert.areEqual(1, summary.excludedSites.size(), 'The incomplete Site must be excluded');
        Assert.isTrue(summary.excludedSites[0].issue.contains('Missing:'));

    }

    @IsTest
    static void syncsOnlySelectedEligibleSites() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Account parent = entity();
        Account incomplete = site();
        markSynced(parent.Id);
        Account newSite = completeSite(parent.Id, 'ZZTEST Complete New Site', false);
        Account syncedSite = completeSite(parent.Id, 'ZZTEST Complete Synced Site', true);

        BCBulkSiteSyncController_CC.SyncSummary summary =
            BCBulkSiteSyncController_CC.getSiteSyncSummary(parent.Id);
        if (!siteCreateConfigDeployed()) {
            assertBlockedForMissingConfig(summary);
            return;
        }
        Assert.isTrue(summary.canSync, 'Entity can be synced: ' + summary.blockingMessage);
        Assert.areEqual(3, summary.totalSites);
        Assert.areEqual(2, summary.eligibleSites.size(), 'Sites with every mapped field are eligible: ' + JSON.serialize(summary.excludedSites));
        Assert.areEqual(1, summary.excludedSites.size());
        for (BCBulkSiteSyncController_CC.SiteRow row : summary.eligibleSites) {
            Assert.areEqual(row.id == syncedSite.Id ? 'Update' : 'New', row.syncType);
            Assert.isTrue(row.recordUrl.contains(row.id));
        }

        Test.startTest();
        BCBulkSiteSyncController_CC.SyncResult result = BCBulkSiteSyncController_CC.syncSites(
            parent.Id, new List<Id>{ newSite.Id, syncedSite.Id, incomplete.Id });
        Integer queued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(1, result.createdCount, 'The new Site is sent as a create');
        Assert.areEqual(1, result.updatedCount, 'The synced Site is sent as an update');
        Assert.areEqual(1, result.skippedCount, 'The incomplete Site is not sent');
        Assert.areEqual(2, queued, 'One Business Central job per operation');
    }

    @IsTest
    static void rejectsSelectionWithNoEligibleSites() {
        Account parent = entity();
        Id incompleteId = site().Id;

        Boolean unsyncedRejected = false;
        try {
            BCBulkSiteSyncController_CC.syncSites(parent.Id, new List<Id>{ incompleteId });
        } catch (AuraHandledException expected) {
            unsyncedRejected = true;
        }

        markSynced(parent.Id);
        Boolean noneEligible = false;
        Test.startTest();
        try {
            BCBulkSiteSyncController_CC.syncSites(parent.Id, new List<Id>{ incompleteId });
        } catch (AuraHandledException expected) {
            noneEligible = true;
        }
        Integer queued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.isTrue(unsyncedRejected, 'Sites of an unsynced Entity cannot be sent');
        Assert.isTrue(noneEligible, 'Selecting only incomplete Sites is rejected');
        Assert.areEqual(0, queued, 'Nothing is sent');
    }

    @IsTest
    static void blocksEntityWithoutSites() {
        Account emptyEntity = OpportunityUi2TestData_CC.entity(UserInfo.getUserId(), false);
        markSynced(emptyEntity.Id);

        Test.startTest();
        BCBulkSiteSyncController_CC.SyncSummary summary =
            BCBulkSiteSyncController_CC.getSiteSyncSummary(emptyEntity.Id);
        Test.stopTest();

        if (!siteCreateConfigDeployed()) {
            assertBlockedForMissingConfig(summary);
            return;
        }
        Assert.isFalse(summary.canSync);
        Assert.areEqual(0, summary.totalSites);
        Assert.isTrue(summary.blockingMessage.contains('no Sites'), summary.blockingMessage);
    }

    @IsTest
    static void blocksUserWithoutAccountEditPermission() {
        Account parent = entity();
        markSynced(parent.Id);
        User readOnly = OpportunityUi2TestData_CC.user('Read Only', 'bcbro');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert readOnly;
        }

        BCBulkSiteSyncController_CC.SyncSummary summary;
        Test.startTest();
        System.runAs(readOnly) {
            summary = BCBulkSiteSyncController_CC.getSiteSyncSummary(parent.Id);
        }
        Test.stopTest();

        Assert.isFalse(summary.canSync);
        Assert.isTrue(summary.blockingMessage.contains('permission'), summary.blockingMessage);
    }

    @IsTest
    static void unexpectedErrorsAreReportedToTheUser() {
        Id missingId = missingAccountId();

        Boolean summaryFailed = false;
        Boolean syncFailed = false;
        Test.startTest();
        try {
            BCBulkSiteSyncController_CC.getSiteSyncSummary(missingId);
        } catch (AuraHandledException expected) {
            summaryFailed = true;
        }
        try {
            BCBulkSiteSyncController_CC.syncSites(missingId, new List<Id>{ missingId });
        } catch (AuraHandledException expected) {
            syncFailed = true;
        }
        Test.stopTest();

        Assert.isTrue(summaryFailed, 'Errors are returned as AuraHandledException');
        Assert.isTrue(syncFailed, 'Errors are returned as AuraHandledException');
    }
}