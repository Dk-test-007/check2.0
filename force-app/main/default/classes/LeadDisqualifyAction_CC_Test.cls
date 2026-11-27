/**
 * Tests for LeadDisqualifyAction_CC (Lead UI pilot Disqualify action). Runs as the System Administrator running the
 * tests, with the Carlton permission sets and Lead field access (TestAdminAccess_CC), because the action reads the
 * Lead in user mode and checks that the user can edit the Status, Disqualified Reason and Disqualification Comments.
 */
@isTest
private class LeadDisqualifyAction_CC_Test {

    private static final String INC_ENTITY = 'Carlton Packaging INC';
    private static final String REASON = 'No Business Need';
    private static Integer sequence = 0;

    @TestSetup
    static void grantAccess() {
        TestAdminAccess_CC.grant(new List<SObjectType>{ Lead.SObjectType });
    }

    // ------------------------------------------------------------------ allowed at every active stage, incomplete

    @isTest
    static void namedIdentifyLead_IncompleteIdentify_IsDisqualified() {
        Lead leadRecord = baseLead('Identify');
        leadRecord.LeadSource = null;
        insert leadRecord;

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadDisqualifyAction_CC.disqualify(leadRecord.Id, REASON, null);
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Disqualified', result.Status, 'A named Identify Lead should be disqualified by the action');
        Assert.areEqual(REASON, result.Disqualified_Reason_CC__c, 'Reason should be saved in the same update');
        Assert.isTrue(result.Disqualified_By_Pilot_Action_CC__c, 'The action marker should be set');
    }

    @isTest
    static void placeholderIdentifyLead_IsDisqualified() {
        Lead leadRecord = baseLead('Identify');
        leadRecord.FirstName = null;
        leadRecord.LastName = 'Needs to Identify - ' + leadRecord.Company;
        insert leadRecord;

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadDisqualifyAction_CC.disqualify(leadRecord.Id, 'Other', 'Company closed the site');
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Disqualified', result.Status, 'A company-only placeholder Lead should be disqualified');
        Assert.areEqual('Company closed the site', result.Disqualification_Comments_CC__c, 'Comments should be saved');
    }

    @isTest
    static void incompleteQualifyLead_NoQualificationMetricsNeeded() {
        Lead leadRecord = baseLead('Qualify');
        insert leadRecord;

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadDisqualifyAction_CC.disqualify(leadRecord.Id, REASON, null);
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Disqualified', result.Status, 'Qualify Lead without Lead Type or metrics should be disqualified');
        Assert.isNull(result.Lead_Type_CC__c, 'No qualification input should have been required');
    }

    @isTest
    static void engageLeadWithoutMeetingOutcome_IsDisqualified() {
        Lead leadRecord = baseLead('Engage');
        leadRecord.Lead_Type_CC__c = 'Site';
        leadRecord.Estimated_Annual_Spend_CC__c = 150000;
        insert leadRecord;

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadDisqualifyAction_CC.disqualify(leadRecord.Id, REASON, '  Budget moved  ');
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Disqualified', result.Status, 'Engage Lead without a meeting outcome should be disqualified');
        Assert.areEqual('Budget moved', result.Disqualification_Comments_CC__c, 'Comments should be trimmed');
    }

    // ------------------------------------------------------------------ reason / comments validation

    @isTest
    static void otherReasonWithoutComments_IsRejectedAndNothingSaved() {
        assertRejected('Other', '   ', LeadDisqualifyAction_CC.COMMENTS_REQUIRED);
    }

    @isTest
    static void blankReason_IsRejectedAndNothingSaved() {
        assertRejected(null, 'Some comments', LeadDisqualifyAction_CC.REASON_REQUIRED);
    }

    @isTest
    static void unknownOrInactiveReason_IsRejectedAndNothingSaved() {
        assertRejected('Unable to Contact', null, LeadDisqualifyAction_CC.REASON_INVALID);
    }

    @isTest
    static void overLongComments_AreRejected() {
        Integer maxLength = Lead.Disqualification_Comments_CC__c.getDescribe().getLength();
        assertRejected('Other', 'x'.repeat(maxLength + 1), LeadDisqualifyAction_CC.COMMENTS_TOO_LONG);
    }

    // ------------------------------------------------------------------ record state

    @isTest
    static void alreadyDisqualifiedOrReNurtureLead_IsRejected() {
        Lead leadRecord = baseLead('Qualify');
        insert leadRecord;

        String message;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadDisqualifyAction_CC.disqualify(leadRecord.Id, REASON, null);
            message = failureOf(leadRecord.Id, REASON, null);
        }
        Test.stopTest();

        Assert.areEqual(LeadDisqualifyAction_CC.NOT_ACTIVE, message, 'A Lead outside Identify/Qualify/Engage must be rejected');
    }

    @isTest
    static void convertedLead_IsRejectedBeforeAnyAccessCheck() {
        Lead converted = (Lead) JSON.deserialize(
            '{"attributes":{"type":"Lead"},"Status":"Qualified","IsConverted":true}', Lead.class);
        Assert.areEqual(LeadDisqualifyAction_CC.CONVERTED, LeadDisqualifyAction_CC.recordProblem(converted),
            'Converted Leads must be rejected');
        Assert.areEqual(LeadDisqualifyAction_CC.NO_ACCESS, LeadDisqualifyAction_CC.recordProblem(null),
            'An invisible or missing Lead must be rejected');
    }

    @isTest
    static void wrongObjectId_IsRejected() {
        String message;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            message = failureOf(UserInfo.getUserId(), REASON, null);
        }
        Test.stopTest();
        Assert.areEqual(LeadDisqualifyAction_CC.NO_ACCESS, message, 'A non-Lead Id must be rejected');
    }

    @isTest
    static void context_ForEligibleUser_OffersActiveReasonsAndCurrentValues() {
        Lead leadRecord = baseLead('Engage');
        leadRecord.Lead_Type_CC__c = 'Site';
        leadRecord.Estimated_Annual_Spend_CC__c = 150000;
        leadRecord.Disqualification_Comments_CC__c = 'Earlier note';
        insert leadRecord;

        LeadDisqualifyAction_CC.Context context;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            context = LeadDisqualifyAction_CC.getContext(leadRecord.Id);
        }
        Test.stopTest();

        Assert.isTrue(context.canDisqualify, 'A user with edit access at Engage should be offered the action: ' + context.message);
        Assert.areEqual('Engage', context.status, 'Context should report the current status');
        Assert.areEqual('Earlier note', context.currentComments, 'Current comments should prefill the form');
        Set<String> values = new Set<String>();
        for (LeadDisqualifyAction_CC.Option option : context.reasons) {
            values.add(option.value);
        }
        Assert.isTrue(values.contains('Other'), 'Active reasons should include Other');
        Assert.isFalse(values.contains('Unable to Contact'), 'Inactive reasons must not be offered');
    }

    // ------------------------------------------------------------------ helpers

    private static void assertRejected(String reason, String comments, String expected) {
        Lead leadRecord = baseLead('Qualify');
        insert leadRecord;

        String message;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            message = failureOf(leadRecord.Id, reason, comments);
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual(expected, message, 'Unexpected validation result');
        Assert.areEqual('Qualify', result.Status, 'Status must be unchanged');
        Assert.isNull(result.Disqualified_Reason_CC__c, 'Reason must not be saved');
        Assert.isFalse(result.Disqualified_By_Pilot_Action_CC__c, 'Marker must not be set');
    }

    private static String failureOf(Id leadId, String reason, String comments) {
        try {
            LeadDisqualifyAction_CC.disqualify(leadId, reason, comments);
        } catch (AuraHandledException ex) {
            return ex.getMessage();
        }
        return null;
    }

    /** A Lead owned by the running administrator. */
    private static Lead baseLead(String status) {
        sequence++;
        String suffix = String.valueOf(sequence) + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new Lead(
            FirstName = 'Disq', LastName = 'Tester ' + suffix, Company = 'Disq Co ' + suffix, Status = status,
            Title = 'Buyer', Email = 'disq' + suffix + '@carltontest.invalid', Phone = '+1 555 0100',
            City = 'Chicago', PostalCode = '60601', CountryCode = 'US',
            // No Entity at Identify, so Identify routing keeps the running user as owner.
            Belongs_To_CC__c = status == 'Identify' ? null : INC_ENTITY,
            LeadSource = 'Web Search', OwnerId = UserInfo.getUserId()
        );
    }

    private static Lead reload(Id leadId) {
        return [SELECT Status, Lead_Type_CC__c, Disqualified_Reason_CC__c, Disqualification_Comments_CC__c,
                       Disqualified_By_Pilot_Action_CC__c
                FROM Lead WHERE Id = :leadId WITH SYSTEM_MODE];
    }
}
