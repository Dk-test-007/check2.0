/**
 * Tests for LeadNextStepBackfill_CC: only Next Step is written, only on approved open Leads whose Status and Owner
 * still match the approval, and nothing advances, changes owner or fails loudly. Leads are created with a blank
 * Next Step (LeadStageTransitionService_CC.suppressInitialMessages), as Leads created before the insert fix are.
 */
@isTest
private class LeadNextStepBackfill_CC_Test {

    private static final String MARKETING_PROFILE = 'Carlton Marketing User';
    private static final String SALES_PROFILE = 'Carlton Sales User';
    private static final String USER_EMAIL = 'lead.backfill.test@carltontest.invalid';
    private static Integer sequence = 0;

    @TestSetup
    static void setupUsers() {
        insert new List<User>{ buildUser(MARKETING_PROFILE, 'lbfmkt'), buildUser(SALES_PROFILE, 'lbfsls') };
    }

    @isTest
    static void backfill_WritesOnlyNextStep_AndKeepsStatusOwnerAndBusinessFields() {
        User marketingUser = testUser(MARKETING_PROFILE);
        User salesUser = testUser(SALES_PROFILE);
        Lead identify = openLead('Identify', marketingUser.Id);
        identify.LeadSource = null;
        Lead marketingEngage = openLead('Engage', marketingUser.Id);
        Lead salesEngage = openLead('Engage', salesUser.Id);
        Lead reNurture = openLead('Re-Nurture', salesUser.Id);
        reNurture.Re_Nurture_Reason_CC__c = firstValue(Lead.Re_Nurture_Reason_CC__c);
        reNurture.Re_Nurture_Comments_CC__c = 'Backfill test';
        reNurture.Reengagement_Date_CC__c = Date.today().addDays(10);
        List<Lead> leads = insertBlank(new List<Lead>{ identify, marketingEngage, salesEngage, reNurture });
        Map<Id, Lead> before = new Map<Id, Lead>(reload(leads));

        Test.startTest();
        Database.executeBatch(new LeadNextStepBackfill_CC(approve(before.values())), 200);
        Test.stopTest();

        for (Lead result : reload(leads)) {
            Lead original = before.get(result.Id);
            Assert.isNotNull(result.Stage_Progress_Message_CC__c, 'Next Step should be backfilled for ' + result.Status);
            Assert.areEqual(original.Status, result.Status, 'Status must not change');
            Assert.areEqual(original.OwnerId, result.OwnerId, 'Owner must not change');
            Assert.areEqual(original.Last_Marketing_Owner_Id_CC__c, result.Last_Marketing_Owner_Id_CC__c, 'Last Marketing Owner must not change');
            Assert.areEqual(original.Lifecycle_Cycle_CC__c, result.Lifecycle_Cycle_CC__c, 'Cycle must not change');
            Assert.areEqual(original.Lifecycle_History_CC__c, result.Lifecycle_History_CC__c, 'History must not change');
            Assert.areEqual(original.Reengagement_Date_CC__c, result.Reengagement_Date_CC__c, 'Re-Nurture fields must not change');
        }
        Map<Id, Lead> results = new Map<Id, Lead>(reload(leads));
        Assert.isTrue(results.get(identify.Id).Stage_Progress_Message_CC__c.startsWith('To move to Qualify'), 'Identify gaps');
        Assert.isTrue(results.get(marketingEngage.Id).Stage_Progress_Message_CC__c.contains('Marketing:'), 'Marketing-owned handoff');
        Assert.isFalse(results.get(salesEngage.Id).Stage_Progress_Message_CC__c.contains('Marketing:'), 'Sales-owned: no handoff');
        Assert.isTrue(results.get(reNurture.Id).Stage_Progress_Message_CC__c.startsWith('Follow up from the Re-engagement Date'), 'Re-Nurture');
    }

    @isTest
    static void backfill_DoesNotChangeTheStageAdvancedOnInsert() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead complete = openLead('Identify', marketingUser.Id);
        complete.Belongs_To_CC__c = 'Carlton Packaging INC'; // every Identify gate met
        // An Identify Lead with an Entity is routed to the Entity pool mapped in Lead_Company_Owner_Mapping_CC; the test
        // stops when that pool does not exist in this org (TestLeadRouting_CC).
        List<Lead> leads = new List<Lead>{ complete };
        LeadStageTransitionService_CC.suppressInitialMessages = true;
        Boolean saved = TestLeadRouting_CC.insertIdentifyLeads(leads);
        LeadStageTransitionService_CC.suppressInitialMessages = false;
        if (!saved) {
            return;
        }
        Lead before = reload(leads)[0];
        Assert.areEqual('Qualify', before.Status, 'Insert advances a complete Identify Lead once.');

        Test.startTest();
        Database.executeBatch(new LeadNextStepBackfill_CC(approve(reload(leads))), 200);
        Test.stopTest();

        Lead result = reload(leads)[0];
        Assert.areEqual(before.Status, result.Status, 'The backfill must not change the Lead stage.');
        Assert.isNotNull(result.Stage_Progress_Message_CC__c, 'The backfill supplies the next step for Qualify.');
    }

    @isTest
    static void backfill_SkipsUnapprovedChangedClosedAndAlreadyFilledLeads() {
        User salesUser = testUser(SALES_PROFILE);
        Lead notApproved = openLead('Engage', salesUser.Id);
        Lead statusChanged = openLead('Engage', salesUser.Id);
        Lead disqualified = openLead('Disqualified', salesUser.Id);
        disqualified.Disqualified_Reason_CC__c = 'Other';
        disqualified.Disqualification_Comments_CC__c = 'Backfill test';
        List<Lead> blanks = insertBlank(new List<Lead>{ notApproved, statusChanged, disqualified });
        Lead filled = openLead('Engage', salesUser.Id);
        insert filled;
        String filledMessage = reload(new List<Lead>{ filled })[0].Stage_Progress_Message_CC__c;

        Map<Id, String> approved = new Map<Id, String>{
            statusChanged.Id => LeadNextStepBackfill_CC.approvalKey('Qualify', salesUser.Id),
            disqualified.Id => LeadNextStepBackfill_CC.approvalKey('Disqualified', salesUser.Id),
            filled.Id => LeadNextStepBackfill_CC.approvalKey('Engage', salesUser.Id)
        };

        Test.startTest();
        Database.executeBatch(new LeadNextStepBackfill_CC(approved), 200);
        Test.stopTest();

        Map<Id, Lead> results = new Map<Id, Lead>(reload(new List<Lead>{ notApproved, statusChanged, disqualified, filled }));
        Assert.isNull(results.get(notApproved.Id).Stage_Progress_Message_CC__c, 'Not approved: untouched');
        Assert.isNull(results.get(statusChanged.Id).Stage_Progress_Message_CC__c, 'Status differs from approval: skipped');
        Assert.isNull(results.get(disqualified.Id).Stage_Progress_Message_CC__c, 'Closed stage: not selected');
        Assert.areEqual(filledMessage, results.get(filled.Id).Stage_Progress_Message_CC__c, 'Existing Next Step: not selected');
    }

    @isTest
    static void backfill_200Leads_AllFilledWithoutStatusOrOwnerChanges() {
        User salesUser = testUser(SALES_PROFILE);
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            Lead leadRecord = openLead(Math.mod(i, 2) == 0 ? 'Engage' : 'Qualify', salesUser.Id);
            if (leadRecord.Status == 'Qualify') {
                leadRecord.Estimated_Annual_Spend_CC__c = null; // an open Engage gap, so Qualify has a Next Step
            }
            leads.add(leadRecord);
        }
        insertBlank(leads);

        Test.startTest();
        Database.executeBatch(new LeadNextStepBackfill_CC(approve(reload(leads))), 200);
        Test.stopTest();

        Integer blank = [SELECT COUNT() FROM Lead WHERE Id IN :leads AND Stage_Progress_Message_CC__c = null WITH SYSTEM_MODE];
        Integer moved = [SELECT COUNT() FROM Lead WHERE Id IN :leads AND (OwnerId != :salesUser.Id OR Status NOT IN ('Engage', 'Qualify')) WITH SYSTEM_MODE];
        Assert.areEqual(0, blank, 'Every approved Lead should get a Next Step');
        Assert.areEqual(0, moved, 'No Lead may change Status or Owner');
    }

    // ------------------------------------------------------------------ helpers

    private static List<Lead> insertBlank(List<Lead> leads) {
        LeadStageTransitionService_CC.suppressInitialMessages = true;
        insert leads;
        LeadStageTransitionService_CC.suppressInitialMessages = false;
        return leads;
    }

    private static Map<Id, String> approve(List<Lead> leads) {
        Map<Id, String> approved = new Map<Id, String>();
        for (Lead leadRecord : leads) {
            approved.put(leadRecord.Id, LeadNextStepBackfill_CC.approvalKey(leadRecord.Status, leadRecord.OwnerId));
        }
        return approved;
    }

    /** No Entity, so insert routing keeps the given owner; Site with spend, so Engage rules are met. */
    private static Lead openLead(String status, Id ownerId) {
        sequence++;
        String suffix = String.valueOf(sequence) + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new Lead(
            FirstName = 'Backfill', LastName = 'Tester ' + suffix, Company = 'Backfill Co ' + suffix, Status = status,
            Title = 'Buyer', Email = 'backfill' + suffix + '@carltontest.invalid', Phone = '+1 555 0100',
            City = 'Chicago', PostalCode = '60601', CountryCode = 'US', LeadSource = 'Web Search',
            Lead_Type_CC__c = 'Site', Estimated_Annual_Spend_CC__c = 150000, OwnerId = ownerId
        );
    }

    private static List<Lead> reload(List<Lead> leads) {
        return [SELECT Id, Status, OwnerId, Stage_Progress_Message_CC__c, Last_Marketing_Owner_Id_CC__c,
                       Lifecycle_Cycle_CC__c, Lifecycle_History_CC__c, Reengagement_Date_CC__c
                FROM Lead WHERE Id IN :leads WITH SYSTEM_MODE];
    }

    private static String firstValue(Schema.SObjectField field) {
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static User testUser(String profileName) {
        return [SELECT Id FROM User WHERE Email = :USER_EMAIL AND Profile.Name = :profileName AND IsActive = true LIMIT 1];
    }

    private static User buildUser(String profileName, String alias) {
        return new User(
            FirstName = 'Backfill', LastName = 'Test ' + alias, Alias = alias, Email = USER_EMAIL,
            Username = alias + Math.abs(Crypto.getRandomLong()) + '@carltontest.invalid',
            ProfileId = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1].Id,
            TimeZoneSidKey = 'America/Chicago', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', IsActive = true
        );
    }
}