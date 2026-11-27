/**
 * Tests for LeadTriggerHandler_CC (legacy Lead handler).
 *
 * LeadTrigger_CC now runs LeadTriggerHandler_CC_New, so this handler is never invoked by DML.
 * Its public static helpers are called directly, and the trigger-context overrides are called
 * outside a trigger (Trigger.new / Trigger.oldMap are null there, so they stop at the first loop).
 */
@IsTest
private class LeadTriggerHandler_CC_Test {

    private static final String DUPLICATE_ERROR_PREFIX = 'This Lead matches an existing record.';
    private static final String STATUS_ENGAGE = 'Engage';
    private static final String STATUS_QUALIFY = 'Qualify';
    private static final String INC_ENTITY = 'Carlton Packaging INC';

    private static Integer sequence = 0;

    // ------------------------------------------------------------------------------------ helpers

    private static String uniqueToken() {
        sequence++;
        return String.valueOf(sequence) + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(6);
    }

    private static Lead buildLead(String firstName, String lastName, String status) {
        String token = uniqueToken();
        return new Lead(
            FirstName = firstName,
            LastName = lastName,
            Company = lastName + ' Co ' + token,
            Status = status,
            Email = lastName.replaceAll('[^a-zA-Z0-9]', '').toLowerCase() + token + '@carltontest.invalid',
            Phone = '+1 555 0199',
            City = 'Test City',
            Country = 'United States',
            PostalCode = '12345',
            Title = 'Buyer',
            Belongs_To_CC__c = INC_ENTITY,
            Bypass_Duplicate_Rules_on_Import_CC__c = false
        );
    }

    private static Database.DMLOptions allowDuplicateSave() {
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        return options;
    }

    private static void insertAllowingDuplicates(List<Lead> leads) {
        List<Database.SaveResult> results = Database.insert(leads, allowDuplicateSave());
        for (Database.SaveResult result : results) {
            Assert.isTrue(result.isSuccess(), 'Lead insert should succeed: ' + result.getErrors());
        }
    }

    private static List<Lead> reload(Set<Id> leadIds) {
        return [
            SELECT Id, FirstName, LastName, Company, CreatedById, Email, Email_List_CC__c,
                   Product_Category_Text_CC__c, LinkedIn_Profile_URL_CC__c,
                   Bypass_Duplicate_Rules_on_Import_CC__c
            FROM Lead
            WHERE Id IN :leadIds
        ];
    }

    private static User buildAdminUser(Id profileId, String aliasSeed, Id roleId) {
        String token = uniqueToken();
        return new User(
            FirstName = 'Legacy',
            LastName = 'Handler ' + aliasSeed,
            Alias = aliasSeed.left(8),
            Email = aliasSeed + token + '@carltontest.invalid',
            Username = aliasSeed + token + String.valueOf(Math.abs(Crypto.getRandomLong())) + '@carltontest.invalid',
            ProfileId = profileId,
            UserRoleId = roleId,
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            IsActive = true
        );
    }

    private static Id fakeLeadId(Integer index) {
        return Id.valueOf('00Q' + String.valueOf(index).leftPad(12, '0'));
    }

    // ------------------------------------------------------------------------------------ tests

    @IsTest
    static void runOutsideTriggerContextDoesNothing() {
        LeadTriggerHandler_CC handler = new LeadTriggerHandler_CC();
        Test.startTest();
        handler.run();
        Test.stopTest();
        Assert.isFalse(Trigger.isExecuting, 'The test itself is not running in a trigger');
    }

    @IsTest
    static void contextOverridesFailSafelyOutsideTrigger() {
        LeadTriggerHandler_CC handler = new LeadTriggerHandler_CC();
        Integer failures = 0;
        Test.startTest();
        try {
            handler.beforeInsert();
        } catch (Exception ex) {
            failures++;
        }
        try {
            handler.beforeUpdate();
        } catch (Exception ex) {
            failures++;
        }
        try {
            handler.afterInsert();
        } catch (Exception ex) {
            failures++;
        }
        try {
            handler.afterUpdate();
        } catch (Exception ex) {
            failures++;
        }
        Test.stopTest();
        // Trigger.new is null outside a trigger, so every override stops at its first loop.
        Assert.areEqual(4, failures, 'Each override needs Trigger.new and should fail outside a trigger');
    }

    @IsTest
    static void sortProductCategoriesHandlesInsertAndUpdate() {
        Id changedId = fakeLeadId(1);
        Id unchangedId = fakeLeadId(2);
        Id clearedId = fakeLeadId(3);
        Id noOldId = fakeLeadId(4);

        Lead insertWithValue = new Lead(LastName = 'Insert', Product_Category_CC__c = 'Tape;Cardboard;Strapping');
        Lead insertBlank = new Lead(LastName = 'Insert Blank', Product_Category_Text_CC__c = 'stale');
        Lead changedLead = new Lead(Id = changedId, Product_Category_CC__c = 'Voidfill;Facilities');
        Lead unchangedLead = new Lead(Id = unchangedId, Product_Category_CC__c = 'Tape', Product_Category_Text_CC__c = 'keep');
        Lead clearedLead = new Lead(Id = clearedId, Product_Category_CC__c = null, Product_Category_Text_CC__c = 'Tape');
        Lead noOldLead = new Lead(Id = noOldId, Product_Category_CC__c = 'Tape;Cardboard');

        Map<Id, Lead> oldMap = new Map<Id, Lead>{
            changedId => new Lead(Id = changedId, Product_Category_CC__c = 'Tape'),
            unchangedId => new Lead(Id = unchangedId, Product_Category_CC__c = 'Tape'),
            clearedId => new Lead(Id = clearedId, Product_Category_CC__c = 'Tape')
        };

        Test.startTest();
        LeadTriggerHandler_CC.sortProductCategories(new List<Lead>{ insertWithValue, insertBlank }, null);
        LeadTriggerHandler_CC.sortProductCategories(new List<Lead>{ changedLead, unchangedLead, clearedLead, noOldLead }, oldMap);
        Test.stopTest();

        Assert.areEqual('Cardboard;Strapping;Tape', insertWithValue.Product_Category_Text_CC__c, 'Insert: categories sorted');
        Assert.isNull(insertBlank.Product_Category_Text_CC__c, 'Insert: blank categories clear the text field');
        Assert.areEqual('Facilities;Voidfill', changedLead.Product_Category_Text_CC__c, 'Update: changed categories sorted');
        Assert.areEqual('keep', unchangedLead.Product_Category_Text_CC__c, 'Update: unchanged categories are skipped');
        Assert.isNull(clearedLead.Product_Category_Text_CC__c, 'Update: cleared categories clear the text field');
        Assert.areEqual('Cardboard;Tape', noOldLead.Product_Category_Text_CC__c, 'Update without an old record is processed');
    }

    @IsTest
    static void checkDuplicatesProcessesFullAndPartialChunks() {
        List<Lead> candidates = new List<Lead>();
        for (Integer i = 0; i < 51; i++) {
            candidates.add(buildLead('Chunk', 'Unique Chunk ' + i, STATUS_QUALIFY));
        }
        Test.startTest();
        LeadTriggerHandler_CC.checkDuplicates(candidates);
        Test.stopTest();
        for (Lead candidate : candidates) {
            Assert.isFalse(candidate.hasErrors(), 'Unique Leads must not be flagged: ' + candidate.getErrors());
        }
    }

    @IsTest
    static void processChunkFlagsMatchingLead() {
        Lead existing = buildLead('Legacy', 'Chunk Match', STATUS_ENGAGE);
        existing.Product_Category_CC__c = 'Tape';
        insertAllowingDuplicates(new List<Lead>{ existing });
        existing = reload(new Set<Id>{ existing.Id })[0];

        Lead candidate = new Lead(
            FirstName = existing.FirstName,
            LastName = existing.LastName,
            Company = existing.Company,
            Email = existing.Email,
            Email_List_CC__c = existing.Email_List_CC__c,
            Product_Category_Text_CC__c = existing.Product_Category_Text_CC__c,
            LinkedIn_Profile_URL_CC__c = existing.LinkedIn_Profile_URL_CC__c,
            Bypass_Duplicate_Rules_on_Import_CC__c = false,
            Status = STATUS_QUALIFY
        );
        Lead unique = buildLead('Legacy', 'No Match', STATUS_QUALIFY);

        Test.startTest();
        LeadTriggerHandler_CC.processChunk(new List<Lead>{ candidate, unique });
        Test.stopTest();

        Assert.isTrue(candidate.hasErrors(), 'Matching Lead should be flagged as a duplicate');
        Assert.isTrue(candidate.getErrors()[0].getMessage().startsWith(DUPLICATE_ERROR_PREFIX),
            'Unexpected error: ' + candidate.getErrors()[0].getMessage());
        Assert.isFalse(unique.hasErrors(), 'Non matching Lead should not be flagged');
    }

    @IsTest
    static void notifyRoleManagerHandlesEmptyInput() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        LeadTriggerHandler_CC.notifyRoleManagerOnDuplicateLead(null);
        LeadTriggerHandler_CC.notifyRoleManagerOnDuplicateLead(new List<Lead>());
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();
        Assert.areEqual(queriesBefore, queriesAfter, 'Empty input must exit before any query');
    }

    @IsTest
    static void notifyRoleManagerOnDuplicateLeadCoversAllRecipientPaths() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User creator;
        User orphanCreator;
        User noRoleCreator;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole managerRole = new UserRole(Name = 'Legacy Mgr Role', DeveloperName = 'Legacy_Mgr_' + uniqueToken());
            UserRole emptyParentRole = new UserRole(Name = 'Legacy Empty Role', DeveloperName = 'Legacy_Empty_' + uniqueToken());
            insert new List<UserRole>{ managerRole, emptyParentRole };
            UserRole repRole = new UserRole(Name = 'Legacy Rep Role', DeveloperName = 'Legacy_Rep_' + uniqueToken(), ParentRoleId = managerRole.Id);
            UserRole orphanRole = new UserRole(Name = 'Legacy Orphan Role', DeveloperName = 'Legacy_Orph_' + uniqueToken(), ParentRoleId = emptyParentRole.Id);
            insert new List<UserRole>{ repRole, orphanRole };

            User manager = buildAdminUser(adminProfile.Id, 'lgmgr', managerRole.Id);
            creator = buildAdminUser(adminProfile.Id, 'lgrep', repRole.Id);
            orphanCreator = buildAdminUser(adminProfile.Id, 'lgorp', orphanRole.Id);
            noRoleCreator = buildAdminUser(adminProfile.Id, 'lgnor', null);
            insert new List<User>{ manager, creator, orphanCreator, noRoleCreator };
        }

        Set<Id> duplicateIds = new Set<Id>();
        Id uniqueLeadId;
        System.runAs(creator) {
            Lead original = buildLead('Legacy', 'Role Notify', STATUS_ENGAGE);
            original.Product_Category_CC__c = 'Tape';
            insertAllowingDuplicates(new List<Lead>{ original });
            Lead duplicate = original.clone(false, true, false, false);
            Lead unique = buildLead('Legacy', 'Role Unique', STATUS_ENGAGE);
            insertAllowingDuplicates(new List<Lead>{ duplicate, unique });
            duplicateIds.add(duplicate.Id);
            uniqueLeadId = unique.Id;
        }

        // Every Lead insert runs the full Lead trigger; start the test here so the remaining inserts and the
        // calls under test get their own SOQL limit.
        Test.startTest();
        Id orphanDuplicateId;
        System.runAs(orphanCreator) {
            Lead original = buildLead('Legacy', 'Orphan Notify', STATUS_ENGAGE);
            insertAllowingDuplicates(new List<Lead>{ original });
            Lead duplicate = original.clone(false, true, false, false);
            insertAllowingDuplicates(new List<Lead>{ duplicate });
            orphanDuplicateId = duplicate.Id;
        }
        Id noRoleDuplicateId;
        System.runAs(noRoleCreator) {
            Lead original = buildLead('Legacy', 'No Role Notify', STATUS_ENGAGE);
            insertAllowingDuplicates(new List<Lead>{ original });
            Lead duplicate = original.clone(false, true, false, false);
            insertAllowingDuplicates(new List<Lead>{ duplicate });
            noRoleDuplicateId = duplicate.Id;
        }

        Set<Id> allIds = new Set<Id>(duplicateIds);
        allIds.add(uniqueLeadId);
        allIds.add(orphanDuplicateId);
        allIds.add(noRoleDuplicateId);

        // Mixed batch: duplicate with a notified manager, unique Lead, duplicate whose parent role is empty,
        // duplicate whose creator has no role.
        LeadTriggerHandler_CC.notifyRoleManagerOnDuplicateLead(reload(allIds));
        // Only a unique Lead: no duplicate found, exits early.
        LeadTriggerHandler_CC.notifyRoleManagerOnDuplicateLead(reload(new Set<Id>{ uniqueLeadId }));
        // Only a duplicate created by a user without a role: no parent role, exits early.
        LeadTriggerHandler_CC.notifyRoleManagerOnDuplicateLead(reload(new Set<Id>{ noRoleDuplicateId }));
        Test.stopTest();

        Lead duplicateLead = reload(duplicateIds)[0];
        Assert.areEqual(creator.Id, duplicateLead.CreatedById, 'Duplicate should be created by the role user');
        List<Datacloud.FindDuplicatesResult> dupResults =
            Datacloud.FindDuplicates.findDuplicates(new List<Lead>{ duplicateLead });
        Integer matches = 0;
        for (Datacloud.DuplicateResult dr : dupResults[0].getDuplicateResults()) {
            for (Datacloud.MatchResult mr : dr.getMatchResults()) {
                matches += mr.getMatchRecords().size();
            }
        }
        Assert.isTrue(matches >= 1, 'The cloned Lead should be detected by the active Lead duplicate rule');
    }
}