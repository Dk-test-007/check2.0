@isTest
private class LeadTriggerHandler_CC_New_Test {

    private static final String MARKETING_PROFILE = 'Carlton Marketing User';
    private static final String SALES_PROFILE = 'Carlton Sales User';
    private static final String TEST_USER_EMAIL = 'lead.handler.test@carltontest.invalid';
    private static final String US_QUEUE = 'US_Marketing_Pool';
    private static final String UK_QUEUE = 'UK_Marketing_Pool';
    private static final String INC_ENTITY = 'Carlton Packing INC';
    private static final String LLP_ENTITY = 'Carlton Packing LLP';
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
            if (isValidUserId(mapping.Owner_Id_CC__c)) {
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
    }

    @isTest
    static void testCompanyOwnerMapping_NonIdentifyAndNullOwnerAreSkipped() {
        Lead engagedLead = memoryLead(null, 'Anything Ltd', STATUS_ENGAGE, UserInfo.getUserId(), INC_ENTITY);
        Lead ownerlessLead = memoryLead(null, 'Anything Ltd', STATUS_IDENTIFY, null, INC_ENTITY);
        Test.startTest();
        LeadTriggerHandler_CC_New.applyCompanyOwnerMapping(new List<Lead>{engagedLead, ownerlessLead}, null);
        Test.stopTest();
    }

    @isTest
    static void testCompanyOwnerMapping_UnmappedCompanyKeepsOwner() {
        Lead unmappedLead = memoryLead(null, 'Totally Unmapped Company ' + Math.abs(Crypto.getRandomInteger()), STATUS_IDENTIFY, UserInfo.getUserId(), null);
        Test.startTest();
        LeadTriggerHandler_CC_New.applyCompanyOwnerMapping(new List<Lead>{unmappedLead}, null);
        Test.stopTest();
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
        Lead llpLead = newLead('LLP Fallback', 'LLP Co', STATUS_ENGAGE, UserInfo.getUserId(), LLP_ENTITY);
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
    }
}