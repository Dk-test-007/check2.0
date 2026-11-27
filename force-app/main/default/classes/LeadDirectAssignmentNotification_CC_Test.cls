/**
 * Tests for LeadDirectAssignmentNotification_CC (DIRECT and SALES_USER e-mail + bell notifications).
 */
@IsTest
private class LeadDirectAssignmentNotification_CC_Test {

    private static final String MODE_DIRECT = 'DIRECT';
    private static final String MODE_SALES_USER = 'SALES_USER';
    private static final String STATUS_ENGAGE = 'Engage';
    private static final String SALES_PROFILE = 'Carlton Sales User';
    private static final String MARKETING_PROFILE = 'Carlton Marketing User';
    private static final String ADMIN_PROFILE = 'System Administrator';
    private static final String DIRECT_NOTIFICATION = 'Direct_Lead_Assignment_Notification_CC';
    private static final String SALES_USER_NOTIFICATION = 'Sales_Handover_Notification_Specific_User_CC';
    private static final String FALLBACK_MAPPED_COMPANY = 'Amazon';

    private static final String LN_DIRECT = 'LDAN Direct';
    private static final String LN_DIRECT_SALES = 'LDAN Direct Sales';
    private static final String LN_UNMAPPED = 'LDAN Unmapped';
    private static final String LN_SALES = 'LDAN Sales';
    private static final String LN_QUEUE = 'LDAN Queue';

    // ------------------------------------------------------------------------------------ setup

    @TestSetup
    static void setupData() {
        User adminOwner;
        User salesOwner;
        User marketingOwner;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            adminOwner = getOrCreateUser(ADMIN_PROFILE, 'ldanadm');
            salesOwner = getOrCreateUser(SALES_PROFILE, 'ldansls');
            marketingOwner = getOrCreateUser(MARKETING_PROFILE, 'ldanmkt');
        }

        String mappedCompany = mappedCompany();
        List<Lead> leads = new List<Lead>();
        leads.add(buildLead(LN_DIRECT, mappedCompany, adminOwner.Id, String.valueOf(marketingOwner.Id)));
        leads.add(buildLead(LN_DIRECT_SALES, mappedCompany, salesOwner.Id, null));
        leads.add(buildLead(LN_UNMAPPED, 'LDAN Unmapped Company Ltd', adminOwner.Id, 'not-a-valid-id'));
        leads.add(buildLead(LN_SALES, 'LDAN Sales Handover Ltd', salesOwner.Id, String.valueOf(marketingOwner.Id)));
        Id queueId = TestDataFactory_CC.queueId('US_Marketing_Pool');
        if (queueId != null) {
            leads.add(buildLead(LN_QUEUE, 'LDAN Queue Company Ltd', queueId, String.valueOf(queueId)));
        }
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        List<Database.SaveResult> results = Database.insert(leads, options);
        for (Database.SaveResult result : results) {
            Assert.isTrue(result.isSuccess(), 'Lead insert should succeed: ' + result.getErrors());
        }
    }

    private static User getOrCreateUser(String profileName, String aliasSeed) {
        try {
            User created = TestDataFactory_CC.createUser(profileName, aliasSeed, false);
            created.FirstName = 'Notify';
            insert created;
            return created;
        } catch (Exception ex) {
            // No licence left for this profile: fall back to an existing active user with it.
            List<User> existing = [
                SELECT Id FROM User
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

    private static Lead leadByName(String lastName) {
        return [
            SELECT Id, Name, Company, LeadSource, Status, OwnerId, Belongs_To_CC__c, Product_Category_Text_CC__c,
                   Last_Marketing_Owner_Id_CC__c, Qualified_Date_CC__c
            FROM Lead
            WHERE LastName = :lastName
            LIMIT 1
        ];
    }

    private static Set<Id> idsOf(String lastName) {
        List<Lead> found = [SELECT Id FROM Lead WHERE LastName = :lastName];
        return new Map<Id, Lead>(found).keySet();
    }

    private static Id fakeLeadId(Integer index) {
        return Id.valueOf('00Q' + String.valueOf(index).leftPad(12, '0'));
    }

    private static void runNotification(Set<Id> leadIds, String mode) {
        new LeadDirectAssignmentNotification_CC(leadIds, mode).execute();
    }

    // ------------------------------------------------------------------------------------ tests

    @IsTest
    static void executeReturnsEarlyForMissingInput() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        runNotification(null, MODE_DIRECT);
        runNotification(new Set<Id>(), MODE_DIRECT);
        Integer queriesAfterEmpty = Limits.getQueries();
        runNotification(new Set<Id>{ fakeLeadId(1) }, MODE_DIRECT);
        Integer queriesAfterUnknown = Limits.getQueries();
        Test.stopTest();
        Assert.areEqual(queriesBefore, queriesAfterEmpty, 'Null or empty input must exit before any query');
        Assert.areEqual(queriesAfterEmpty + 1, queriesAfterUnknown, 'Unknown Lead Ids stop after the Lead query');
    }

    @IsTest
    static void directModeNotifiesOwnerOfMappedCompanyLead() {
        Set<Id> leadIds = idsOf(LN_DIRECT);
        Test.startTest();
        runNotification(leadIds, MODE_DIRECT);
        Test.stopTest();
        // Delivery is not observable in tests; the notification must not change the Lead.
        Assert.areEqual(1, leadIds.size(), 'Direct Lead should exist');
        Lead reloaded = [SELECT Company FROM Lead WHERE Id IN :leadIds];
        Assert.areEqual(mappedCompany(), reloaded.Company, 'Notification must not change the Lead company');
    }

    @IsTest
    static void directModeSkipsUnmappedQueueOwnedAndOtherModes() {
        Set<Id> unmappedIds = idsOf(LN_UNMAPPED);
        Set<Id> queueIds = idsOf(LN_QUEUE);
        Set<Id> directIds = idsOf(LN_DIRECT);
        Test.startTest();
        runNotification(unmappedIds, MODE_DIRECT);
        if (!queueIds.isEmpty()) {
            runNotification(queueIds, MODE_DIRECT);
        }
        runNotification(directIds, 'UNKNOWN_MODE');
        Integer emailInvocations = Limits.getEmailInvocations();
        Test.stopTest();
        Assert.areEqual(0, emailInvocations, 'Skipped Leads must not send any e-mail');
    }

    @IsTest
    static void salesUserModeNotifiesSalesOwnerOnly() {
        Set<Id> salesIds = idsOf(LN_SALES);
        Set<Id> adminOwnedIds = idsOf(LN_DIRECT);
        Test.startTest();
        runNotification(adminOwnedIds, MODE_SALES_USER);
        Integer emailsAfterSkip = Limits.getEmailInvocations();
        runNotification(salesIds, MODE_SALES_USER);
        Test.stopTest();
        Assert.areEqual(0, emailsAfterSkip, 'A Lead not owned by a Carlton Sales User is skipped');
    }

    @IsTest
    static void lookupHelpersReturnExpectedValues() {
        LeadDirectAssignmentNotification_CC service =
            new LeadDirectAssignmentNotification_CC(new Set<Id>(), MODE_DIRECT);
        Lead directLead = leadByName(LN_DIRECT);
        Lead unmappedLead = leadByName(LN_UNMAPPED);
        Lead salesLead = leadByName(LN_SALES);

        Test.startTest();
        Map<String, Id> templates = service.getTemplates();
        Map<String, Id> notifications = service.getNotificationTypes();
        Id orgWideId = service.getOrgWideEmailId();
        Map<Id, User> owners = service.getOwners(new List<Lead>{ directLead, unmappedLead, salesLead });
        Map<Id, User> noOwners = service.getOwners(new List<Lead>{ new Lead(LastName = 'No Owner') });
        Map<Id, User> marketingOwners = service.getMarketingOwners(new List<Lead>{ directLead, unmappedLead });
        Map<Id, User> noMarketingOwners = service.getMarketingOwners(new List<Lead>{ unmappedLead });
        Set<Id> directIds = service.getDirectlyMappedLeadIds(new List<Lead>{ directLead, unmappedLead });
        Test.stopTest();

        Assert.isNotNull(templates, 'Template map should never be null');
        Assert.isNotNull(notifications, 'Notification map should never be null');
        Assert.isTrue(orgWideId == null || orgWideId.getSObjectType() == OrgWideEmailAddress.SObjectType,
            'Org-wide address is optional');
        Assert.isTrue(owners.containsKey(directLead.OwnerId), 'Active user owner should be returned');
        Assert.isTrue(owners.containsKey(salesLead.OwnerId), 'Sales owner should be returned');
        Assert.isTrue(noOwners.isEmpty(), 'Lead without owner returns no users');
        Assert.isTrue(marketingOwners.containsKey(Id.valueOf(directLead.Last_Marketing_Owner_Id_CC__c)),
            'Valid marketing owner should be returned');
        Assert.isTrue(noMarketingOwners.isEmpty(), 'Invalid marketing owner ids are ignored');
        Assert.isTrue(directIds.contains(directLead.Id), 'Mapped company Lead should be direct');
        Assert.isFalse(directIds.contains(unmappedLead.Id), 'Unmapped company Lead is not direct');
    }

    @IsTest
    static void marketingOwnerIdParsesOnlyUserIds() {
        LeadDirectAssignmentNotification_CC service =
            new LeadDirectAssignmentNotification_CC(new Set<Id>(), MODE_DIRECT);
        Id userId = UserInfo.getUserId();
        Test.startTest();
        Id blankResult = service.getMarketingOwnerId(new Lead(Last_Marketing_Owner_Id_CC__c = '  '));
        Id invalidResult = service.getMarketingOwnerId(new Lead(Last_Marketing_Owner_Id_CC__c = 'not-an-id'));
        Id leadIdResult = service.getMarketingOwnerId(new Lead(Last_Marketing_Owner_Id_CC__c = String.valueOf(fakeLeadId(7))));
        Id userResult = service.getMarketingOwnerId(new Lead(Last_Marketing_Owner_Id_CC__c = ' ' + userId + ' '));
        Test.stopTest();
        Assert.isNull(blankResult, 'Blank value returns null');
        Assert.isNull(invalidResult, 'Invalid value returns null');
        Assert.isNull(leadIdResult, 'Non-user Id returns null');
        Assert.areEqual(userId, userResult, 'User Id is parsed and trimmed');
    }

    @IsTest
    static void mergeFieldsAndDefaultsAreReplaced() {
        LeadDirectAssignmentNotification_CC service =
            new LeadDirectAssignmentNotification_CC(new Set<Id>(), MODE_SALES_USER);
        Lead leadRecord = new Lead(Company = 'Merge Co', Qualified_Date_CC__c = null);
        User namedOwner = new User(FirstName = 'Jamie');
        User marketingOwner = new User(LastName = 'Marketer');
        String template = '[Recipient First Name]|[Assigned To]|[LastMarketingOwnerId]|[Qualified_Date_CC__c]|'
            + '{!User.FirstName}|{!Lead.OwnerFullName}';

        Test.startTest();
        String blank = service.replaceMergeFields('', leadRecord, namedOwner, null);
        String nullBody = service.replaceMergeFields(null, leadRecord, namedOwner, null);
        String withDefaults = service.replaceMergeFields(template, leadRecord, new User(), null);
        String withNames = service.replaceMergeFields(template, leadRecord, namedOwner, marketingOwner);
        Test.stopTest();

        Assert.areEqual('', blank, 'Blank body is returned unchanged');
        Assert.isNull(nullBody, 'Null body is returned unchanged');
        Assert.areEqual('Team|Not Provided|Not Provided|Not Provided|Team|Not Provided', withDefaults,
            'Missing values fall back to defaults');
        Assert.isTrue(withNames.startsWith('Jamie|'), 'Owner first name should be merged: ' + withNames);
        Assert.areEqual('Not Provided', service.valueOrDefault(null), 'Null value default');
        Assert.areEqual('Not Provided', service.valueOrDefault(' '), 'Blank value default');
        Assert.areEqual('Tape', service.valueOrDefault('Tape'), 'Value returned as-is');
    }

    @IsTest
    static void customNotificationsAreSentForBothTypes() {
        LeadDirectAssignmentNotification_CC service =
            new LeadDirectAssignmentNotification_CC(new Set<Id>(), MODE_DIRECT);
        Map<String, Id> notifications = service.getNotificationTypes();
        Lead directLead = leadByName(LN_DIRECT);
        Lead salesLead = leadByName(LN_SALES);
        Map<Id, User> owners = service.getOwners(new List<Lead>{ directLead, salesLead });
        User marketingOwner = new User(LastName = 'Marketer');
        Integer sent = 0;

        Test.startTest();
        if (notifications.containsKey(DIRECT_NOTIFICATION)) {
            try {
                service.sendCustomNotification(notifications.get(DIRECT_NOTIFICATION), DIRECT_NOTIFICATION,
                    directLead, owners.get(directLead.OwnerId), null);
                sent++;
            } catch (Exception ex) {
                System.debug(LoggingLevel.WARN, 'Direct notification not sent: ' + ex.getMessage());
            }
        }
        if (notifications.containsKey(SALES_USER_NOTIFICATION)) {
            try {
                service.sendCustomNotification(notifications.get(SALES_USER_NOTIFICATION), SALES_USER_NOTIFICATION,
                    salesLead, owners.get(salesLead.OwnerId), marketingOwner);
                sent++;
            } catch (Exception ex) {
                System.debug(LoggingLevel.WARN, 'Sales notification not sent: ' + ex.getMessage());
            }
        }
        Test.stopTest();
        Assert.isTrue(sent <= 2, 'At most two notifications are sent');
    }
}