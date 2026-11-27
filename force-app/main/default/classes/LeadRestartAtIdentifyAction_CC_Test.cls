/**
 * Tests for the Re-Nurture -> Identify reactivation loop: LeadRestartAtIdentifyAction_CC (pilot card) and
 * LeadLifecycleCycle_CC (cycle bookkeeping and review enforcement, through LeadStageTransitionService_CC).
 * The action methods run as the System Administrator running the tests (TestAdminAccess_CC), because the action
 * checks field access and saves in user mode, and the Sales / Marketing profiles' field access and custom permissions
 * are not deployed with the code. Tests whose behaviour depends on the stage rules for Sales / Marketing users still
 * save as those users.
 */
@isTest
private class LeadRestartAtIdentifyAction_CC_Test {

    private static final String MARKETING_PROFILE = 'Carlton Marketing User';
    private static final String SALES_PROFILE = 'Carlton Sales User';
    private static final String PILOT_EMAIL = 'lead.restart.pilot@carltontest.invalid';
    private static final String CONTROL_EMAIL = 'lead.restart.control@carltontest.invalid';
    private static final String UI_REWORK_PERMISSION_SET = 'Lead_UI_Rework_User_CC';
    private static final String INC_ENTITY = 'Carlton Packaging INC';
    private static final String QUALIFIED_OUTCOME = 'Qualified';
    private static final String NOTE = 'New buyer in post; budget reopened';
    private static Integer sequence = 0;

    @TestSetup
    static void setupUsers() {
        // The action checks field access and saves in user mode: give the running admin access to the Lead fields.
        TestAdminAccess_CC.grant(new List<SObjectType>{ Lead.SObjectType });
        List<User> pilotUsers = new List<User>{
            buildUser(SALES_PROFILE, 'rstsls', PILOT_EMAIL), buildUser(MARKETING_PROFILE, 'rstmkt', PILOT_EMAIL)
        };
        User control = buildUser(SALES_PROFILE, 'rstctl', CONTROL_EMAIL);
        insert pilotUsers;
        insert control;
        Id permissionSetId = [SELECT Id FROM PermissionSet WHERE Name = :UI_REWORK_PERMISSION_SET LIMIT 1].Id;
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (User pilot : pilotUsers) {
            assignments.add(new PermissionSetAssignment(AssigneeId = pilot.Id, PermissionSetId = permissionSetId));
        }
        insert assignments;
        // Queue membership is shared with other Lead test classes; retry if a parallel test holds the lock.
        TestDmlRetry_CC.insertWithRetry(new List<SObject>{ new GroupMember(GroupId = marketingPoolId(), UserOrGroupId = pilotUsers[1].Id) });
    }

    // ------------------------------------------------------------------ restart

    @isTest
    static void queueOwnedLead_Restarts_LogsThenResetsCycleControls() {
        Lead leadRecord = reNurtureLead(marketingPoolId());
        leadRecord.Meeting_Outcome_CC__c = QUALIFIED_OUTCOME;
        leadRecord.Bypass_Duplicate_Rules_on_Qualification__c = true;
        insert leadRecord;

        LeadRestartAtIdentifyAction_CC.Context context;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            context = LeadRestartAtIdentifyAction_CC.getContext(leadRecord.Id);
            LeadRestartAtIdentifyAction_CC.restart(leadRecord.Id, NOTE);
        }
        Test.stopTest();

        Assert.isTrue(context.canRestart, 'A user who can edit the queue-owned Lead should be offered the restart: ' + context.restartMessage);
        Assert.isTrue(context.ownedByQueue, 'The card should know a queue owns the Lead');
        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Qualify', result.Status, 'The restart action resumes at Qualify (the Identify details are kept)');
        Assert.areEqual(2, result.Lifecycle_Cycle_CC__c, 'Restart starts cycle 2');
        Assert.areEqual(marketingPoolId(), result.OwnerId, 'The Marketing pool stays the owner');
        Assert.isNull(result.Meeting_Outcome_CC__c, 'The old positive outcome must not carry into the new cycle');
        Assert.isNull(result.Re_Nurture_Reason_CC__c, 'Re-Nurture reason is cleared after logging');
        Assert.isNull(result.Reengagement_Date_CC__c, 'Re-engagement date is cleared after logging');
        Assert.isFalse(result.Bypass_Duplicate_Rules_on_Qualification__c, 'An old duplicate confirmation is not new review evidence');
        Assert.areEqual(leadRecord.Company, result.Company, 'Company facts are kept');
        Assert.areEqual('Buyer', result.Title, 'Contact facts are kept');
        Assert.isTrue(result.Lifecycle_History_CC__c.contains('| RESTART AT IDENTIFY | cycle 2 |'), result.Lifecycle_History_CC__c);
        Assert.isTrue(result.Lifecycle_History_CC__c.contains(NOTE), 'The restart note is kept');
        Assert.isTrue(result.Lifecycle_History_CC__c.contains('reason: Other'), 'The previous reason is kept');
        Assert.isTrue(result.Lifecycle_History_CC__c.contains('previous meeting outcome: ' + QUALIFIED_OUTCOME),
            'The previous outcome is kept');
        Assert.isTrue(result.Stage_Progress_Message_CC__c.contains(LeadLifecycleCycle_CC.QUALIFICATION_REVIEW_GAP),
            'Next Step asks for this cycle\'s qualification review: ' + result.Stage_Progress_Message_CC__c);
    }

    // ------------------------------------------------------------------ review gates

    // The restart action resumes at Qualify with the identity review already satisfied (the Identify details are
    // kept), so only the qualification review gates the new cycle.
    @isTest
    static void restartedLead_OldCompleteFieldsCannotSkipTheQualificationReview() {
        Lead leadRecord = reNurtureLead(UserInfo.getUserId());
        insert leadRecord;

        String identityConfirm;
        Lead afterUnrelatedQualify;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadRestartAtIdentifyAction_CC.restart(leadRecord.Id, NOTE);
            identityConfirm = confirmFailure(leadRecord.Id, 'identity');
            update new Lead(Id = leadRecord.Id, Description = 'Unrelated edit');
            afterUnrelatedQualify = reload(leadRecord.Id);
            LeadRestartAtIdentifyAction_CC.confirmReview(leadRecord.Id, 'qualification');
        }
        Test.stopTest();

        Assert.areEqual(LeadRestartAtIdentifyAction_CC.NO_REVIEW, identityConfirm,
            'A Lead restarted at Qualify has no identity review left to confirm');
        Assert.areEqual('Qualify', afterUnrelatedQualify.Status, 'Complete qualification fields alone must not advance to Engage');
        Assert.isTrue(afterUnrelatedQualify.Stage_Progress_Message_CC__c.contains(LeadLifecycleCycle_CC.QUALIFICATION_REVIEW_GAP),
            afterUnrelatedQualify.Stage_Progress_Message_CC__c);
        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Engage', result.Status, 'Confirming the qualification review completes Qualify');
        Assert.isTrue(result.Stage_Progress_Message_CC__c.startsWith('Book a meeting'),
            'A new outcome is needed: ' + result.Stage_Progress_Message_CC__c);
        Assert.isTrue(result.Lifecycle_History_CC__c.contains('QUALIFICATION REVIEW CONFIRMED'), 'Qualification confirmation is logged');
    }

    // A manual Re-Nurture -> Identify edit is still a restart at Identify, which keeps both review gates.
    @isTest
    static void manualRestartAtIdentify_RequiresTheIdentityReviewFirst() {
        Lead leadRecord = reNurtureLead(UserInfo.getUserId());
        insert leadRecord;

        Lead afterUnrelatedIdentify;
        String afterIdentityConfirm;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            update new Lead(Id = leadRecord.Id, Status = 'Identify');
            update new Lead(Id = leadRecord.Id, Description = 'Unrelated edit');
            afterUnrelatedIdentify = reload(leadRecord.Id);
            afterIdentityConfirm = LeadRestartAtIdentifyAction_CC.confirmReview(leadRecord.Id, 'identity');
        }
        Test.stopTest();

        Assert.areEqual('Identify', afterUnrelatedIdentify.Status, 'Complete identity fields alone must not advance a restarted Lead');
        Assert.isTrue(afterUnrelatedIdentify.Stage_Progress_Message_CC__c.contains('Confirm identity review'),
            afterUnrelatedIdentify.Stage_Progress_Message_CC__c);
        Assert.areEqual('Qualify', afterIdentityConfirm, 'Confirming the identity review advances one stage only');
        Assert.isTrue(reload(leadRecord.Id).Lifecycle_History_CC__c.contains('IDENTITY REVIEW CONFIRMED'), 'Identity confirmation is logged');
    }

    @isTest
    static void explicitStatusMoves_CannotSkipReviews_EvenForAdmin() {
        Lead atIdentify = cycleTwoLead('Identify', false, false);
        Lead atQualify = cycleTwoLead('Qualify', true, false);
        if (!TestLeadRouting_CC.insertIdentifyLeads(new List<Lead>{ atIdentify })) {
            return; // the Entity pool mapped in Lead_Company_Owner_Mapping_CC does not exist in this org
        }
        insert atQualify;

        Test.startTest();
        Database.SaveResult skipIdentify = Database.update(new Lead(Id = atIdentify.Id, Status = 'Qualify'), false);
        Database.SaveResult skipQualify = Database.update(new Lead(Id = atQualify.Id, Status = 'Engage'), false);
        Test.stopTest();

        Assert.isFalse(skipIdentify.isSuccess(), 'Identify -> Qualify without the identity review must fail');
        Assert.isTrue(String.valueOf(skipIdentify.getErrors()).contains(LeadLifecycleCycle_CC.IDENTITY_BLOCK), String.valueOf(skipIdentify.getErrors()));
        Assert.isFalse(skipQualify.isSuccess(), 'Qualify -> Engage without the qualification review must fail');
        Assert.isTrue(String.valueOf(skipQualify.getErrors()).contains(LeadLifecycleCycle_CC.QUALIFICATION_BLOCK), String.valueOf(skipQualify.getErrors()));
    }

    @isTest
    static void conversion_OfUnreviewedRestartedLead_IsBlockedForEveryEntryPoint() {
        Lead leadRecord = cycleTwoLead('Engage', true, false);
        leadRecord.Meeting_Outcome_CC__c = QUALIFIED_OUTCOME;
        // Entity Lead converted into an existing Entity Account: a new Account would take the running user's default
        // record type, which differs between orgs (profiles are not deployed), and could stop at the Account rule
        // before the Lead trigger is reached.
        leadRecord.Lead_Type_CC__c = 'Entity';
        insert leadRecord;
        Account entity = new Account(Name = 'ZZTEST Restart Entity ' + Math.abs(Crypto.getRandomInteger()),
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Entity').getRecordTypeId());
        OpportunityUi2TestData_CC.saveAllowingDuplicates(entity);
        String convertedStatus = [SELECT ApiName FROM LeadStatus WHERE IsConverted = true LIMIT 1].ApiName;

        Test.startTest();
        Database.LeadConvert request = new Database.LeadConvert();
        request.setLeadId(leadRecord.Id);
        request.setAccountId(entity.Id);
        request.setConvertedStatus(convertedStatus);
        request.setDoNotCreateOpportunity(true);
        Database.LeadConvertResult result = Database.convertLead(request, false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'A restarted Lead without both reviews must not convert');
        Assert.isTrue(String.valueOf(result.getErrors()).contains(LeadLifecycleCycle_CC.CONVERSION_BLOCK), String.valueOf(result.getErrors()));
    }

    @isTest
    static void confirmationAtTheWrongStage_IsRejected() {
        Lead leadRecord = cycleTwoLead('Identify', false, false);
        if (!TestLeadRouting_CC.insertIdentifyLeads(new List<Lead>{ leadRecord })) {
            return; // the Entity pool mapped in Lead_Company_Owner_Mapping_CC does not exist in this org
        }

        Test.startTest();
        Database.SaveResult early = Database.update(new Lead(Id = leadRecord.Id, Qualification_Review_Confirmed_CC__c = true), false);
        Test.stopTest();

        Assert.isFalse(early.isSuccess(), 'The qualification review cannot be confirmed at Identify');
        Assert.isTrue(String.valueOf(early.getErrors()).contains(LeadLifecycleCycle_CC.QUALIFICATION_WRONG_STAGE), String.valueOf(early.getErrors()));
    }

    @isTest
    static void confirmReview_WithNothingPending_IsRejected() {
        Lead firstCycle = reNurtureLead(UserInfo.getUserId());
        firstCycle.Status = 'Identify';
        if (!TestLeadRouting_CC.insertIdentifyLeads(new List<Lead>{ firstCycle })) {
            return; // the Entity pool mapped in Lead_Company_Owner_Mapping_CC does not exist in this org
        }

        String failure;
        LeadRestartAtIdentifyAction_CC.Context context;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            context = LeadRestartAtIdentifyAction_CC.getContext(firstCycle.Id);
            failure = confirmFailure(firstCycle.Id, 'identity');
        }
        Test.stopTest();

        Assert.isNull(context.pendingReview, 'A first-cycle Lead has no review to confirm');
        Assert.areEqual(LeadRestartAtIdentifyAction_CC.NO_REVIEW, failure, 'Direct calls get the same answer');
    }

    // ------------------------------------------------------------------ denials and stale confirmation

    // The running admin does not hold the Lead_UI_Rework_User_CC pilot permission set.
    @isTest
    static void nonPilotUser_CanRestart() {
        Lead leadRecord = reNurtureLead(UserInfo.getUserId());
        insert leadRecord;

        String failure;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            failure = restartFailure(leadRecord.Id, NOTE);
        }
        Test.stopTest();

        Assert.isNull(failure, 'The pilot permission is no longer required');
        Assert.areEqual('Qualify', reload(leadRecord.Id).Status, 'A user without the pilot permission restarts the Lead');
    }

    @isTest
    static void missingNote_WrongStatus_StaleSecondConfirm_AndNonLeadId_AreRejected() {
        Lead reNurture = reNurtureLead(UserInfo.getUserId());
        Lead disqualified = reNurtureLead(UserInfo.getUserId());
        disqualified.Status = 'Disqualified';
        disqualified.Disqualified_Reason_CC__c = firstValue(Lead.Disqualified_Reason_CC__c);
        disqualified.Disqualification_Comments_CC__c = 'Closed';
        insert new List<Lead>{ reNurture, disqualified };

        String noNote;
        String wrongStatus;
        String secondConfirm;
        String notALead;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            noNote = restartFailure(reNurture.Id, '  ');
            wrongStatus = restartFailure(disqualified.Id, NOTE);
            LeadRestartAtIdentifyAction_CC.restart(reNurture.Id, NOTE);
            secondConfirm = restartFailure(reNurture.Id, NOTE);
            notALead = restartFailure(UserInfo.getUserId(), NOTE);
        }
        Test.stopTest();

        Assert.areEqual(LeadRestartAtIdentifyAction_CC.NOTE_REQUIRED, noNote, 'A reason is required');
        Assert.areEqual(LeadRestartAtIdentifyAction_CC.NOT_RE_NURTURE, wrongStatus, 'Disqualified is not reopened');
        Assert.areEqual(LeadRestartAtIdentifyAction_CC.NOT_RE_NURTURE, secondConfirm, 'A stale second confirm writes nothing');
        Assert.areEqual(LeadRestartAtIdentifyAction_CC.NO_ACCESS, notALead, 'Non-Lead Ids are rejected');
        Assert.areEqual(2, reload(reNurture.Id).Lifecycle_Cycle_CC__c, 'Only one restart happened');
        Assert.areEqual('Disqualified', reload(disqualified.Id).Status, 'Disqualified stays closed');
    }

    @isTest
    static void restartProblem_ConvertedLead_IsRejected() {
        Lead converted = (Lead) JSON.deserialize('{"attributes":{"type":"Lead"},"IsConverted":true,"Status":"Re-Nurture"}', Lead.class);
        Assert.areEqual(LeadRestartAtIdentifyAction_CC.CONVERTED, LeadRestartAtIdentifyAction_CC.restartProblem(converted),
            'Converted Leads cannot enter the recycle loop');
    }

    // ------------------------------------------------------------------ repeated cycles, ownership timing

    @isTest
    static void twoFullRecycles_KeepEveryReasonAndCountCycles() {
        Lead leadRecord = reNurtureLead(UserInfo.getUserId());
        leadRecord.Status = 'Engage';
        leadRecord.Re_Nurture_Reason_CC__c = null;
        leadRecord.Re_Nurture_Comments_CC__c = null;
        leadRecord.Reengagement_Date_CC__c = null;
        insert leadRecord;

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            for (String reason : new List<String>{ 'Budget Not Available', 'Not Ready to Buy' }) {
                update new Lead(Id = leadRecord.Id, Re_Nurture_Reason_CC__c = reason,
                    Re_Nurture_Comments_CC__c = 'Cycle note ' + reason, Reengagement_Date_CC__c = Date.today().addMonths(2));
                Assert.areEqual('Re-Nurture', reload(leadRecord.Id).Status, 'Reason and date re-nurture the Lead');
                LeadRestartAtIdentifyAction_CC.restart(leadRecord.Id, 'Restart after ' + reason);
                LeadRestartAtIdentifyAction_CC.confirmReview(leadRecord.Id, 'qualification');
                Assert.areEqual('Engage', reload(leadRecord.Id).Status, 'The qualification review brings the Lead back to Engage');
            }
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual(3, result.Lifecycle_Cycle_CC__c, 'Two restarts make cycle 3');
        String history = result.Lifecycle_History_CC__c;
        Assert.isTrue(history.contains('Cycle note Budget Not Available'), 'The first cycle comments are kept');
        Assert.isTrue(history.contains('Cycle note Not Ready to Buy'), 'The second cycle comments are kept');
        Assert.areEqual(2, history.countMatches('| RE-NURTURE |'), 'Each Re-Nurture entry is logged once');
        Assert.areEqual(2, history.countMatches('| RESTART AT IDENTIFY |'), 'Each restart is logged once');
        Assert.isTrue(history.indexOf('cycle 3') < history.indexOf('cycle 2'), 'History is newest first');
    }

    @isTest
    static void restartBeforeOwnerTransferJob_JobLeavesOwnerAlone() {
        Id ownerId = UserInfo.getUserId();
        Lead leadRecord = reNurtureLead(ownerId);
        insert leadRecord;

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadRestartAtIdentifyAction_CC.restart(leadRecord.Id, NOTE);
        }
        // The transfer queued when the Lead entered Re-Nurture runs late, after the restart.
        new ChangeOwnerOnReNurture_CC(new Map<Id, Id>{ leadRecord.Id => ownerId }).execute(null);
        Test.stopTest();

        Assert.areEqual(ownerId, reload(leadRecord.Id).OwnerId, 'A late Re-Nurture owner transfer must not move a restarted Lead');
    }

    // The duplicate checkpoint is on entry to Qualified (LeadStageTransitionService_CC), not Engage, so the restarted
    // Lead reaches Engage; the old "not a duplicate" confirmation is cleared so the Qualified entry checks again.
    @isTest
    static void restartClearsOldDuplicateConfirmation_SoQualifiedChecksAgain() {
        Lead original = reNurtureLead(UserInfo.getUserId());
        original.Status = 'Engage';
        insert original;
        Lead copy = original.clone(false, true, false, false);
        copy.Status = 'Re-Nurture';
        copy.Bypass_Duplicate_Rules_on_Qualification__c = true;
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Assert.isTrue(Database.insert(copy, options).isSuccess(), 'Duplicate copy should save with allowSave');

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            LeadRestartAtIdentifyAction_CC.restart(copy.Id, NOTE);
            LeadRestartAtIdentifyAction_CC.confirmReview(copy.Id, 'qualification');
        }
        Test.stopTest();

        Lead result = reload(copy.Id);
        Assert.areEqual('Engage', result.Status, 'There is no duplicate checkpoint on entry to Engage');
        Assert.isFalse(result.Bypass_Duplicate_Rules_on_Qualification__c,
            'The old duplicate confirmation is cleared, so entry to Qualified checks for duplicates again');
        Assert.isTrue(result.Lifecycle_History_CC__c.contains('duplicate confirmation cleared for a new check'),
            'Clearing the confirmation is logged');
    }

    // ------------------------------------------------------------------ Return to Engage interplay

    @isTest
    static void returnToEngage_ClearsOldOutcome_AndStaleCommentsDoNotReNurtureAgain() {
        Lead leadRecord = reNurtureLead(UserInfo.getUserId());
        leadRecord.Status = 'Engage';
        leadRecord.Meeting_Outcome_CC__c = 'Re-Nurture';
        leadRecord.Re_Nurture_Reason_CC__c = null;
        leadRecord.Reengagement_Date_CC__c = null;
        insert leadRecord;

        Lead afterStaleEdit;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            update new Lead(Id = leadRecord.Id, Re_Nurture_Reason_CC__c = 'Other', Reengagement_Date_CC__c = Date.today().addMonths(1));
            LeadReturnToEngageAction_CC.returnToEngage(leadRecord.Id);
            update new Lead(Id = leadRecord.Id, Re_Nurture_Comments_CC__c = 'Only the comments changed');
            afterStaleEdit = reload(leadRecord.Id);
        }
        Test.stopTest();

        Assert.areEqual('Engage', afterStaleEdit.Status, 'Old reason and date must not re-nurture on a comments-only edit');
        Assert.isNull(afterStaleEdit.Meeting_Outcome_CC__c, 'The previous outcome is cleared on return');
        Assert.areEqual('Other', afterStaleEdit.Re_Nurture_Reason_CC__c, 'Return to Engage keeps the Re-Nurture details');
        Assert.isTrue(afterStaleEdit.Lifecycle_History_CC__c.contains('previous meeting outcome: Re-Nurture'),
            afterStaleEdit.Lifecycle_History_CC__c);
        Assert.isNull(afterStaleEdit.Lifecycle_Cycle_CC__c, 'Return to Engage does not start a new cycle');
    }

    // ------------------------------------------------------------------ messages and bulk

    @isTest
    static void reNurtureNextStep_ExplainsFollowUpAndBothRoutes() {
        Lead dated = reNurtureLead(UserInfo.getUserId());
        dated.Status = 'Engage';
        dated.Re_Nurture_Reason_CC__c = null;
        dated.Reengagement_Date_CC__c = null;
        insert dated;

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            update new Lead(Id = dated.Id, Re_Nurture_Reason_CC__c = 'Not Ready to Buy', Reengagement_Date_CC__c = Date.today().addMonths(1));
        }
        Test.stopTest();

        String message = reload(dated.Id).Stage_Progress_Message_CC__c;
        Assert.isTrue(message.contains('Re-Nurture Follow-ups'), message);
        Assert.isTrue(message.contains('Restart at Identify') && message.contains('Return to Engage'), message);
        Assert.isTrue(message.length() <= 255, 'Message must fit the field');
    }

    @isTest
    static void everyActiveMeetingOutcome_HasANextStepThatFitsAndNeverChangesStatus() {
        User salesUser = user(SALES_PROFILE, PILOT_EMAIL);
        List<Lead> leads = new List<Lead>();
        List<String> outcomes = new List<String>();
        for (Schema.PicklistEntry entry : Lead.Meeting_Outcome_CC__c.getDescribe().getPicklistValues()) {
            if (entry.isActive() && entry.getValue() != QUALIFIED_OUTCOME) {
                Lead leadRecord = reNurtureLead(salesUser.Id);
                leadRecord.Status = 'Engage';
                leadRecord.Re_Nurture_Reason_CC__c = null;
                leadRecord.Re_Nurture_Comments_CC__c = null;
                leadRecord.Reengagement_Date_CC__c = null;
                leads.add(leadRecord);
                outcomes.add(entry.getValue());
            }
        }
        insert leads;

        Test.startTest();
        System.runAs(salesUser) {
            List<Lead> updates = new List<Lead>();
            for (Integer i = 0; i < leads.size(); i++) {
                updates.add(new Lead(Id = leads[i].Id, Meeting_Outcome_CC__c = outcomes[i]));
            }
            update updates;
        }
        Test.stopTest();

        for (Integer i = 0; i < leads.size(); i++) {
            Lead result = reload(leads[i].Id);
            Assert.areEqual('Engage', result.Status, outcomes[i] + ' must not change Status by itself');
            // Outcomes without their own entry in OUTCOME_NEXT_STEPS get the general "choose the next step" text.
            String expected = LeadStageTransitionService_CC.OUTCOME_NEXT_STEPS.containsKey(outcomes[i])
                ? LeadStageTransitionService_CC.OUTCOME_NEXT_STEPS.get(outcomes[i])
                : 'Outcome ' + outcomes[i] + ': choose the next step (rebook, Re-Nurture or Disqualify). The Lead stays at Engage.';
            Assert.isTrue(expected.length() <= 255, outcomes[i] + ' text too long');
            Assert.isTrue(result.Stage_Progress_Message_CC__c.startsWith(expected),
                'Next Step should give the ' + outcomes[i] + ' action: ' + result.Stage_Progress_Message_CC__c);
        }
    }

    @isTest
    static void bulkRestartByPilotUser_200Leads_BoundedQueries() {
        User marketingUser = user(MARKETING_PROFILE, PILOT_EMAIL);
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            leads.add(reNurtureLead(marketingUser.Id));
        }
        insert leads;
        List<Lead> updates = new List<Lead>();
        for (Lead leadRecord : leads) {
            updates.add(new Lead(Id = leadRecord.Id, Status = 'Identify'));
        }

        Integer queriesUsed;
        Test.startTest();
        System.runAs(marketingUser) {
            update updates;
            queriesUsed = Limits.getQueries();
        }
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Lead WHERE Id IN :leads AND Lifecycle_Cycle_CC__c = 2 AND Status = 'Identify' WITH SYSTEM_MODE],
            'A pilot user\'s Re-Nurture -> Identify edit is a restart for every Lead');
        Assert.isTrue(queriesUsed < 30, 'Bulk restart should use a bounded number of queries, used ' + queriesUsed);
    }

    // The pilot permission no longer gates the restart (LeadLifecycleCycle_CC.apply), so a manual
    // Re-Nurture -> Identify edit by any user starts a new cycle.
    @isTest
    static void nonPilotManualReNurtureToIdentify_StartsANewCycle() {
        User control = user(SALES_PROFILE, CONTROL_EMAIL);
        Lead leadRecord = reNurtureLead(control.Id);
        insert leadRecord;

        Test.startTest();
        System.runAs(control) {
            update new Lead(Id = leadRecord.Id, Status = 'Identify');
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Identify', result.Status, 'The deployed rules allow this move');
        Assert.areEqual(2, result.Lifecycle_Cycle_CC__c, 'Every user\'s Re-Nurture -> Identify edit is a restart');
    }

    // ------------------------------------------------------------------ helpers

    /** A cycle-2 Lead at the given status that meets every stage rule (inserted by the admin test runner). */
    private static Lead cycleTwoLead(String status, Boolean identityConfirmed, Boolean qualificationConfirmed) {
        Lead leadRecord = reNurtureLead(UserInfo.getUserId());
        leadRecord.Status = status;
        leadRecord.Re_Nurture_Reason_CC__c = null;
        leadRecord.Re_Nurture_Comments_CC__c = null;
        leadRecord.Reengagement_Date_CC__c = null;
        leadRecord.Lifecycle_Cycle_CC__c = 2;
        leadRecord.Identity_Review_Confirmed_CC__c = identityConfirmed;
        leadRecord.Qualification_Review_Confirmed_CC__c = qualificationConfirmed;
        return leadRecord;
    }

    /** A Re-Nurture Lead that meets the Identify and Engage gates, with saved Re-Nurture details. */
    private static Lead reNurtureLead(Id ownerId) {
        sequence++;
        String suffix = String.valueOf(sequence) + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new Lead(
            FirstName = 'Restart', LastName = 'Tester ' + suffix, Company = 'Restart Co ' + suffix, Status = 'Re-Nurture',
            Title = 'Buyer', Email = 'restart' + suffix + '@carltontest.invalid', Phone = '+1 555 0100',
            City = 'Chicago', PostalCode = '60601', CountryCode = 'US', Belongs_To_CC__c = INC_ENTITY,
            LeadSource = 'Web Search', Lead_Type_CC__c = 'Site', Estimated_Annual_Spend_CC__c = 150000,
            Re_Nurture_Reason_CC__c = 'Other', Re_Nurture_Comments_CC__c = 'Budget frozen',
            Reengagement_Date_CC__c = Date.today().addMonths(3), OwnerId = ownerId
        );
    }

    private static String restartFailure(Id leadId, String note) {
        try {
            LeadRestartAtIdentifyAction_CC.restart(leadId, note);
        } catch (AuraHandledException ex) {
            return ex.getMessage();
        }
        return null;
    }

    private static String confirmFailure(Id leadId, String review) {
        try {
            LeadRestartAtIdentifyAction_CC.confirmReview(leadId, review);
        } catch (AuraHandledException ex) {
            return ex.getMessage();
        }
        return null;
    }

    private static Lead reload(Id leadId) {
        return [SELECT Status, OwnerId, Company, Title, Meeting_Outcome_CC__c, Re_Nurture_Reason_CC__c, Reengagement_Date_CC__c,
                       Bypass_Duplicate_Rules_on_Qualification__c, Duplicate_Review_Required_CC__c, Lifecycle_Cycle_CC__c,
                       Lifecycle_History_CC__c, Stage_Progress_Message_CC__c
                FROM Lead WHERE Id = :leadId WITH SYSTEM_MODE];
    }

    private static Id marketingPoolId() {
        return [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'US_Marketing_Pool' LIMIT 1].Id;
    }

    private static String firstValue(Schema.SObjectField field) {
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive() && entry.getValue() != 'Other') {
                return entry.getValue();
            }
        }
        return null;
    }

    private static User user(String profileName, String email) {
        return [SELECT Id FROM User WHERE Email = :email AND Profile.Name = :profileName AND IsActive = true LIMIT 1];
    }

    private static User buildUser(String profileName, String alias, String email) {
        return new User(
            FirstName = 'Restart', LastName = 'Test ' + alias, Alias = alias, Email = email,
            Username = alias + Math.abs(Crypto.getRandomLong()) + '@carltontest.invalid',
            ProfileId = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1].Id,
            TimeZoneSidKey = 'America/Chicago', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', IsActive = true
        );
    }
}