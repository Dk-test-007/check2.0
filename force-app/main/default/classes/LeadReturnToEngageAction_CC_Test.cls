/**
 * Tests for LeadReturnToEngageAction_CC (Lead UI pilot Return to Engage action). Runs as the System Administrator
 * running the tests, with the Carlton permission sets and Lead field access (TestAdminAccess_CC), because the action
 * reads and saves the Lead in user mode. The System Administrator profile passes the Sales check
 * (LeadReturnToEngageAction_CC.isOutcomePermitted); record state, the Engage gate and the duplicate checkpoint are the
 * behaviour under test.
 */
@isTest
private class LeadReturnToEngageAction_CC_Test {

    private static final String INC_ENTITY = 'Carlton Packaging INC';
    private static final String RE_NURTURE_COMMENTS = 'Budget frozen until next year';
    private static Integer sequence = 0;

    @TestSetup
    static void grantAccess() {
        TestAdminAccess_CC.grant(new List<SObjectType>{ Lead.SObjectType });
    }

    // ------------------------------------------------------------------ success

    @isTest
    static void returnsToEngage_KeepsReNurtureDetailsAndOwner() {
        Lead leadRecord = reNurtureLead();
        insert leadRecord;

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadReturnToEngageAction_CC.returnToEngage(leadRecord.Id);
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Engage', result.Status, 'The Lead should be back at Engage');
        Assert.areEqual('Other', result.Re_Nurture_Reason_CC__c, 'Re-Nurture Reason must be kept');
        Assert.areEqual(RE_NURTURE_COMMENTS, result.Re_Nurture_Comments_CC__c, 'Re-Nurture Comments must be kept');
        Assert.areEqual(leadRecord.Reengagement_Date_CC__c, result.Reengagement_Date_CC__c, 'Re-engagement Date must be kept');
        Assert.areEqual(UserInfo.getUserId(), result.OwnerId, 'Owner must not change');
        Assert.isTrue(result.Stage_Progress_Message_CC__c.startsWith('Book a meeting'),
            'Next Step should show the Engage work: ' + result.Stage_Progress_Message_CC__c);
        Assert.isFalse(result.Bypass_Duplicate_Rules_on_Qualification__c, 'The duplicate bypass must not be set');
    }

    @isTest
    static void context_ForEligibleUser_OffersTheAction() {
        Lead leadRecord = reNurtureLead();
        insert leadRecord;

        LeadReturnToEngageAction_CC.Context context;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            context = LeadReturnToEngageAction_CC.getContext(leadRecord.Id);
        }
        Test.stopTest();

        Assert.isTrue(context.canReturn, 'An eligible user at Re-Nurture should be offered the action: ' + context.message);
        Assert.areEqual('Re-Nurture', context.status, 'Context should report the current status');
        Assert.areEqual(leadRecord.Company, context.company, 'Context should name the company for the confirmation');
    }

    // ------------------------------------------------------------------ record state and Engage gate

    @isTest
    static void leadNotAtReNurture_IsRejected() {
        Lead leadRecord = reNurtureLead();
        leadRecord.Status = 'Engage';
        insert leadRecord;

        String message;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            message = failureOf(leadRecord.Id);
        }
        Test.stopTest();

        Assert.areEqual(LeadReturnToEngageAction_CC.NOT_RE_NURTURE, message, 'Only Re-Nurture Leads can return to Engage');
    }

    @isTest
    static void missingEngageInputs_AreListedAndNothingSaved() {
        Lead leadRecord = reNurtureLead();
        leadRecord.Title = null;
        leadRecord.Estimated_Annual_Spend_CC__c = null;
        insert leadRecord;

        String message;
        LeadReturnToEngageAction_CC.Context context;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            context = LeadReturnToEngageAction_CC.getContext(leadRecord.Id);
            message = failureOf(leadRecord.Id);
        }
        Test.stopTest();

        Assert.isTrue(message.startsWith(LeadReturnToEngageAction_CC.GAPS_PREFIX), 'Unexpected message: ' + message);
        Assert.isTrue(message.contains(Lead.Title.getDescribe().getLabel()), 'Title should be listed: ' + message);
        Assert.isTrue(message.contains(Lead.Estimated_Annual_Spend_CC__c.getDescribe().getLabel()),
            'The Site qualification rule should be listed: ' + message);
        Assert.areEqual(message, context.message, 'Panel should show the same gaps');
        Assert.areEqual('Re-Nurture', reload(leadRecord.Id).Status, 'Nothing should be written');
    }

    @isTest
    static void placeholderContact_IsRejectedByTheEngageGate() {
        Lead leadRecord = reNurtureLead();
        leadRecord.FirstName = null;
        leadRecord.LastName = 'Needs to Identify - ' + leadRecord.Company;
        insert leadRecord;

        String message;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            message = failureOf(leadRecord.Id);
        }
        Test.stopTest();

        Assert.isTrue(message.contains('Needs to Identify'), 'The placeholder contact should be listed first: ' + message);
        Assert.areEqual('Re-Nurture', reload(leadRecord.Id).Status, 'Nothing should be written');
    }

    @isTest
    static void convertedOrMissingLead_IsRejected() {
        Lead converted = (Lead) JSON.deserialize(
            '{"attributes":{"type":"Lead"},"Status":"Qualified","IsConverted":true}', Lead.class);
        Assert.areEqual(LeadReturnToEngageAction_CC.CONVERTED, LeadReturnToEngageAction_CC.recordProblem(converted),
            'Converted Leads must be rejected');
        Assert.areEqual(LeadReturnToEngageAction_CC.NO_ACCESS, LeadReturnToEngageAction_CC.recordProblem(null),
            'An invisible or missing Lead must be rejected');
    }

    @isTest
    static void wrongObjectId_IsRejected() {
        String message;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            message = failureOf(UserInfo.getUserId());
        }
        Test.stopTest();
        Assert.areEqual(LeadReturnToEngageAction_CC.NO_ACCESS, message, 'A non-Lead Id must be rejected');
    }

    // ------------------------------------------------------------------ duplicate checkpoint

    // The duplicate checkpoint runs on entry to Qualified (LeadStageTransitionService_CC), not on entry to Engage,
    // and the Lead duplicate rule only alerts, so a duplicate Lead returns to Engage without the bypass being set.
    @isTest
    static void duplicateLead_ReturnsToEngage_CheckpointIsAtQualified() {
        Lead copy = insertDuplicatePair(false);

        String message;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            message = failureOf(copy.Id);
        }
        Test.stopTest();

        Lead result = reload(copy.Id);
        Assert.isNull(message, 'There is no duplicate checkpoint on entry to Engage');
        Assert.areEqual('Engage', result.Status, 'The duplicate Lead returns to Engage');
        Assert.isFalse(result.Bypass_Duplicate_Rules_on_Qualification__c, 'The duplicate bypass must not be set');
    }

    @isTest
    static void duplicateLeadAlreadyMarkedNotDuplicate_ReturnsToEngage() {
        Lead copy = insertDuplicatePair(true);

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadReturnToEngageAction_CC.returnToEngage(copy.Id);
        }
        Test.stopTest();

        Assert.areEqual('Engage', reload(copy.Id).Status,
            'A user-confirmed non-duplicate passes the checkpoint; the Allow rule alert does not block');
    }

    // ------------------------------------------------------------------ helpers

    /** An Engage Lead and a matching Re-Nurture copy (bypass as given, standing in for a user's earlier choice). */
    private static Lead insertDuplicatePair(Boolean bypass) {
        Lead original = reNurtureLead();
        original.Status = 'Engage';
        insert original;
        Lead copy = original.clone(false, true, false, false);
        copy.Status = 'Re-Nurture';
        copy.Bypass_Duplicate_Rules_on_Qualification__c = bypass;
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.SaveResult inserted = Database.insert(copy, options);
        Assert.isTrue(inserted.isSuccess(), 'Duplicate should save with allowSave: ' + inserted.getErrors());
        return copy;
    }

    private static String failureOf(Id leadId) {
        try {
            LeadReturnToEngageAction_CC.returnToEngage(leadId);
        } catch (AuraHandledException ex) {
            return ex.getMessage();
        }
        return null;
    }

    /** A Re-Nurture Lead that meets the Engage gate, with saved Re-Nurture details, owned by the running administrator. */
    private static Lead reNurtureLead() {
        sequence++;
        String suffix = String.valueOf(sequence) + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new Lead(
            FirstName = 'Reengage', LastName = 'Tester ' + suffix, Company = 'Reengage Co ' + suffix, Status = 'Re-Nurture',
            Title = 'Buyer', Email = 'reengage' + suffix + '@carltontest.invalid', Phone = '+1 555 0100',
            City = 'Chicago', PostalCode = '60601', CountryCode = 'US', Belongs_To_CC__c = INC_ENTITY,
            LeadSource = 'Web Search', Lead_Type_CC__c = 'Site', Estimated_Annual_Spend_CC__c = 150000,
            Re_Nurture_Reason_CC__c = 'Other', Re_Nurture_Comments_CC__c = RE_NURTURE_COMMENTS,
            Reengagement_Date_CC__c = Date.today().addMonths(3), OwnerId = UserInfo.getUserId()
        );
    }

    private static Lead reload(Id leadId) {
        return [SELECT Status, OwnerId, Re_Nurture_Reason_CC__c, Re_Nurture_Comments_CC__c, Reengagement_Date_CC__c,
                       Stage_Progress_Message_CC__c, Bypass_Duplicate_Rules_on_Qualification__c
                FROM Lead WHERE Id = :leadId WITH SYSTEM_MODE];
    }
}
