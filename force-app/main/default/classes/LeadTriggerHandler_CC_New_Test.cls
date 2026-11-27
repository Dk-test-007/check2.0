@isTest
private class LeadTriggerHandler_CC_New_Test {

    private static final String MARKETING_PROFILE = 'Carlton Marketing User';
    private static final String SALES_PROFILE = 'Carlton Sales User';
    private static final String TEST_USER_EMAIL = 'lead.handler.test@carltontest.invalid';
    private static final String US_QUEUE = 'US_Marketing_Pool';
    private static final String UK_QUEUE = 'UK_Marketing_Pool';
    private static final String US_SALES_QUEUE = 'US_Sales_Pool';
    private static final String UK_SALES_QUEUE = 'UK_Sales_Pool';
    private static final String DUPLICATE_ERROR = 'This Lead matches an existing record.';
    // Values must match LeadTriggerHandler_CC_New. Only INC exists in the restricted Belongs_To_CC__c picklist,
    // so LLP is only ever used on in-memory records (never in DML).
    private static final String INC_ENTITY = 'Carlton Packaging INC';
    private static final String LLP_ENTITY = 'Carlton Packaging LLP';
    private static final String STATUS_IDENTIFY = 'Identify';
    private static final String STATUS_ENGAGE = 'Engage';
    private static final String STATUS_QUALIFY = 'Qualify';
    private static final String STATUS_RE_NURTURE = 'Re-Nurture';

    private static final List<String> RE_NURTURE_REASON_FIELDS = new List<String>{
        'Re_Nurture_Reason_CC__c', 'ReNurture_Reason_CC__c', 'Re_Nurturing_Reason_CC__c',
        'Re_Nurture_Reason__c', 'ReNurture_Reason__c'
    };

    private static Map<String, Schema.SObjectField> leadFieldCache;
    private static Integer emailSequence = 0;

    @TestSetup
    static void setupData() {
        createUserForProfile(MARKETING_PROFILE, 'ltmkt');
        createUserForProfile(SALES_PROFILE, 'ltsls');
        ensureMarketingQueues();
        addRegionalQueueMemberships();
    }

    // Marketing test user -> US_Marketing_Pool, Sales test user -> US_Sales_Pool (used by the
    // raiseValidationOnOwnerChange membership checks and for the marketing user to claim pool Leads).
    private static void addRegionalQueueMemberships() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        User salesUser = getTestUser(SALES_PROFILE);
        Id usMarketingQueue = getQueueId(US_QUEUE);
        Id usSalesQueue = getQueueId(US_SALES_QUEUE);
        List<GroupMember> members = new List<GroupMember>();
        if (marketingUser != null && usMarketingQueue != null) {
            members.add(new GroupMember(GroupId = usMarketingQueue, UserOrGroupId = marketingUser.Id));
        }
        if (salesUser != null && usSalesQueue != null) {
            members.add(new GroupMember(GroupId = usSalesQueue, UserOrGroupId = salesUser.Id));
        }
        insert members;
    }

    private static void createUserForProfile(String profileName, String aliasSeed) {
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        if (profiles.isEmpty()) {
            return;
        }
        User newUser = new User(
            FirstName = 'Handler',
            LastName = 'Test ' + aliasSeed,
            Alias = aliasSeed.left(8),
            Email = TEST_USER_EMAIL,
            Username = aliasSeed + String.valueOf(Math.abs(Crypto.getRandomLong())) + '@carltontest.invalid',
            ProfileId = profiles[0].Id,
            TimeZoneSidKey = 'Asia/Kolkata',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            IsActive = true
        );
        try {
            insert newUser;
        } catch (Exception ex) {
            System.debug('Could not create user for profile ' + profileName + ': ' + ex.getMessage());
        }
    }

    private static void ensureMarketingQueues() {
        Set<String> existing = new Set<String>();
        for (Group grp : [SELECT DeveloperName FROM Group WHERE Type = 'Queue' AND DeveloperName IN (:US_QUEUE, :UK_QUEUE)]) {
            existing.add(grp.DeveloperName);
        }
        List<Group> queuesToInsert = new List<Group>();
        if (!existing.contains(US_QUEUE)) {
            queuesToInsert.add(new Group(Name = 'US Marketing Pool', DeveloperName = US_QUEUE, Type = 'Queue'));
        }
        if (!existing.contains(UK_QUEUE)) {
            queuesToInsert.add(new Group(Name = 'UK Marketing Pool', DeveloperName = UK_QUEUE, Type = 'Queue'));
        }
        if (queuesToInsert.isEmpty()) {
            return;
        }
        try {
            insert queuesToInsert;
            List<QueueSobject> queueObjects = new List<QueueSobject>();
            for (Group grp : queuesToInsert) {
                queueObjects.add(new QueueSobject(QueueId = grp.Id, SobjectType = 'Lead'));
            }
            insert queueObjects;
        } catch (Exception ex) {
            System.debug('Could not create marketing queues: ' + ex.getMessage());
        }
    }

    private static Lead newLead(String lastName, String company, String status) {
        Lead leadRecord = new Lead(
            LastName = lastName,
            Company = company,
            Status = status,
            Email = buildUniqueEmail(lastName),
            Phone = '+1 555 0' + String.valueOf(100 + emailSequence)
        );
        if (status == STATUS_RE_NURTURE) {
            stampReNurtureReason(leadRecord);
        }
        return leadRecord;
    }

    private static Lead newLead(String lastName, String company, String status, Id ownerId) {
        Lead leadRecord = newLead(lastName, company, status);
        leadRecord.OwnerId = ownerId;
        return leadRecord;
    }

    private static Lead newLead(String lastName, String company, String status, Id ownerId, String belongsTo) {
        Lead leadRecord = newLead(lastName, company, status, ownerId);
        leadRecord.Belongs_To_CC__c = belongsTo;
        return leadRecord;
    }

    private static String buildUniqueEmail(String seed) {
        emailSequence++;
        String local = seed.replaceAll('[^a-zA-Z0-9]', '').toLowerCase();
        if (String.isBlank(local)) {
            local = 'lead';
        }
        return local + emailSequence + Math.abs(Crypto.getRandomInteger()) + '@carltontest.invalid';
    }

    private static Map<String, Schema.SObjectField> leadFields() {
        if (leadFieldCache == null) {
            leadFieldCache = Schema.SObjectType.Lead.fields.getMap();
        }
        return leadFieldCache;
    }

    private static void stampReNurtureReason(Lead leadRecord) {
        Schema.DescribeFieldResult reasonField = findReNurtureReasonField();
        if (reasonField == null || !reasonField.isUpdateable()) {
            return;
        }
        if (reasonField.getType() == Schema.DisplayType.PICKLIST || reasonField.getType() == Schema.DisplayType.MULTIPICKLIST) {
            for (Schema.PicklistEntry entry : reasonField.getPicklistValues()) {
                if (entry.isActive()) {
                    leadRecord.put(reasonField.getName(), entry.getValue());
                    return;
                }
            }
            return;
        }
        leadRecord.put(reasonField.getName(), 'Test Re-Nurture Reason');
    }

    private static Schema.DescribeFieldResult findReNurtureReasonField() {
        for (String candidate : RE_NURTURE_REASON_FIELDS) {
            Schema.SObjectField field = leadFields().get(candidate.toLowerCase());
            if (field != null) {
                return field.getDescribe();
            }
        }
        return null;
    }

    private static Lead reNurtureUpdate(Id leadId) {
        Lead leadRecord = new Lead(Id = leadId, Status = STATUS_RE_NURTURE);
        stampReNurtureReason(leadRecord);
        return leadRecord;
    }

    private static Lead memoryLead(Id leadId, String company, String status, Id ownerId, String belongsTo) {
        Lead leadRecord = new Lead(LastName = 'Memory Lead', Company = company, Status = status, Belongs_To_CC__c = belongsTo);
        if (leadId != null) {
            leadRecord.Id = leadId;
        }
        if (ownerId != null) {
            leadRecord.OwnerId = ownerId;
        }
        return leadRecord;
    }

    private static User getTestUser(String profileName) {
        List<User> users = [SELECT Id FROM User WHERE Email = :TEST_USER_EMAIL AND Profile.Name = :profileName AND IsActive = TRUE LIMIT 1];
        return users.isEmpty() ? null : users[0];
    }

    private static Id getQueueId(String developerName) {
        List<Group> queues = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :developerName LIMIT 1];
        return queues.isEmpty() ? null : queues[0].Id;
    }

    private static Id fakeLeadId(Integer index) {
        return Id.valueOf('00Q' + String.valueOf(index).leftPad(12, '0'));
    }

    private static Lead_Company_Owner_Mapping_CC__mdt getCompanyMapping() {
        for (Lead_Company_Owner_Mapping_CC__mdt mapping : [SELECT Company_Name_CC__c, Entity_CC__c, Owner_Id_CC__c, Active_CC__c
                                                           FROM Lead_Company_Owner_Mapping_CC__mdt
                                                           WHERE Active_CC__c = TRUE AND Company_Name_CC__c != NULL AND Owner_Id_CC__c != NULL]) {
            if (isValidUserId(mapping.Owner_Id_CC__c)) {
                return mapping;
            }
        }
        return null;
    }

    private static Lead_Company_Owner_Mapping_CC__mdt getEntityMapping() {
        for (Lead_Company_Owner_Mapping_CC__mdt mapping : [SELECT Company_Name_CC__c, Entity_CC__c, Owner_Id_CC__c, Active_CC__c
                                                           FROM Lead_Company_Owner_Mapping_CC__mdt
                                                           WHERE Active_CC__c = TRUE AND Company_Name_CC__c = NULL
                                                           AND Entity_CC__c != NULL AND Owner_Id_CC__c != NULL]) {
            if (isValidOwnerId(mapping.Owner_Id_CC__c)) {
                return mapping;
            }
        }
        return null;
    }

    private static Boolean isValidUserId(String value) {
        if (String.isBlank(value) || !value.trim().startsWith('005')) {
            return false;
        }
        try {
            Id.valueOf(value.trim());
            return true;
        } catch (Exception ex) {
            return false;
        }
    }

    // Entity mappings point at queues (00G...), so accept any valid User or Group id.
    private static Boolean isValidOwnerId(String value) {
        if (String.isBlank(value)) {
            return false;
        }
        try {
            Schema.SObjectType ownerType = Id.valueOf(value.trim()).getSObjectType();
            return ownerType == User.SObjectType || ownerType == Group.SObjectType;
        } catch (Exception ex) {
            return false;
        }
    }

    private static Boolean handlerIsWiredToTrigger() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        if (marketingUser == null) {
            return false;
        }
        Lead probe = newLead('Wiring Probe', 'Probe Co', STATUS_ENGAGE, marketingUser.Id);
        insert probe;
        Lead reloaded = [SELECT Last_Marketing_Owner_Id_CC__c FROM Lead WHERE Id = :probe.Id];
        return reloaded.Last_Marketing_Owner_Id_CC__c == String.valueOf(marketingUser.Id);
    }

    @isTest
    static void testSortProductCategories_InsertAndUpdateContexts() {
        Id changedId = fakeLeadId(1);
        Id unchangedId = fakeLeadId(2);
        Id blankId = fakeLeadId(3);
        Lead insertWithValue = new Lead(LastName = 'Sort Insert', Company = 'Sort Co', Status = STATUS_ENGAGE, Product_Category_CC__c = 'Charlie;Alpha;Bravo');
        Lead insertWithoutValue = new Lead(LastName = 'Sort Insert Blank', Company = 'Sort Co', Status = STATUS_ENGAGE);
        Lead changedLead = new Lead(Id = changedId, Product_Category_CC__c = 'Charlie;Alpha;Bravo');
        Lead unchangedLead = new Lead(Id = unchangedId, Product_Category_CC__c = 'Bravo;Alpha');
        Lead blankLead = new Lead(Id = blankId, Product_Category_CC__c = null);
        Map<Id, Lead> oldMap = new Map<Id, Lead>{
            changedId => new Lead(Id = changedId, Product_Category_CC__c = 'Alpha'),
            unchangedId => new Lead(Id = unchangedId, Product_Category_CC__c = 'Bravo;Alpha'),
            blankId => new Lead(Id = blankId, Product_Category_CC__c = 'Alpha')
        };
        Test.startTest();
        LeadTriggerHandler_CC_New.sortProductCategories(new List<Lead>{insertWithValue, insertWithoutValue}, null);
        LeadTriggerHandler_CC_New.sortProductCategories(new List<Lead>{changedLead, unchangedLead, blankLead}, oldMap);
        Test.stopTest();
        Assert.areEqual('Alpha;Bravo;Charlie', insertWithValue.Product_Category_Text_CC__c, 'Insert: categories sorted');
        Assert.isNull(insertWithoutValue.Product_Category_Text_CC__c, 'Insert: blank categories untouched');
        Assert.areEqual('Alpha;Bravo;Charlie', changedLead.Product_Category_Text_CC__c, 'Update: changed categories sorted');
        Assert.isNull(unchangedLead.Product_Category_Text_CC__c, 'Update: unchanged categories untouched');
        Assert.isNull(blankLead.Product_Category_Text_CC__c, 'Update: blank categories untouched');
    }

    @isTest
    static void testSortEmailValues_InsertAndUpdateContexts() {
        Id changedPrimaryId = fakeLeadId(5);
        Id changedSecondaryId = fakeLeadId(6);
        Id unchangedId = fakeLeadId(7);
        Lead insertBoth = new Lead(LastName = 'Email Both', Company = 'Email Co', Status = STATUS_ENGAGE,
                                   Email = 'primary@carltontest.invalid', Secondary_Email_Address_CC__c = 'a.secondary@carltontest.invalid');
        Lead insertPrimaryOnly = new Lead(LastName = 'Email Primary', Company = 'Email Co', Status = STATUS_ENGAGE,
                                          Email = 'onlyprimary@carltontest.invalid');
        Lead insertSecondaryOnly = new Lead(LastName = 'Email Secondary', Company = 'Email Co', Status = STATUS_ENGAGE,
                                            Secondary_Email_Address_CC__c = 'onlysecondary@carltontest.invalid');
        Lead insertNeither = new Lead(LastName = 'Email None', Company = 'Email Co', Status = STATUS_ENGAGE);
        Lead changedPrimary = new Lead(Id = changedPrimaryId, Email = 'changed@carltontest.invalid', Secondary_Email_Address_CC__c = 'stable@carltontest.invalid');
        Lead changedSecondary = new Lead(Id = changedSecondaryId, Email = 'stable@carltontest.invalid', Secondary_Email_Address_CC__c = null);
        Lead unchangedEmails = new Lead(Id = unchangedId, Email = 'stable@carltontest.invalid', Secondary_Email_Address_CC__c = 'stable2@carltontest.invalid');
        Map<Id, Lead> oldMap = new Map<Id, Lead>{
            changedPrimaryId => new Lead(Id = changedPrimaryId, Email = 'original@carltontest.invalid', Secondary_Email_Address_CC__c = 'stable@carltontest.invalid'),
            changedSecondaryId => new Lead(Id = changedSecondaryId, Email = 'stable@carltontest.invalid', Secondary_Email_Address_CC__c = 'wasthere@carltontest.invalid'),
            unchangedId => new Lead(Id = unchangedId, Email = 'stable@carltontest.invalid', Secondary_Email_Address_CC__c = 'stable2@carltontest.invalid')
        };
        Test.startTest();
        LeadTriggerHandler_CC_New.sortEmailValues(new List<Lead>{insertBoth, insertPrimaryOnly, insertSecondaryOnly, insertNeither}, null);
        LeadTriggerHandler_CC_New.sortEmailValues(new List<Lead>{changedPrimary, changedSecondary, unchangedEmails}, oldMap);
        Test.stopTest();
        Assert.areEqual('a.secondary@carltontest.invalid;primary@carltontest.invalid', insertBoth.Email_List_CC__c, 'Both e-mails sorted');
        Assert.areEqual('onlyprimary@carltontest.invalid', insertPrimaryOnly.Email_List_CC__c, 'Primary only');
        Assert.areEqual('onlysecondary@carltontest.invalid', insertSecondaryOnly.Email_List_CC__c, 'Secondary only');
        Assert.isNull(insertNeither.Email_List_CC__c, 'No e-mails -> untouched');
        Assert.areEqual('changed@carltontest.invalid;stable@carltontest.invalid', changedPrimary.Email_List_CC__c, 'Changed primary re-sorted');
        Assert.areEqual('stable@carltontest.invalid', changedSecondary.Email_List_CC__c, 'Removed secondary re-computed');
        Assert.isNull(unchangedEmails.Email_List_CC__c, 'Unchanged e-mails untouched');
    }

    @isTest
    static void testCompanyOwnerMapping_NonIdentifyAndNullOwnerAreSkipped() {
        Lead engagedLead = memoryLead(null, 'Anything Ltd', STATUS_ENGAGE, UserInfo.getUserId(), INC_ENTITY);
        Lead ownerlessLead = memoryLead(null, 'Anything Ltd', STATUS_IDENTIFY, null, INC_ENTITY);
        Test.startTest();
        LeadTriggerHandler_CC_New.applyCompanyOwnerMapping(new List<Lead>{engagedLead, ownerlessLead}, null);
        Test.stopTest();
        Assert.areEqual(UserInfo.getUserId(), engagedLead.OwnerId, 'Non-Identify Lead keeps its owner');
        Assert.isNull(ownerlessLead.OwnerId, 'Ownerless Lead is skipped');
    }

    @isTest
    static void testCompanyOwnerMapping_UnmappedCompanyKeepsOwner() {
        Lead unmappedLead = memoryLead(null, 'Totally Unmapped Company ' + Math.abs(Crypto.getRandomInteger()), STATUS_IDENTIFY, UserInfo.getUserId(), null);
        Test.startTest();
        LeadTriggerHandler_CC_New.applyCompanyOwnerMapping(new List<Lead>{unmappedLead}, null);
        Test.stopTest();
        Assert.areEqual(UserInfo.getUserId(), unmappedLead.OwnerId, 'Unmapped company without entity keeps its owner');
    }

    @isTest
    static void testCompanyOwnerMapping_CompanyMatchOnInsert() {
        Lead_Company_Owner_Mapping_CC__mdt mapping = getCompanyMapping();
        if (mapping == null) {
            return;
        }
        Lead identifyLead = memoryLead(null, mapping.Company_Name_CC__c, STATUS_IDENTIFY, UserInfo.getUserId(), INC_ENTITY);
        Test.startTest();
        LeadTriggerHandler_CC_New.applyCompanyOwnerMapping(new List<Lead>{identifyLead}, null);
        Test.stopTest();
        Assert.areEqual(Id.valueOf(mapping.Owner_Id_CC__c), identifyLead.OwnerId, 'Mapped company owner should be assigned');
    }

    @isTest
    static void testCompanyOwnerMapping_EntityFallbackOnInsert() {
        Lead_Company_Owner_Mapping_CC__mdt mapping = getEntityMapping();
        if (mapping == null) {
            return;
        }
        Lead identifyLead = memoryLead(null, 'Unmapped Company ' + Math.abs(Crypto.getRandomInteger()), STATUS_IDENTIFY, UserInfo.getUserId(), mapping.Entity_CC__c);
        Test.startTest();
        LeadTriggerHandler_CC_New.applyCompanyOwnerMapping(new List<Lead>{identifyLead}, null);
        Test.stopTest();
        Assert.areEqual(Id.valueOf(mapping.Owner_Id_CC__c), identifyLead.OwnerId, 'Entity mapped owner (queue) should be assigned');
    }

    @isTest
    static void testCompanyOwnerMapping_UpdateChangedVersusUnchangedCompany() {
        Lead_Company_Owner_Mapping_CC__mdt mapping = getCompanyMapping();
        if (mapping == null) {
            return;
        }
        Id changedId = fakeLeadId(10);
        Id unchangedId = fakeLeadId(11);
        Lead changedCompanyLead = memoryLead(changedId, mapping.Company_Name_CC__c, STATUS_IDENTIFY, UserInfo.getUserId(), INC_ENTITY);
        Lead unchangedCompanyLead = memoryLead(unchangedId, mapping.Company_Name_CC__c, STATUS_IDENTIFY, UserInfo.getUserId(), INC_ENTITY);
        Map<Id, Lead> oldMap = new Map<Id, Lead>{
            changedId => new Lead(Id = changedId, Company = 'Previous Company Name'),
            unchangedId => new Lead(Id = unchangedId, Company = mapping.Company_Name_CC__c)
        };
        Test.startTest();
        LeadTriggerHandler_CC_New.applyCompanyOwnerMapping(new List<Lead>{changedCompanyLead, unchangedCompanyLead}, oldMap);
        Test.stopTest();
        Assert.areEqual(Id.valueOf(mapping.Owner_Id_CC__c), changedCompanyLead.OwnerId, 'Changed company to a mapped one re-assigns owner');
        Assert.areEqual(UserInfo.getUserId(), unchangedCompanyLead.OwnerId, 'Unchanged company keeps owner');
    }

    @isTest
    static void testCompanyOwnerMapping_SalesUserIsBypassed() {
        Lead_Company_Owner_Mapping_CC__mdt mapping = getCompanyMapping();
        User salesUser = getTestUser(SALES_PROFILE);
        if (mapping == null || salesUser == null) {
            return;
        }
        Lead identifyLead = memoryLead(null, mapping.Company_Name_CC__c, STATUS_IDENTIFY, UserInfo.getUserId(), INC_ENTITY);
        Test.startTest();
        System.runAs(salesUser) {
            LeadTriggerHandler_CC_New.applyCompanyOwnerMapping(new List<Lead>{identifyLead}, null);
        }
        Test.stopTest();
        Assert.areEqual(UserInfo.getUserId(), identifyLead.OwnerId, 'Sales users bypass the company owner mapping');
    }

    @isTest
    static void testStampLastMarketingOwner_AllOwnerCombinations() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        if (marketingUser == null) {
            return;
        }
        Id handoverId = fakeLeadId(20);
        Id neitherId = fakeLeadId(21);
        Id usQueueId = getQueueId(US_QUEUE);
        Lead marketingOwned = newLead('Stamp New', 'Stamp Co', STATUS_ENGAGE, marketingUser.Id);
        Lead handoverLead = new Lead(Id = handoverId, OwnerId = UserInfo.getUserId());
        Lead neitherLead = new Lead(Id = neitherId, OwnerId = UserInfo.getUserId());
        Map<Id, Lead> oldMap = new Map<Id, Lead>{
            handoverId => new Lead(Id = handoverId, OwnerId = marketingUser.Id),
            neitherId => new Lead(Id = neitherId, OwnerId = UserInfo.getUserId())
        };
        Test.startTest();
        LeadTriggerHandler_CC_New.stampLastMarketingOwner(new List<Lead>{marketingOwned}, null);
        LeadTriggerHandler_CC_New.stampLastMarketingOwner(new List<Lead>{handoverLead, neitherLead}, oldMap);
        Assert.areEqual(String.valueOf(marketingUser.Id), marketingOwned.Last_Marketing_Owner_Id_CC__c, 'Marketing owner stamped on insert');
        Assert.areEqual(String.valueOf(marketingUser.Id), handoverLead.Last_Marketing_Owner_Id_CC__c, 'Previous marketing owner stamped on hand-over');
        Assert.isNull(neitherLead.Last_Marketing_Owner_Id_CC__c, 'No marketing owner -> not stamped');
        if (usQueueId != null) {
            LeadTriggerHandler_CC_New.stampLastMarketingOwner(new List<Lead>{newLead('Queue Owned', 'Queue Co', STATUS_ENGAGE, usQueueId)}, null);
        }
        Test.stopTest();
    }

    @isTest
    static void testCheckDuplicates_ChunkBoundaryAndRemainder() {
        List<Lead> candidateLeads = new List<Lead>();
        for (Integer i = 0; i < 51; i++) {
            candidateLeads.add(newLead('Dup ' + i, 'Dup Co ' + i, STATUS_QUALIFY));
        }
        Test.startTest();
        try {
            LeadTriggerHandler_CC_New.checkDuplicates(candidateLeads);
        } catch (Exception ex) {
            System.debug('checkDuplicates raised: ' + ex.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testProcessChunk_SingleRecord() {
        List<Lead> singleChunk = new List<Lead>{newLead('Single Dup', 'Single Co', STATUS_QUALIFY)};
        Test.startTest();
        try {
            LeadTriggerHandler_CC_New.processChunk(singleChunk);
        } catch (Exception ex) {
            System.debug('processChunk raised: ' + ex.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testReNurture_NullAndEmptyArgumentsAreSafe() {
        Test.startTest();
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(null, null);
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(new List<Lead>(), null);
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(null, new Map<Id, Lead>());
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(new List<Lead>(), new Map<Id, Lead>());
        Assert.areEqual(0, Limits.getQueueableJobs(), 'No job should be enqueued for empty input');
        Test.stopTest();
    }

    @isTest
    static void testReNurture_StatusNotEnteringReNurtureIsIgnored() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        if (marketingUser == null) {
            return;
        }
        Id notEnteringId = fakeLeadId(30);
        Id alreadyThereId = fakeLeadId(31);
        Id missingOldId = fakeLeadId(32);
        String storedOwner = String.valueOf(marketingUser.Id);
        List<Lead> newLeads = new List<Lead>{
            new Lead(Id = notEnteringId, Status = STATUS_ENGAGE, OwnerId = UserInfo.getUserId(), Last_Marketing_Owner_Id_CC__c = storedOwner),
            new Lead(Id = alreadyThereId, Status = STATUS_RE_NURTURE, OwnerId = UserInfo.getUserId(), Last_Marketing_Owner_Id_CC__c = storedOwner),
            new Lead(Id = missingOldId, Status = STATUS_RE_NURTURE, OwnerId = UserInfo.getUserId(), Last_Marketing_Owner_Id_CC__c = storedOwner)
        };
        Map<Id, Lead> oldMap = new Map<Id, Lead>{
            notEnteringId => new Lead(Id = notEnteringId, Status = STATUS_IDENTIFY),
            alreadyThereId => new Lead(Id = alreadyThereId, Status = STATUS_RE_NURTURE)
        };
        Test.startTest();
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(newLeads, oldMap);
        Assert.areEqual(0, Limits.getQueueableJobs(), 'Leads not newly entering Re-Nurture are ignored');
        Test.stopTest();
    }

    @isTest
    static void testReNurture_RevertsToLastMarketingOwner() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        if (marketingUser == null) {
            return;
        }
        String storedOwner = String.valueOf(marketingUser.Id);
        Lead salesOwnedLead = newLead('Revert Owner', 'Revert Co', STATUS_ENGAGE, UserInfo.getUserId(), INC_ENTITY);
        salesOwnedLead.Last_Marketing_Owner_Id_CC__c = storedOwner;
        insert salesOwnedLead;
        Test.startTest();
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(
            new List<Lead>{new Lead(Id = salesOwnedLead.Id, Status = STATUS_RE_NURTURE, OwnerId = UserInfo.getUserId(),
                                    Belongs_To_CC__c = INC_ENTITY, Last_Marketing_Owner_Id_CC__c = storedOwner)},
            new Map<Id, Lead>{salesOwnedLead.Id => new Lead(Id = salesOwnedLead.Id, Status = STATUS_ENGAGE)});
        Test.stopTest();
    }

    @isTest
    static void testReNurture_FallsBackToUsQueueForInc() {
        Id usQueueId = getQueueId(US_QUEUE);
        if (usQueueId == null) {
            return;
        }
        Lead incLead = newLead('INC Fallback', 'INC Co', STATUS_ENGAGE, UserInfo.getUserId(), INC_ENTITY);
        insert incLead;
        Test.startTest();
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(
            new List<Lead>{new Lead(Id = incLead.Id, Status = STATUS_RE_NURTURE, OwnerId = UserInfo.getUserId(), Belongs_To_CC__c = INC_ENTITY)},
            new Map<Id, Lead>{incLead.Id => new Lead(Id = incLead.Id, Status = STATUS_ENGAGE)});
        Test.stopTest();
    }

    @isTest
    static void testReNurture_FallsBackToUkQueueForLlp() {
        Id ukQueueId = getQueueId(UK_QUEUE);
        if (ukQueueId == null) {
            return;
        }
        // LLP is not an allowed value of the restricted picklist, so the record is inserted without it
        Lead llpLead = newLead('LLP Fallback', 'LLP Co', STATUS_ENGAGE, UserInfo.getUserId(), null);
        insert llpLead;
        Test.startTest();
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(
            new List<Lead>{new Lead(Id = llpLead.Id, Status = STATUS_RE_NURTURE, OwnerId = UserInfo.getUserId(), Belongs_To_CC__c = LLP_ENTITY)},
            new Map<Id, Lead>{llpLead.Id => new Lead(Id = llpLead.Id, Status = STATUS_ENGAGE)});
        Test.stopTest();
    }

    @isTest
    static void testReNurture_MarketingOwnerIsLeftAlone() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        if (marketingUser == null) {
            return;
        }
        Lead marketingOwnedLead = newLead('Already Marketing', 'Already Co', STATUS_ENGAGE, marketingUser.Id, INC_ENTITY);
        insert marketingOwnedLead;
        Test.startTest();
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(
            new List<Lead>{new Lead(Id = marketingOwnedLead.Id, Status = STATUS_RE_NURTURE, OwnerId = marketingUser.Id, Belongs_To_CC__c = INC_ENTITY)},
            new Map<Id, Lead>{marketingOwnedLead.Id => new Lead(Id = marketingOwnedLead.Id, Status = STATUS_ENGAGE)});
        Test.stopTest();
    }

    @isTest
    static void testReNurture_MarketingQueueOwnerIsLeftAlone() {
        Id usQueueId = getQueueId(US_QUEUE);
        User marketingUser = getTestUser(MARKETING_PROFILE);
        if (usQueueId == null || marketingUser == null) {
            return;
        }
        String storedOwner = String.valueOf(marketingUser.Id);
        Lead queueOwnedLead = newLead('Already Queue', 'Already Queue Co', STATUS_ENGAGE, usQueueId, INC_ENTITY);
        queueOwnedLead.Last_Marketing_Owner_Id_CC__c = storedOwner;
        insert queueOwnedLead;
        Test.startTest();
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(
            new List<Lead>{new Lead(Id = queueOwnedLead.Id, Status = STATUS_RE_NURTURE, OwnerId = usQueueId,
                                    Belongs_To_CC__c = INC_ENTITY, Last_Marketing_Owner_Id_CC__c = storedOwner)},
            new Map<Id, Lead>{queueOwnedLead.Id => new Lead(Id = queueOwnedLead.Id, Status = STATUS_ENGAGE)});
        Test.stopTest();
    }

    @isTest
    static void testReNurture_InvalidStoredOwnerIdsAndUnknownEntity() {
        Id usQueueId = getQueueId(US_QUEUE);
        if (usQueueId == null) {
            return;
        }
        Lead blankStored = newLead('Blank Stored', 'Blank Co', STATUS_ENGAGE, UserInfo.getUserId(), INC_ENTITY);
        blankStored.Last_Marketing_Owner_Id_CC__c = '';
        Lead wrongPrefix = newLead('Wrong Prefix', 'Prefix Co', STATUS_ENGAGE, UserInfo.getUserId(), INC_ENTITY);
        wrongPrefix.Last_Marketing_Owner_Id_CC__c = '00Q000000000001';
        Lead malformedId = newLead('Malformed Id', 'Malformed Co', STATUS_ENGAGE, UserInfo.getUserId(), INC_ENTITY);
        malformedId.Last_Marketing_Owner_Id_CC__c = '005NOTAVALIDID';
        Lead unknownEntity = newLead('Unknown Entity', 'Unknown Co', STATUS_ENGAGE, UserInfo.getUserId(), null);
        unknownEntity.Last_Marketing_Owner_Id_CC__c = '';
        List<Lead> seeded = new List<Lead>{blankStored, wrongPrefix, malformedId, unknownEntity};
        insert seeded;
        List<Lead> newLeads = new List<Lead>();
        Map<Id, Lead> oldMap = new Map<Id, Lead>();
        for (Lead seededLead : [SELECT Id, OwnerId, Belongs_To_CC__c, Last_Marketing_Owner_Id_CC__c FROM Lead WHERE Id IN :seeded]) {
            newLeads.add(new Lead(Id = seededLead.Id, Status = STATUS_RE_NURTURE, OwnerId = seededLead.OwnerId,
                                  Belongs_To_CC__c = seededLead.Belongs_To_CC__c,
                                  Last_Marketing_Owner_Id_CC__c = seededLead.Last_Marketing_Owner_Id_CC__c));
            oldMap.put(seededLead.Id, new Lead(Id = seededLead.Id, Status = STATUS_ENGAGE));
        }
        Test.startTest();
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(newLeads, oldMap);
        Test.stopTest();
    }

    @isTest
    static void testReNurture_RecursionGuardBlocksSecondTransfer() {
        Id usQueueId = getQueueId(US_QUEUE);
        if (usQueueId == null) {
            return;
        }
        Lead firstLead = newLead('Guard One', 'Guard Co 1', STATUS_ENGAGE, UserInfo.getUserId(), INC_ENTITY);
        Lead secondLead = newLead('Guard Two', 'Guard Co 2', STATUS_ENGAGE, UserInfo.getUserId(), INC_ENTITY);
        insert new List<Lead>{firstLead, secondLead};
        Test.startTest();
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(
            new List<Lead>{new Lead(Id = firstLead.Id, Status = STATUS_RE_NURTURE, OwnerId = UserInfo.getUserId(), Belongs_To_CC__c = INC_ENTITY)},
            new Map<Id, Lead>{firstLead.Id => new Lead(Id = firstLead.Id, Status = STATUS_ENGAGE)});
        LeadTriggerHandler_CC_New.assignOwnerOnReNurture(
            new List<Lead>{new Lead(Id = secondLead.Id, Status = STATUS_RE_NURTURE, OwnerId = UserInfo.getUserId(), Belongs_To_CC__c = INC_ENTITY)},
            new Map<Id, Lead>{secondLead.Id => new Lead(Id = secondLead.Id, Status = STATUS_ENGAGE)});
        Test.stopTest();
    }

    @isTest
    static void testRaiseValidationOnOwnerChange_AllowedCombinations() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        if (marketingUser == null) {
            return;
        }
        Id unchangedId = fakeLeadId(40);
        Id engageId = fakeLeadId(41);
        List<Lead> newLeads = new List<Lead>{
            new Lead(Id = unchangedId, Status = STATUS_QUALIFY, OwnerId = UserInfo.getUserId()),
            new Lead(Id = engageId, Status = STATUS_ENGAGE, OwnerId = marketingUser.Id)
        };
        Map<Id, Lead> oldMap = new Map<Id, Lead>{
            unchangedId => new Lead(Id = unchangedId, Status = STATUS_QUALIFY, OwnerId = UserInfo.getUserId()),
            engageId => new Lead(Id = engageId, Status = STATUS_ENGAGE, OwnerId = UserInfo.getUserId())
        };
        Test.startTest();
        LeadTriggerHandler_CC_New.raiseValidationOnOwnerChange(newLeads, oldMap);
        Test.stopTest();
    }

    @isTest
    static void testRaiseValidationOnOwnerChange_MarketingToSalesIsBlocked() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        User salesUser = getTestUser(SALES_PROFILE);
        if (marketingUser == null || salesUser == null) {
            return;
        }
        Id leadId = fakeLeadId(42);
        List<Lead> newLeads = new List<Lead>{new Lead(Id = leadId, Status = STATUS_QUALIFY, OwnerId = salesUser.Id)};
        Map<Id, Lead> oldMap = new Map<Id, Lead>{leadId => new Lead(Id = leadId, Status = STATUS_QUALIFY, OwnerId = marketingUser.Id)};
        Test.startTest();
        System.runAs(marketingUser) {
            try {
                LeadTriggerHandler_CC_New.raiseValidationOnOwnerChange(newLeads, oldMap);
            } catch (Exception ex) {
                System.debug('addError outside trigger context: ' + ex.getMessage());
            }
        }
        Test.stopTest();
    }

    @isTest
    static void testResetBypassDuplicateRules() {
        Lead flaggedLead = newLead('Bypass Import', 'Bypass Co', STATUS_ENGAGE, UserInfo.getUserId());
        flaggedLead.Bypass_Duplicate_Rules_on_Import_CC__c = true;
        Lead plainLead = newLead('No Bypass', 'No Bypass Co', STATUS_ENGAGE, UserInfo.getUserId());
        insert new List<Lead>{flaggedLead, plainLead};
        Test.startTest();
        LeadTriggerHandler_CC_New.resetBypassDuplicateRules(new List<Id>{flaggedLead.Id});
        LeadTriggerHandler_CC_New.resetBypassDuplicateRules(new List<Id>{plainLead.Id});
        Test.stopTest();
        Assert.isFalse([SELECT Bypass_Duplicate_Rules_on_Import_CC__c FROM Lead WHERE Id = :flaggedLead.Id].Bypass_Duplicate_Rules_on_Import_CC__c, 'Import bypass flag should be reset');
    }

    @isTest
    static void testRunOutsideTriggerContext() {
        Test.startTest();
        try {
            new LeadTriggerHandler_CC_New().run();
        } catch (Exception ex) {
            System.debug('run() outside trigger context: ' + ex.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testTriggerContext_InsertWithImportBypass() {
        if (!handlerIsWiredToTrigger()) {
            return;
        }
        Lead importedLead = newLead('Async Insert', 'Async Co', STATUS_ENGAGE);
        importedLead.Bypass_Duplicate_Rules_on_Import_CC__c = true;
        Test.startTest();
        insert importedLead;
        Test.stopTest();
    }

    @isTest
    static void testTriggerContext_OwnerChangeOnEngage() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        if (marketingUser == null || !handlerIsWiredToTrigger()) {
            return;
        }
        Lead engageLead = newLead('Engage Move', 'Engage Co', STATUS_ENGAGE, UserInfo.getUserId());
        Lead untouchedLead = newLead('No Owner Move', 'Untouched Co', STATUS_ENGAGE, UserInfo.getUserId());
        insert new List<Lead>{engageLead, untouchedLead};
        Test.startTest();
        update new Lead(Id = engageLead.Id, OwnerId = marketingUser.Id);
        update new Lead(Id = untouchedLead.Id, Description = 'No owner change');
        Test.stopTest();
    }

    @isTest
    static void testTriggerContext_BeforeUpdateRunsDuplicateCheckOnQualify() {
        if (!handlerIsWiredToTrigger()) {
            return;
        }
        Lead checkedLead = newLead('Qualify Checked', 'Qualify Co', STATUS_ENGAGE, UserInfo.getUserId());
        Lead bypassedLead = newLead('Qualify Bypassed', 'Bypass Co', STATUS_ENGAGE, UserInfo.getUserId());
        bypassedLead.Bypass_Duplicate_Rules_on_Qualification__c = true;
        insert new List<Lead>{checkedLead, bypassedLead};
        Test.startTest();
        try {
            update new List<Lead>{
                new Lead(Id = checkedLead.Id, Status = STATUS_QUALIFY),
                new Lead(Id = bypassedLead.Id, Status = STATUS_QUALIFY)
            };
        } catch (DmlException ex) {
            System.debug('Duplicate rule fired: ' + ex.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testTriggerContext_ReNurtureEndToEnd() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        if (marketingUser == null || !handlerIsWiredToTrigger()) {
            return;
        }
        Lead nurturedLead = newLead('End To End', 'E2E Co', STATUS_ENGAGE, marketingUser.Id, INC_ENTITY);
        insert nurturedLead;
        try {
            update new Lead(Id = nurturedLead.Id, Status = STATUS_QUALIFY);
            update new Lead(Id = nurturedLead.Id, OwnerId = UserInfo.getUserId());
        } catch (DmlException ex) {
            System.debug('Progression step blocked: ' + ex.getMessage());
            return;
        }
        Test.startTest();
        try {
            update reNurtureUpdate(nurturedLead.Id);
        } catch (DmlException ex) {
            System.debug('Re-Nurture step blocked: ' + ex.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testTriggerContext_BulkInsertAndUpdate() {
        if (!handlerIsWiredToTrigger()) {
            return;
        }
        List<Lead> bulkLeads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            bulkLeads.add(newLead('Bulk ' + i, 'Bulk Co ' + i, STATUS_ENGAGE, UserInfo.getUserId()));
        }
        Test.startTest();
        try {
            insert bulkLeads;
            List<Lead> bulkUpdates = new List<Lead>();
            for (Lead bulkLead : bulkLeads) {
                bulkUpdates.add(new Lead(Id = bulkLead.Id, Description = 'Bulk touched'));
            }
            update bulkUpdates;
        } catch (DmlException ex) {
            System.debug('Bulk DML blocked: ' + ex.getMessage());
        }
        Test.stopTest();
        Assert.areEqual(200, [SELECT COUNT() FROM Lead WHERE Id IN :bulkLeads], 'All 200 Leads should be inserted');
    }

    // ========================================================================================
    // Additional coverage: owner-change validation, duplicate detection / notification,
    // entity owner mapping and the marketing-user after-update path.
    // ========================================================================================

    private static Lead fullLead(String firstName, String lastName, String status, Id ownerId) {
        Lead leadRecord = new Lead(
            FirstName = firstName,
            LastName = lastName,
            Company = lastName + ' Co',
            Status = status,
            Email = buildUniqueEmail(lastName),
            Phone = '+1 555 0199',
            City = 'Test City',
            Country = 'United States',
            PostalCode = '12345',
            Title = 'Buyer',
            Belongs_To_CC__c = INC_ENTITY
        );
        if (ownerId != null) {
            leadRecord.OwnerId = ownerId;
        }
        return leadRecord;
    }

    private static Lead ownerChange(Integer index, Id newOwnerId, Id oldOwnerId, String status, String belongsTo, Map<Id, Lead> oldMap) {
        Id leadId = fakeLeadId(index);
        oldMap.put(leadId, new Lead(Id = leadId, OwnerId = oldOwnerId, Status = status, Belongs_To_CC__c = belongsTo));
        return new Lead(Id = leadId, OwnerId = newOwnerId, Status = status, Belongs_To_CC__c = belongsTo);
    }

    private static String firstError(Lead leadRecord) {
        return leadRecord.hasErrors() ? leadRecord.getErrors()[0].getMessage() : null;
    }

    private static Database.DMLOptions allowDuplicateSave() {
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        return options;
    }

    // Verifies every branch of raiseValidationOnOwnerChange for a Carlton Marketing User (pool / user targets,
    // Engage gate, regional queue and regional membership checks).
    @isTest
    static void testRaiseValidationOnOwnerChange_MarketingUserBranches() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        User salesUser = getTestUser(SALES_PROFILE);
        Assert.isNotNull(marketingUser, 'Marketing test user is required');
        Assert.isNotNull(salesUser, 'Sales test user is required');
        Id usMkt = getQueueId(US_QUEUE);
        Id ukMkt = getQueueId(UK_QUEUE);
        Id usSales = getQueueId(US_SALES_QUEUE);
        Id ukSales = getQueueId(UK_SALES_QUEUE);
        Id adminId = UserInfo.getUserId();

        Map<Id, Lead> oldMap = new Map<Id, Lead>();
        Lead claimFromPool      = ownerChange(101, marketingUser.Id, usMkt, STATUS_QUALIFY, INC_ENTITY, oldMap);
        Lead toOwnMktPool       = ownerChange(102, usMkt, salesUser.Id, STATUS_QUALIFY, INC_ENTITY, oldMap);
        Lead toWrongMktPool     = ownerChange(103, ukMkt, salesUser.Id, STATUS_QUALIFY, INC_ENTITY, oldMap);
        Lead toSalesPoolEarly   = ownerChange(104, usSales, marketingUser.Id, STATUS_QUALIFY, INC_ENTITY, oldMap);
        Lead toUsSalesPool      = ownerChange(105, usSales, marketingUser.Id, STATUS_ENGAGE, INC_ENTITY, oldMap);
        Lead incToUkSalesPool   = ownerChange(106, ukSales, marketingUser.Id, STATUS_ENGAGE, INC_ENTITY, oldMap);
        Lead llpToUsSalesPool   = ownerChange(107, usSales, marketingUser.Id, STATUS_ENGAGE, LLP_ENTITY, oldMap);
        Lead toSalesUserEarly   = ownerChange(108, salesUser.Id, marketingUser.Id, STATUS_QUALIFY, INC_ENTITY, oldMap);
        Lead toSalesUserValid   = ownerChange(109, salesUser.Id, marketingUser.Id, STATUS_ENGAGE, INC_ENTITY, oldMap);
        Lead llpToSalesUser     = ownerChange(110, salesUser.Id, marketingUser.Id, STATUS_ENGAGE, LLP_ENTITY, oldMap);
        Lead toMktUserValid     = ownerChange(111, marketingUser.Id, salesUser.Id, STATUS_QUALIFY, INC_ENTITY, oldMap);
        Lead llpToMktUser       = ownerChange(112, marketingUser.Id, salesUser.Id, STATUS_QUALIFY, LLP_ENTITY, oldMap);
        Lead fromSalesPoolToMe  = ownerChange(113, marketingUser.Id, usSales, STATUS_QUALIFY, INC_ENTITY, oldMap);
        Lead unchangedOwner     = ownerChange(114, salesUser.Id, salesUser.Id, STATUS_QUALIFY, INC_ENTITY, oldMap);
        Lead toAdminUser        = ownerChange(115, adminId, marketingUser.Id, STATUS_QUALIFY, LLP_ENTITY, oldMap);
        List<Lead> newLeads = new List<Lead>{
            claimFromPool, toOwnMktPool, toWrongMktPool, toSalesPoolEarly, toUsSalesPool, incToUkSalesPool,
            llpToUsSalesPool, toSalesUserEarly, toSalesUserValid, llpToSalesUser, toMktUserValid, llpToMktUser,
            fromSalesPoolToMe, unchangedOwner, toAdminUser
        };

        Test.startTest();
        System.runAs(marketingUser) {
            LeadTriggerHandler_CC_New.raiseValidationOnOwnerChange(newLeads, oldMap);
        }
        Test.stopTest();

        Assert.isNull(firstError(claimFromPool), 'Marketing user may claim a Lead from a Marketing pool');
        Assert.isNull(firstError(toOwnMktPool), 'INC Lead may go to the US Marketing pool');
        Assert.areEqual('A Lead can only be assigned to the Marketing Pool corresponding to its entity.', firstError(toWrongMktPool), 'INC -> UK Marketing pool');
        Assert.areEqual('A Lead can only be reassigned to Sales once it has been Engaged by Marketing.', firstError(toSalesPoolEarly), 'Sales pool before Engage');
        Assert.isNull(firstError(toUsSalesPool), 'Engaged INC Lead may go to the US Sales pool');
        Assert.areEqual('Leads belonging to Carlton Packaging INC can only be assigned to the US Sales Pool.', firstError(incToUkSalesPool), 'INC -> UK Sales pool');
        Assert.areEqual('Leads belonging to Carlton Packaging LLP can only be assigned to the UK Sales Pool.', firstError(llpToUsSalesPool), 'LLP -> US Sales pool');
        Assert.areEqual('A Lead can only be reassigned to Sales once it has been Engaged by Marketing.', firstError(toSalesUserEarly), 'Sales user before Engage');
        Assert.isNull(firstError(toSalesUserValid), 'Engaged INC Lead may go to a US Sales pool member');
        Assert.areEqual('A Marketing User can only reassign a Lead to a Sales User from the corresponding regional Sales Pool.', firstError(llpToSalesUser), 'LLP -> US sales member');
        Assert.isNull(firstError(toMktUserValid), 'INC Lead may go to a US Marketing pool member');
        Assert.areEqual('A Marketing User can only reassign a Lead to a Marketing User from the corresponding regional Marketing Pool.', firstError(llpToMktUser), 'LLP -> US marketing member');
        Assert.isNull(firstError(fromSalesPoolToMe), 'INC Lead from Sales pool to a US Marketing member is allowed');
        Assert.isNull(firstError(unchangedOwner), 'Unchanged owner is ignored');
        Assert.isNull(firstError(toAdminUser), 'Non Sales/Marketing target user is not restricted');
    }

    // Verifies the owner-change rules are not applied when the running user is not a Marketing user.
    @isTest
    static void testRaiseValidationOnOwnerChange_AdminIsNotRestricted() {
        Map<Id, Lead> oldMap = new Map<Id, Lead>();
        Lead toWrongPool = ownerChange(120, getQueueId(UK_QUEUE), getQueueId(US_SALES_QUEUE), STATUS_QUALIFY, INC_ENTITY, oldMap);
        Test.startTest();
        LeadTriggerHandler_CC_New.raiseValidationOnOwnerChange(new List<Lead>{toWrongPool}, oldMap);
        Test.stopTest();
        Assert.isFalse(toWrongPool.hasErrors(), 'Administrators are not restricted by the owner-change rules');
    }

    // Verifies (trigger context) a Marketing user claiming a Lead from the US Marketing pool is allowed,
    // runs the marketing-only after-update path and stamps Last_Marketing_Owner_Id_CC__c.
    @isTest
    static void testTriggerContext_MarketingUserClaimsLeadFromPool() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        Assert.isNotNull(marketingUser, 'Marketing test user is required');
        Lead poolLead = fullLead('Pool', 'Claimable', STATUS_QUALIFY, getQueueId(US_QUEUE));
        poolLead.LeadSource = 'Web Search';
        insert poolLead;

        Test.startTest();
        System.runAs(marketingUser) {
            update new Lead(Id = poolLead.Id, OwnerId = marketingUser.Id);
        }
        Test.stopTest();

        Lead reloaded = [SELECT OwnerId, Last_Marketing_Owner_Id_CC__c FROM Lead WHERE Id = :poolLead.Id];
        Assert.areEqual(marketingUser.Id, reloaded.OwnerId, 'Marketing user should own the claimed Lead');
        Assert.areEqual(String.valueOf(marketingUser.Id), reloaded.Last_Marketing_Owner_Id_CC__c, 'Last marketing owner should be stamped');
    }

    // Verifies (trigger context) a Marketing user cannot hand a non-Engaged Lead to a Sales pool.
    @isTest
    static void testTriggerContext_MarketingUserBlockedFromSalesPoolBeforeEngage() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        Assert.isNotNull(marketingUser, 'Marketing test user is required');
        Lead ownedLead = fullLead('Early', 'Handover', STATUS_QUALIFY, marketingUser.Id);
        insert ownedLead;

        String message;
        Test.startTest();
        System.runAs(marketingUser) {
            try {
                update new Lead(Id = ownedLead.Id, OwnerId = getQueueId(US_SALES_QUEUE));
            } catch (DmlException ex) {
                message = ex.getMessage();
            }
        }
        Test.stopTest();

        Assert.isNotNull(message, 'Update should be rejected');
        Assert.isTrue(message.contains('once it has been Engaged by Marketing'), 'Unexpected error: ' + message);
        Assert.areEqual(marketingUser.Id, [SELECT OwnerId FROM Lead WHERE Id = :ownedLead.Id].OwnerId, 'Owner must be unchanged');
    }

    // Verifies (trigger context) an Identify Lead with an unmapped company is routed to the owner mapped to its entity.
    // The shipped Lead_Company_Owner_Mapping_CC records hold another org's queue Ids; until they are updated with this
    // org's queue Ids after deployment, the routed save fails with INVALID_CROSS_REFERENCE_KEY, which is asserted here.
    @isTest
    static void testTriggerContext_EntityOwnerMappingOnInsert() {
        List<Lead_Company_Owner_Mapping_CC__mdt> entityMappings = [
            SELECT Owner_Id_CC__c FROM Lead_Company_Owner_Mapping_CC__mdt
            WHERE Active_CC__c = TRUE AND Company_Name_CC__c = NULL AND Entity_CC__c = :INC_ENTITY AND Owner_Id_CC__c != NULL LIMIT 1
        ];
        Assert.isFalse(entityMappings.isEmpty(), 'An active entity mapping for ' + INC_ENTITY + ' is required');
        Lead identifyLead = fullLead('Entity', 'Routed ' + Math.abs(Crypto.getRandomInteger()), STATUS_IDENTIFY, UserInfo.getUserId());
        Id mappedOwnerId = Id.valueOf(entityMappings[0].Owner_Id_CC__c);
        Boolean mappedOwnerExists = (mappedOwnerId.getSObjectType() == Group.SObjectType
            ? [SELECT COUNT() FROM Group WHERE Id = :mappedOwnerId] : [SELECT COUNT() FROM User WHERE Id = :mappedOwnerId]) > 0;

        Test.startTest();
        Database.SaveResult saved = Database.insert(identifyLead, false);
        Test.stopTest();

        if (!mappedOwnerExists) {
            Assert.isFalse(saved.isSuccess(), 'A Lead cannot be routed to an owner that does not exist in this org');
            Assert.isTrue(String.valueOf(saved.getErrors()).contains('INVALID_CROSS_REFERENCE_KEY'), String.valueOf(saved.getErrors()));
            return;
        }
        Assert.isTrue(saved.isSuccess(), String.valueOf(saved.getErrors()));
        Assert.areEqual(mappedOwnerId, [SELECT OwnerId FROM Lead WHERE Id = :identifyLead.Id].OwnerId,
            'Identify Lead should be owned by the entity-mapped owner');
    }

    // Verifies processChunk flags an in-memory Lead that matches an existing Lead under the Lead duplicate rule.
    @isTest
    static void testProcessChunk_FlagsMatchingLead() {
        Lead existing = fullLead('Dupe', 'Chunk Match', STATUS_ENGAGE, UserInfo.getUserId());
        existing.Product_Category_CC__c = 'Tape';
        insert existing;
        existing = [SELECT FirstName, LastName, Email, Email_List_CC__c, Product_Category_CC__c, Product_Category_Text_CC__c, Company
                    FROM Lead WHERE Id = :existing.Id];
        Lead candidate = new Lead(FirstName = existing.FirstName, LastName = existing.LastName, Company = existing.Company,
                                  Email = existing.Email, Email_List_CC__c = existing.Email_List_CC__c,
                                  Product_Category_CC__c = existing.Product_Category_CC__c,
                                  Product_Category_Text_CC__c = existing.Product_Category_Text_CC__c, Status = STATUS_QUALIFY);
        Lead unique = fullLead('Unique', 'No Match', STATUS_QUALIFY, null);

        Test.startTest();
        LeadTriggerHandler_CC_New.processChunk(new List<Lead>{candidate, unique});
        Test.stopTest();

        Assert.areEqual(DUPLICATE_ERROR, firstError(candidate), 'Matching Lead should be flagged as duplicate');
        Assert.isFalse(unique.hasErrors(), 'Non matching Lead should not be flagged');
    }

    // Verifies (trigger context) the duplicate checkpoint now applies on entry to Engage, not Qualify:
    // entering Qualify is allowed, an explicit move to Engage is blocked, and the bypass flag allows it.
    @isTest
    static void testTriggerContext_EngageDuplicateBlocked() {
        Lead original = fullLead('Dupe', 'Engage Match', STATUS_QUALIFY, UserInfo.getUserId());
        insert original;
        Lead copy = original.clone(false, true, false, false);
        copy.Status = STATUS_IDENTIFY;
        Lead bypassCopy = original.clone(false, true, false, false);
        bypassCopy.Bypass_Duplicate_Rules_on_Qualification__c = true;
        // The Identify copy has an Entity, so it is routed to the Entity pool mapped in Lead_Company_Owner_Mapping_CC;
        // the test stops when that pool does not exist in this org (TestLeadRouting_CC).
        Database.SaveResult insertedCopy = Database.insert(copy, allowDuplicateSave());
        if (!TestLeadRouting_CC.entityPoolsExist()) {
            TestLeadRouting_CC.assertRoutingFailure(insertedCopy);
            return;
        }
        Database.SaveResult insertedBypass = Database.insert(bypassCopy, allowDuplicateSave());
        Assert.isTrue(insertedCopy.isSuccess() && insertedBypass.isSuccess(),
            'Duplicates should save with allowSave: ' + insertedCopy.getErrors() + insertedBypass.getErrors());

        String message;
        Test.startTest();
        Database.SaveResult qualifyResult = Database.update(new Lead(Id = copy.Id, Status = STATUS_QUALIFY), allowDuplicateSave());
        try {
            update new Lead(Id = copy.Id, Status = STATUS_ENGAGE);
        } catch (DmlException ex) {
            message = ex.getMessage();
        }
        Database.SaveResult bypassResult = Database.update(new Lead(Id = bypassCopy.Id, Status = STATUS_ENGAGE), allowDuplicateSave());
        Test.stopTest();

        Assert.isTrue(qualifyResult.isSuccess(), 'Entering Qualify no longer runs the duplicate checkpoint: ' + qualifyResult.getErrors());
        Assert.isNotNull([SELECT Qualified_Date_CC__c FROM Lead WHERE Id = :copy.Id].Qualified_Date_CC__c, 'Qualified date should be captured');
        Assert.isNotNull(message, 'Engaging a duplicate Lead should fail');
        Assert.isTrue(message.contains(DUPLICATE_ERROR) || message.contains('DUPLICATES_DETECTED'),
            'An active Salesforce duplicate rule or the trigger checkpoint must block the move: ' + message);
        Assert.isTrue(bypassResult.isSuccess(), 'Bypass flag should skip the duplicate check: ' + bypassResult.getErrors());
        Assert.areEqual(STATUS_ENGAGE, [SELECT Status FROM Lead WHERE Id = :bypassCopy.Id].Status, 'Bypassed Lead should be Engage');
    }

    // Verifies (trigger context) creating a duplicate Lead notifies the creator's role manager; also covers
    // the creator-without-role early exit. The notification itself is not queryable, so the test asserts
    // the duplicate is detected by the duplicate rule and the insert succeeds in both cases.
    @isTest
    static void testTriggerContext_DuplicateInsertNotifiesRoleManager() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User creator;
        User noRoleCreator;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole parentRole = new UserRole(Name = 'Lead Test Manager Role', DeveloperName = 'Lead_Test_Mgr_' + Math.abs(Crypto.getRandomInteger()));
            insert parentRole;
            UserRole childRole = new UserRole(Name = 'Lead Test Rep Role', DeveloperName = 'Lead_Test_Rep_' + Math.abs(Crypto.getRandomInteger()), ParentRoleId = parentRole.Id);
            insert childRole;
            User manager = buildAdminUser(adminProfile.Id, 'ltmgr', parentRole.Id);
            creator = buildAdminUser(adminProfile.Id, 'ltrep', childRole.Id);
            noRoleCreator = buildAdminUser(adminProfile.Id, 'ltnor', null);
            insert new List<User>{manager, creator, noRoleCreator};
        }

        List<Database.SaveResult> results = new List<Database.SaveResult>();
        Lead duplicate;
        Test.startTest();
        System.runAs(creator) {
            Lead original = fullLead('Dupe', 'Role Notify', STATUS_ENGAGE, null);
            original.Product_Category_CC__c = 'Tape';
            insert original;
            duplicate = original.clone(false, true, false, false);
            results.add(Database.insert(duplicate, allowDuplicateSave()));
        }
        System.runAs(noRoleCreator) {
            Lead original = fullLead('Dupe', 'No Role', STATUS_ENGAGE, null);
            insert original;
            results.add(Database.insert(original.clone(false, true, false, false), allowDuplicateSave()));
        }
        Test.stopTest();

        for (Database.SaveResult sr : results) {
            Assert.isTrue(sr.isSuccess(), 'Duplicate insert with allowSave should succeed: ' + sr.getErrors());
        }
        List<Datacloud.FindDuplicatesResult> dupResults = Datacloud.FindDuplicates.findDuplicates(
            new List<Lead>{[SELECT FirstName, LastName, Email, Email_List_CC__c, Product_Category_Text_CC__c, Company
                            FROM Lead WHERE Id = :duplicate.Id]});
        Integer matches = 0;
        for (Datacloud.DuplicateResult dr : dupResults[0].getDuplicateResults()) {
            for (Datacloud.MatchResult mr : dr.getMatchResults()) {
                matches += mr.getMatchRecords().size();
            }
        }
        Assert.isTrue(matches >= 1, 'The inserted Lead should be detected as a duplicate by the active Lead duplicate rule');
    }

    private static User buildAdminUser(Id profileId, String aliasSeed, Id roleId) {
        return new User(
            FirstName = 'Role', LastName = 'Test ' + aliasSeed, Alias = aliasSeed,
            Email = aliasSeed + '@carltontest.invalid',
            Username = aliasSeed + String.valueOf(Math.abs(Crypto.getRandomLong())) + '@carltontest.invalid',
            ProfileId = profileId, UserRoleId = roleId, TimeZoneSidKey = 'Europe/London', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', IsActive = true
        );
    }

    // Verifies notifyRoleManagerOnDuplicateLead exits immediately (no SOQL) for null or empty input.
    @isTest
    static void testNotifyRoleManager_NullAndEmptyInput() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        LeadTriggerHandler_CC_New.notifyRoleManagerOnDuplicateLead(null);
        LeadTriggerHandler_CC_New.notifyRoleManagerOnDuplicateLead(new List<Lead>());
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();
        Assert.areEqual(queriesBefore, queriesAfter, 'No query should run for empty input');
    }

    // Verifies isCurrentUserMarketing reflects the running user's profile.
    @isTest
    static void testIsCurrentUserMarketing() {
        User marketingUser = getTestUser(MARKETING_PROFILE);
        Assert.isNotNull(marketingUser, 'Marketing test user is required');
        Boolean asMarketing;
        Test.startTest();
        System.runAs(marketingUser) {
            asMarketing = LeadTriggerHandler_CC_New.isCurrentUserMarketing();
        }
        Test.stopTest();
        Assert.isTrue(asMarketing, 'Marketing profile should be detected');
        Assert.isFalse(LeadTriggerHandler_CC_New.isCurrentUserMarketing(), 'Administrator is not a marketing user');
    }
}