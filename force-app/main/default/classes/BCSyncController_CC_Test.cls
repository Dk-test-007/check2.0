/**
 * Tests for BCSyncController_CC (manual Business Central sync quick action).
 * Covers Entity / Site / Order evaluation, the review-field builder, record access checks
 * and the send path (callout through CalloutService_CC, mocked).
 */
@IsTest
private class BCSyncController_CC_Test {


    /** Anypoint MQ publish response, as returned for the Business Central event queue. */
    private class AnypointMqSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(201);
            response.setHeader('Content-Type', 'application/json');
            response.setBody('{"status":"successful","statusDescription":"Messages published","messageIds":["0f8fad5b-d9cb-469f-a165-70867728950e"]}');
            return response;
        }
    }

    @TestSetup
    static void setup() {
        Id ownerId = UserInfo.getUserId();

        Account unsyncedEntity = OpportunityUi2TestData_CC.entity(ownerId, false);

        Account syncedEntity = OpportunityUi2TestData_CC.entity(ownerId, false);
        update new Account(Id = syncedEntity.Id, Business_Central_Customer_ID_CC__c = 'ZZBCS-C' + OpportunityUi2TestData_CC.suffix());

        OpportunityUi2TestData_CC.site(unsyncedEntity.Id, ownerId, 'ZZBCS Orphan Site');
        OpportunityUi2TestData_CC.site(syncedEntity.Id, ownerId, 'ZZBCS New Site');
        Account syncedSite = OpportunityUi2TestData_CC.site(syncedEntity.Id, ownerId, 'ZZBCS Synced Site');
        update new Account(Id = syncedSite.Id, Site_Synced_CC__c = true);
    }

    // ------------------------------------------------------------------ helpers

    private static Account unsyncedEntity() {
        return [SELECT Id, Name FROM Account
                WHERE Name LIKE 'ZZUI2 Entity%' AND Business_Central_Customer_ID_CC__c = null LIMIT 1];
    }

    private static Account syncedEntity() {
        return [SELECT Id, Name FROM Account
                WHERE Name LIKE 'ZZUI2 Entity%' AND Business_Central_Customer_ID_CC__c != null LIMIT 1];
    }

    private static Account siteNamed(String prefix) {
        return [SELECT Id, Name, ParentId FROM Account WHERE Name LIKE :(prefix + '%') LIMIT 1];
    }

    /**
     * Whether the named Integration Config (custom metadata) is deployed. The review fields are read from its Request
     * Mapping; without it the record can still be synced but no review fields are shown.
     */
    private static Boolean configDeployed(String developerName) {
        return [SELECT COUNT() FROM Integration_Config__mdt WHERE DeveloperName = :developerName] > 0;
    }

    private static Id missingAccountId() {
        // Well-formed Account Id that does not exist, so the record query throws.
        return (Id) ('001' + '000000000000');
    }

    private static User readOnlyUser() {
        User u = OpportunityUi2TestData_CC.user('Read Only', 'bcsro');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    // ------------------------------------------------------------------ getSyncContext

    @IsTest
    static void blocksMissingRecordAndUnsupportedObject() {
        Test.startTest();
        BCSyncController_CC.SyncContext none = BCSyncController_CC.getSyncContext(null);
        BCSyncController_CC.SyncContext unsupported = BCSyncController_CC.getSyncContext(UserInfo.getUserId());
        Test.stopTest();

        Assert.isFalse(none.canSync, 'A missing record cannot be synced');
        Assert.isTrue(none.blockingMessage.contains('No record'), none.blockingMessage);
        Assert.isFalse(unsupported.canSync, 'Users are not synced to Business Central');
        Assert.isTrue(unsupported.blockingMessage.contains('not configured'), unsupported.blockingMessage);
        Assert.isNotNull(unsupported.recordLabel);
        Assert.isFalse(unsupported.isAccount);
    }

    @IsTest
    static void unsyncedEntityIsCreateWithReviewFields() {
        Account entity = unsyncedEntity();

        Test.startTest();
        BCSyncController_CC.SyncContext ctx = BCSyncController_CC.getSyncContext(entity.Id);
        Test.stopTest();

        Assert.isTrue(ctx.canSync, 'An Entity the user can edit can be synced: ' + ctx.blockingMessage);
        Assert.isTrue(ctx.isAccount);
        Assert.isFalse(ctx.isResync, 'An Entity without a Business Central Id is a new sync');
        Assert.areEqual('Entity', ctx.recordLabel);
        Assert.areEqual(entity.Name, ctx.recordName);
        Assert.areEqual(!configDeployed('Account_BC_Create'), ctx.reviewFields.isEmpty(),
            'Review fields come from the Account_BC_Create Request Mapping (none while it is not deployed)');

        if (!configDeployed('Account_BC_Create')) {
            return;
        }
        Boolean hasAddress = false;
        for (BCSyncController_CC.ReviewField field : ctx.reviewFields) {
            Assert.isNotNull(field.label, 'Every review field has a label');
            if (field.value != null && field.value.contains('New York')) {
                hasAddress = true;
            }
        }
        Assert.isTrue(hasAddress, 'The Billing Address compound field is formatted into one value');
    }

    @IsTest
    static void syncedEntityIsUpdate() {
        Test.startTest();
        BCSyncController_CC.SyncContext ctx = BCSyncController_CC.getSyncContext(syncedEntity().Id);
        Test.stopTest();

        Assert.isTrue(ctx.canSync);
        Assert.isTrue(ctx.isResync, 'An Entity with a Business Central Id is a re-sync');
        Assert.areEqual(!configDeployed('Account_BC_Update'), ctx.reviewFields.isEmpty(),
            'Review fields come from the Account_BC_Update Request Mapping (none while it is not deployed)');
    }

    @IsTest
    static void siteWithUnsyncedParentIsBlockedWithParentLink() {
        Account site = siteNamed('ZZBCS Orphan Site');

        Test.startTest();
        BCSyncController_CC.SyncContext ctx = BCSyncController_CC.getSyncContext(site.Id);
        Test.stopTest();

        Assert.isFalse(ctx.canSync, 'The parent Entity must be synced first');
        Assert.areEqual('Site', ctx.recordLabel);
        Assert.isTrue(ctx.blockingMessage.contains('parent Entity'), ctx.blockingMessage);
        Assert.areEqual(site.ParentId, ctx.parentRecordId, 'The user can read the parent, so a link is offered');
        Assert.isNotNull(ctx.parentRecordName);
        Assert.isTrue(ctx.reviewFields.isEmpty(), 'Review fields are only built when the record can be synced');
    }

    @IsTest
    static void newSiteUnderSyncedEntityIsSiteCreate() {
        Test.startTest();
        BCSyncController_CC.SyncContext ctx = BCSyncController_CC.getSyncContext(siteNamed('ZZBCS New Site').Id);
        Test.stopTest();

        Assert.isTrue(ctx.canSync, 'A Site under a synced Entity can be synced: ' + ctx.blockingMessage);
        Assert.isFalse(ctx.isResync);
        Assert.areEqual(!configDeployed('Site_BC_Create'), ctx.reviewFields.isEmpty(),
            'Review fields come from the Site_BC_Create Request Mapping (none while it is not deployed)');
    }

    @IsTest
    static void syncedSiteIsSiteUpdate() {
        Test.startTest();
        BCSyncController_CC.SyncContext ctx = BCSyncController_CC.getSyncContext(siteNamed('ZZBCS Synced Site').Id);
        Test.stopTest();

        Assert.isTrue(ctx.canSync);
        Assert.isTrue(ctx.isResync, 'A Site already synced is a re-sync');
        Assert.areEqual(!configDeployed('Site_BC_Update'), ctx.reviewFields.isEmpty(),
            'Review fields come from the Site_BC_Update Request Mapping (none while it is not deployed)');
    }

    @IsTest
    static void userWithoutEditAccessIsBlocked() {
        Account entity = unsyncedEntity();
        User readOnly = readOnlyUser();

        BCSyncController_CC.SyncContext ctx;
        String result;
        Test.startTest();
        System.runAs(readOnly) {
            ctx = BCSyncController_CC.getSyncContext(entity.Id);
            result = BCSyncController_CC.syncRecord(entity.Id, 'Account');
        }
        Test.stopTest();

        Assert.isFalse(ctx.canSync, 'A user who cannot edit Accounts cannot sync them');
        Assert.isTrue(ctx.blockingMessage.contains('permission'), ctx.blockingMessage);
        Assert.isTrue(result.startsWith('Error: '), result);
    }

    @IsTest
    static void unexpectedErrorIsReturnedToTheUser() {
        Id missingId = missingAccountId();

        Boolean thrown = false;
        Test.startTest();
        try {
            BCSyncController_CC.getSyncContext(missingId);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        String result = BCSyncController_CC.syncRecord(missingId, 'Account');
        Test.stopTest();

        Assert.isTrue(thrown, 'getSyncContext reports errors as AuraHandledException');
        Assert.isTrue(result.startsWith('Error: '), 'syncRecord returns errors as text: ' + result);
    }

    // ------------------------------------------------------------------ syncRecord

    @IsTest
    static void syncRecordSendsEntityAndSite() {
        Test.setMock(HttpCalloutMock.class, new AnypointMqSuccessMock());
        Account entity = unsyncedEntity();
        Account site = siteNamed('ZZBCS Synced Site');

        Test.startTest();
        String entityResult = BCSyncController_CC.syncRecord(entity.Id, 'Account');
        String siteResult = BCSyncController_CC.syncRecord(site.Id, 'Account');
        Integer queued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual('Success', entityResult);
        Assert.areEqual('Success', siteResult);
        Assert.areEqual(2, queued, 'One Business Central callout job is queued per record');
    }

    @IsTest
    static void syncRecordReturnsBlockingMessage() {
        Test.startTest();
        String result = BCSyncController_CC.syncRecord(siteNamed('ZZBCS Orphan Site').Id, 'Account');
        Test.stopTest();

        Assert.isTrue(result.startsWith('Error: '), result);
        Assert.isTrue(result.contains('parent Entity'), result);
        Assert.areEqual(0, Limits.getQueueableJobs(), 'Nothing is sent when the record is blocked');
    }

    // ------------------------------------------------------------------ Orders

    @IsTest
    static void draftOrderIsBlocked() {
        Account entity = syncedEntity();
        Order ord = new Order(AccountId = entity.Id, EffectiveDate = Date.today(), Status = 'Draft');
        insert ord;

        Test.startTest();
        BCSyncController_CC.SyncContext ctx = BCSyncController_CC.getSyncContext(ord.Id);
        String result = BCSyncController_CC.syncRecord(ord.Id, 'Order');
        Test.stopTest();

        Assert.isFalse(ctx.canSync, 'Draft Orders are not sent to Business Central');
        Assert.areEqual('Order', ctx.recordLabel);
        Assert.isFalse(ctx.isAccount);
        Assert.isFalse(ctx.isResync, 'An Order without an External Id is a new sync');
        Assert.isTrue(ctx.blockingMessage.contains('Activated'), ctx.blockingMessage);
        Assert.isTrue(result.startsWith('Error: '), result);
    }
}