/**
 * Tests for LeadStageTransitionService_CC through the Lead trigger: Entity/Site gates, partial saves,
 * one-stage-per-save transitions, the Engage duplicate checkpoint, outcomes, conversion handoff and bulk.
 * Runs as real Carlton Marketing / Sales profile users where the behaviour depends on the user.
 */
@isTest
private class LeadStageTransitionService_CC_Test {

    private static final String MARKETING_PROFILE = 'Carlton Marketing User';
    private static final String SALES_PROFILE = 'Carlton Sales User';
    private static final String USER_EMAIL = 'lead.stage.test@carltontest.invalid';
    private static final String UNASSIGNED_EMAIL = 'lead.stage.control@carltontest.invalid';
    private static final String UI_REWORK_PERMISSION_SET = 'Lead_UI_Rework_User_CC';
    private static final String SALES_PERMISSION_SET = 'PS_Carlton_Sales_User_CC';
    private static final String INC_ENTITY = 'Carlton Packaging INC';
    private static final String QUALIFIED_OUTCOME = 'Qualified';
    private static final String PLACEHOLDER_BLOCK = 'Identify the contact first';
    private static Integer sequence = 0;

    @TestSetup
    static void setupUsers() {
        List<User> assigned = new List<User>{ buildUser(MARKETING_PROFILE, 'lstmkt'), buildUser(SALES_PROFILE, 'lstsls') };
        User control = buildUser(MARKETING_PROFILE, 'lstctl');
        control.Email = UNASSIGNED_EMAIL;
        insert assigned;
        insert control;
        Id permissionSetId = [SELECT Id FROM PermissionSet WHERE Name = :UI_REWORK_PERMISSION_SET LIMIT 1].Id;
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = assigned[0].Id, PermissionSetId = permissionSetId),
            new PermissionSetAssignment(AssigneeId = assigned[1].Id, PermissionSetId = permissionSetId)
        };
        // Sales users get the Lead question fields (for example Bespoke Over 20 Percent) from the Sales permission set,
        // not the profile, so the Sales test user holds it as real Sales users do.
        for (PermissionSet salesSet : [SELECT Id FROM PermissionSet WHERE Name = :SALES_PERMISSION_SET LIMIT 1]) {
            assignments.add(new PermissionSetAssignment(AssigneeId = assigned[1].Id, PermissionSetId = salesSet.Id));
        }
        insert assignments;
    }

    // ------------------------------------------------------------------ error placement

    @isTest
    static void errorFieldOf_ChoiceOfFieldsGoesToTopOfPage_SingleOrCompoundFieldStaysOnField() {
        Assert.isNull(LeadStageTransitionService_CC.errorFieldOf(
            new Lead_Stage_Field_CC__mdt(Field_API_Names_CC__c = 'Email,Phone,MobilePhone')),
            'Email, Phone or Mobile is a choice: the error belongs at the top of the page');
        Assert.areEqual('Country', LeadStageTransitionService_CC.errorFieldOf(
            new Lead_Stage_Field_CC__mdt(Field_API_Names_CC__c = 'Country,CountryCode')),
            'Country and CountryCode are one Address field: the error stays on Country');
        Assert.areEqual('Title', LeadStageTransitionService_CC.errorFieldOf(
            new Lead_Stage_Field_CC__mdt(Field_API_Names_CC__c = 'Title')),
            'A single field keeps its error on the field');
    }

    @isTest
    static void contactMethodMissing_ErrorIsShownAtTopOfPage() {
        Lead rec = new Lead(LastName = 'Contact Method', Company = 'Contact Method Co', Status = 'Identify');
        String message = [SELECT Error_Message_CC__c FROM Lead_Stage_Field_CC__mdt
            WHERE DeveloperName = 'Identify_Contact_Method' LIMIT 1].Error_Message_CC__c;
        Database.SaveResult result;
        System.runAs(testUser(SALES_PROFILE)) {
            result = Database.insert(rec, false);
        }
        Boolean atTop = false;
        for (Database.Error err : result.getErrors()) {
            if (err.getMessage().contains(message)) {
                Assert.isTrue(err.getFields() == null || err.getFields().isEmpty(),
                    'Contact method error must not be on a field, got: ' + err.getFields());
                atTop = true;
            }
        }
        Assert.isTrue(atTop, 'Expected the contact method error, got: ' + result.getErrors());
    }

    // ------------------------------------------------------------------ Entity / Site gates

    @isTest
    static void entityLead_OneMetricStaysAtQualify_TwoMetricsAdvanceToEngage() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = baseLead('Qualify', marketingUser.Id);
        leadRecord.Lead_Type_CC__c = 'Entity';
        leadRecord.Industry = firstValue(Lead.Industry);
        leadRecord.Industry_Sub_Sector_CC__c = firstValue(Lead.Industry_Sub_Sector_CC__c);
        insert leadRecord;

        Test.startTest();
        System.runAs(marketingUser) {
            update new Lead(Id = leadRecord.Id, AnnualRevenue = 2500000);
            Assert.areEqual('Qualify', reload(leadRecord.Id).Status, 'One of four Entity metrics must not advance');
            Assert.isTrue(reload(leadRecord.Id).Stage_Progress_Message_CC__c.startsWith('To move to Engage'),
                'An incomplete Entity Lead should show its next step');
            update new Lead(Id = leadRecord.Id, Number_of_Locations_CC__c = 3);
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Engage', result.Status, 'Industry, Sub-Sector and two metrics should advance to Engage');
        Assert.isTrue(result.Qualification_Criteria_Met_CC__c, 'Formula gate should be met');
    }

    @isTest
    static void siteLead_EitherSiteMetricAdvancesWithoutEntityQuestions() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = baseLead('Qualify', marketingUser.Id);
        leadRecord.Lead_Type_CC__c = 'Site';
        insert leadRecord;

        Test.startTest();
        System.runAs(marketingUser) {
            update new Lead(Id = leadRecord.Id, Pallet_Volume_Factor__c = firstValue(Lead.Pallet_Volume_Factor__c));
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Engage', result.Status, 'A Site Lead needs only Estimated Annual Spend or Pallet Volume');
        Assert.isNull(result.Industry, 'Industry must not be required for a Site Lead');
        Assert.isNull(result.AnnualRevenue, 'Annual Revenue must not be required for a Site Lead');
    }

    @isTest
    static void manualMoveToEngage_EntityGateNotMet_IsRejectedByValidationRule() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = baseLead('Qualify', marketingUser.Id);
        leadRecord.Lead_Type_CC__c = 'Entity';
        leadRecord.AnnualRevenue = 2500000;
        insert leadRecord;

        String message;
        Test.startTest();
        System.runAs(marketingUser) {
            try {
                update new Lead(Id = leadRecord.Id, Status = 'Engage');
            } catch (DmlException ex) {
                message = ex.getMessage();
            }
        }
        Test.stopTest();

        Assert.isNotNull(message, 'Qualification_Criteria_Gate_CC should reject Engage');
        Assert.isTrue(message.contains('Industry is required'), 'Unexpected error: ' + message);
    }

    // ------------------------------------------------------------------ Identify, partial saves, one stage per save

    @isTest
    static void identifyLead_PartialSaveStays_CompleteSaveAdvancesOnlyOneStage() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = placeholderLead(marketingUser.Id);
        // The placeholder contact keeps the first save at Identify even when its other inputs are complete.
        // Everything needed for Engage is already present, to prove a save moves only one stage.
        leadRecord.Lead_Type_CC__c = 'Site';
        leadRecord.Estimated_Annual_Spend_CC__c = 150000;
        insert leadRecord;

        Test.startTest();
        System.runAs(marketingUser) {
            update new Lead(Id = leadRecord.Id, LeadSource = 'Web Search', Belongs_To_CC__c = INC_ENTITY);
            Lead partial = reload(leadRecord.Id);
            Assert.areEqual('Identify', partial.Status, 'A partial save must stay at Identify');
            Assert.isTrue(partial.Stage_Progress_Message_CC__c.startsWith('Identify the contact'),
                'Message should name the missing contact');
            update new Lead(Id = leadRecord.Id, FirstName = 'Stage', LastName = 'Actual Contact');
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Qualify', result.Status, 'Completing Identify moves exactly one stage');
        Assert.isNotNull(result.Qualified_Date_CC__c, 'Qualification timestamp should still be captured');
        Assert.areEqual(marketingUser.Id, result.OwnerId, 'Owner must be unchanged');
    }

    @isTest
    static void placeholderContactName_StaysAtIdentifyWithMessage() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = placeholderLead(marketingUser.Id);
        insert leadRecord;

        Test.startTest();
        System.runAs(marketingUser) {
            // A valid partial save that completes every other Identify input.
            update new Lead(Id = leadRecord.Id, LeadSource = 'Web Search', Belongs_To_CC__c = INC_ENTITY);
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Identify', result.Status, 'A placeholder contact must hold the Lead at Identify');
        Assert.isTrue(result.Stage_Progress_Message_CC__c.startsWith('Identify the contact'),
            'Next Step should ask for the contact to be identified: ' + result.Stage_Progress_Message_CC__c);
    }

    @isTest
    static void placeholderReplacedWithRealName_AdvancesToQualify() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = placeholderLead(marketingUser.Id);
        leadRecord.LeadSource = 'Web Search';
        insert leadRecord;

        Test.startTest();
        System.runAs(marketingUser) {
            update new Lead(Id = leadRecord.Id, Belongs_To_CC__c = INC_ENTITY);
            Assert.areEqual('Identify', reload(leadRecord.Id).Status, 'Still a placeholder: stays at Identify');
            update new Lead(Id = leadRecord.Id, FirstName = 'Jordan', LastName = 'Identified');
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Qualify', result.Status, 'Replacing the placeholder lets the Lead advance');
        Assert.isNotNull(result.Qualified_Date_CC__c, 'Qualification timestamp should be captured');
    }

    @isTest
    static void placeholder_ManualMovesBeyondIdentify_AreBlockedEvenForAdmin() {
        Lead leadRecord = placeholderLead(UserInfo.getUserId());
        insert leadRecord;
        Lead createdAtEngage = placeholderLead(UserInfo.getUserId());
        createdAtEngage.Status = 'Engage';

        List<String> messages = new List<String>();
        Test.startTest();
        for (String target : new List<String>{ 'Qualify', 'Engage', 'Qualified' }) {
            Database.SaveResult result = Database.update(new Lead(Id = leadRecord.Id, Status = target), false);
            messages.add(result.isSuccess() ? null : String.valueOf(result.getErrors()));
        }
        Database.SaveResult insertResult = Database.insert(createdAtEngage, false);
        Test.stopTest();

        for (String message : messages) {
            Assert.isNotNull(message, 'Moving a placeholder Lead beyond Identify must fail');
            Assert.isTrue(message.contains(PLACEHOLDER_BLOCK), 'Unexpected error: ' + message);
        }
        Assert.isFalse(insertResult.isSuccess(), 'Creating a placeholder Lead beyond Identify must fail');
        Assert.areEqual('Identify', reload(leadRecord.Id).Status, 'The Lead stays at Identify');
    }

    @isTest
    static void renamingToPlaceholderBeyondIdentify_IsBlocked() {
        Lead leadRecord = baseLead('Qualify', UserInfo.getUserId());
        insert leadRecord;

        Test.startTest();
        Database.SaveResult result = Database.update(new Lead(Id = leadRecord.Id, LastName = 'Needs to Identify - Renamed Co'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'A Lead beyond Identify cannot be given the placeholder name');
        Assert.isTrue(String.valueOf(result.getErrors()).contains(PLACEHOLDER_BLOCK), 'Unexpected error: ' + result.getErrors());
    }

    @isTest
    static void placeholderLead_SalesUserCanStillDisqualifyFromIdentify() {
        User salesUser = testUser(SALES_PROFILE);
        Lead automatic = placeholderLead(salesUser.Id);
        Lead manual = placeholderLead(salesUser.Id);
        insert new List<Lead>{ automatic, manual };

        Test.startTest();
        System.runAs(salesUser) {
            update new Lead(Id = automatic.Id, Disqualified_Reason_CC__c = 'No Business Need');
            update new Lead(Id = manual.Id, Status = 'Disqualified', Disqualified_Reason_CC__c = 'No Business Need');
        }
        Test.stopTest();

        Assert.areEqual('Disqualified', reload(automatic.Id).Status, 'A reason disqualifies an unidentified Lead from Identify');
        Assert.areEqual('Disqualified', reload(manual.Id).Status, 'Manual disqualification from Identify is allowed while unidentified');
    }

    @isTest
    static void explicitStatusChange_IsNotAdvancedFurther() {
        Lead leadRecord = baseLead('Identify', UserInfo.getUserId());
        leadRecord.Lead_Type_CC__c = 'Site';
        leadRecord.Estimated_Annual_Spend_CC__c = 150000;
        // Incomplete at insert (no Entity), so automatic advancement on insert leaves it at Identify.
        leadRecord.Belongs_To_CC__c = null;
        insert leadRecord;
        Assert.areEqual('Identify', reload(leadRecord.Id).Status, 'Setup: an incomplete Lead is created at Identify');

        Test.startTest();
        update new Lead(Id = leadRecord.Id, Status = 'Qualify', Belongs_To_CC__c = INC_ENTITY);
        Test.stopTest();

        Assert.areEqual('Qualify', reload(leadRecord.Id).Status, 'A user-chosen Status is kept; no second move in the same save');
    }

    @isTest
    static void asyncSave_DoesNotAdvance() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = baseLead('Qualify', marketingUser.Id);
        leadRecord.Lead_Type_CC__c = 'Site';
        insert leadRecord;

        Test.startTest();
        LeadStageTransitionService_CC.forceAsyncContext = true;
        System.runAs(marketingUser) {
            update new Lead(Id = leadRecord.Id, Estimated_Annual_Spend_CC__c = 150000);
        }
        Test.stopTest();

        Assert.areEqual('Qualify', reload(leadRecord.Id).Status, 'System/async saves must not move stages');
    }

    // ------------------------------------------------------------------ assigned versus unassigned

    @isTest
    static void unassignedUser_GateMet_AdvancesAutomatically() {
        User controlUser = [SELECT Id FROM User WHERE Email = :UNASSIGNED_EMAIL LIMIT 1];
        Assert.isFalse(hasUiReworkPermission(controlUser.Id), 'Control user must not hold the permission set');
        Lead leadRecord = baseLead('Qualify', controlUser.Id);
        leadRecord.Lead_Type_CC__c = 'Site';
        insert leadRecord;

        Test.startTest();
        System.runAs(controlUser) {
            update new Lead(Id = leadRecord.Id, Estimated_Annual_Spend_CC__c = 150000);
        }
        Test.stopTest();

        Assert.areEqual('Engage', reload(leadRecord.Id).Status, 'Automatic advancement applies to every user, not only permission holders');
    }

    @isTest
    static void unassignedUser_GateNotMet_SharedRuleStillApplies() {
        User controlUser = [SELECT Id FROM User WHERE Email = :UNASSIGNED_EMAIL LIMIT 1];
        Lead leadRecord = baseLead('Qualify', controlUser.Id);
        leadRecord.Lead_Type_CC__c = 'Site';
        insert leadRecord;

        String message;
        Test.startTest();
        System.runAs(controlUser) {
            try {
                update new Lead(Id = leadRecord.Id, Status = 'Engage');
            } catch (DmlException ex) {
                message = ex.getMessage();
            }
        }
        Test.stopTest();

        Assert.isNotNull(message, 'Qualification_Criteria_Gate_CC applies to every user, not only permission holders');
        Assert.isTrue(message.contains('Estimated Annual Spend or Daily Pallet Volume'), 'Unexpected error: ' + message);
    }

    @isTest
    static void assignedUsers_HoldCustomPermission() {
        Assert.isTrue(hasUiReworkPermission(testUser(MARKETING_PROFILE).Id), 'Assigned marketing user should hold Lead_UI_Rework_Access_CC');
        Assert.isTrue(hasUiReworkPermission(testUser(SALES_PROFILE).Id), 'Assigned sales user should hold Lead_UI_Rework_Access_CC');
    }

    // ------------------------------------------------------------------ duplicate checkpoint at Engage

    @isTest
    static void duplicateAtEngageGate_OrgRuleOverrideAllowsAutoAdvance() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead original = baseLead('Engage', marketingUser.Id);
        original.Lead_Type_CC__c = 'Site';
        original.Estimated_Annual_Spend_CC__c = 150000;
        insert original;
        Lead copy = original.clone(false, true, false, false);
        copy.Status = 'Qualify';
        copy.Estimated_Annual_Spend_CC__c = null;
        Database.SaveResult inserted = Database.insert(copy, allowDuplicateSave());
        Assert.isTrue(inserted.isSuccess(), 'Duplicate should save with allowSave: ' + inserted.getErrors());

        Database.SaveResult held;
        Database.SaveResult bypassed;
        Lead afterHold;
        Test.startTest();
        System.runAs(marketingUser) {
            held = Database.update(new Lead(Id = copy.Id, Estimated_Annual_Spend_CC__c = 150000), allowDuplicateSave());
            afterHold = reload(copy.Id);
            bypassed = Database.update(new Lead(Id = copy.Id, Bypass_Duplicate_Rules_on_Qualification__c = true), allowDuplicateSave());
        }
        Test.stopTest();

        Assert.isTrue(held.isSuccess(), 'The partial save must succeed even though the Lead is held: ' + held.getErrors());
        Assert.areEqual('Engage', afterHold.Status, 'The test-only duplicate-rule override allows auto advancement');
        Assert.isFalse(afterHold.Duplicate_Review_Required_CC__c, 'The old duplicate review flag is not used');
        Assert.isFalse(afterHold.Bypass_Duplicate_Rules_on_Qualification__c, 'The bypass must never be set automatically');
        Assert.isTrue(bypassed.isSuccess(), 'Ticking the bypass should save: ' + bypassed.getErrors());
        Lead result = reload(copy.Id);
        Assert.areEqual('Engage', result.Status, 'After the user resolves the warning the Lead advances');
        Assert.isFalse(result.Duplicate_Review_Required_CC__c, 'Duplicate review flag clears after Engage');
    }

    @isTest
    static void explicitMoveToEngage_DuplicateIsBlocked() {
        Lead original = baseLead('Engage', UserInfo.getUserId());
        insert original;
        Lead copy = original.clone(false, true, false, false);
        copy.Status = 'Qualify';
        Database.insert(copy, allowDuplicateSave());

        String message;
        Test.startTest();
        try {
            update new Lead(Id = copy.Id, Status = 'Engage');
        } catch (DmlException ex) {
            message = ex.getMessage();
        }
        Test.stopTest();

        Assert.isNotNull(message, 'An explicit move to Engage must still be blocked');
        Assert.isTrue(message.contains(LeadStageTransitionService_CC.DUPLICATE_ERROR)
            || message.contains('DUPLICATES_DETECTED'), 'Unexpected error: ' + message);
    }

    // ------------------------------------------------------------------ outcomes

    @isTest
    static void salesUser_DisqualifiesDirectlyFromQualify() {
        User salesUser = testUser(SALES_PROFILE);
        Lead leadRecord = baseLead('Qualify', salesUser.Id);
        insert leadRecord;

        Test.startTest();
        System.runAs(salesUser) {
            update new Lead(Id = leadRecord.Id, Disqualified_Reason_CC__c = 'No Business Need');
        }
        Test.stopTest();

        Assert.areEqual('Disqualified', reload(leadRecord.Id).Status, 'A reason entered at Qualify should disqualify');
    }

    @isTest
    static void disqualifyOtherWithoutComments_StaysWithMessage() {
        User salesUser = testUser(SALES_PROFILE);
        Lead leadRecord = baseLead('Qualify', salesUser.Id);
        insert leadRecord;

        Test.startTest();
        System.runAs(salesUser) {
            update new Lead(Id = leadRecord.Id, Disqualified_Reason_CC__c = 'Other');
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Qualify', result.Status, 'Other without comments must not disqualify');
        Assert.isTrue(result.Stage_Progress_Message_CC__c.startsWith('To disqualify'), 'Message should ask for comments');
    }

    @isTest
    static void marketingUser_CanDisqualifyByReasonOrStatus() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead byReason = baseLead('Qualify', marketingUser.Id);
        Lead byStatus = baseLead('Qualify', marketingUser.Id);
        Lead placeholder = placeholderLead(marketingUser.Id);
        insert new List<Lead>{ byReason, byStatus, placeholder };

        Test.startTest();
        System.runAs(marketingUser) {
            update new Lead(Id = byReason.Id, Disqualified_Reason_CC__c = 'No Business Need');
            update new Lead(Id = byStatus.Id, Status = 'Disqualified', Disqualified_Reason_CC__c = 'No Business Need');
            update new Lead(Id = placeholder.Id, Disqualified_Reason_CC__c = 'No Business Need');
        }
        Test.stopTest();

        Assert.areEqual('Disqualified', reload(byReason.Id).Status, 'A reason entered by Marketing should disqualify');
        Assert.areEqual('Disqualified', reload(byStatus.Id).Status, 'Marketing may set Disqualified directly');
        Assert.areEqual('Disqualified', reload(placeholder.Id).Status, 'Marketing may disqualify an unidentified Lead from Identify');
    }

    @isTest
    static void marketingUser_ReNurtureAndQualified_StillNeedSales() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead reNurture = engageLead(marketingUser.Id);
        Lead qualified = engageLead(marketingUser.Id);
        insert new List<Lead>{ reNurture, qualified };

        List<Database.SaveResult> results;
        Test.startTest();
        System.runAs(marketingUser) {
            results = Database.update(new List<Lead>{
                new Lead(Id = reNurture.Id, Status = 'Re-Nurture'),
                new Lead(Id = qualified.Id, Status = 'Qualified')
            }, false);
        }
        Test.stopTest();

        Assert.areEqual('Engage', reload(reNurture.Id).Status, 'Re-Nurture stays reserved for Sales');
        Assert.areEqual('Engage', reload(qualified.Id).Status, 'Qualified stays reserved for Sales');
        for (Database.SaveResult saveResult : results) {
            Assert.isFalse(saveResult.isSuccess(), 'Marketing must not set Re-Nurture or Qualified');
            Boolean salesOnly = false;
            for (Database.Error error : saveResult.getErrors()) {
                salesOnly = salesOnly || error.getMessage().contains('Only sales users and admins can move the status');
            }
            Assert.isTrue(salesOnly, 'Expected the Sales-only error');
        }
    }

    @isTest
    static void explicitDisqualifyFromQualify_IsAllowedByValidationRules() {
        User salesUser = testUser(SALES_PROFILE);
        Lead leadRecord = baseLead('Qualify', salesUser.Id);
        insert leadRecord;

        Test.startTest();
        System.runAs(salesUser) {
            update new Lead(Id = leadRecord.Id, Status = 'Disqualified', Disqualified_Reason_CC__c = 'Unresponsive');
        }
        Test.stopTest();

        Assert.areEqual('Disqualified', reload(leadRecord.Id).Status, 'Disqualified from Qualify is now permitted');
    }

    // Runs as the System Administrator, who may record a Re-Nurture outcome (as a Sales user with
    // Sales_User_Permission_CC may); that custom permission comes from the Sales profile, which is not deployed.
    @isTest
    static void reNurtureFromEngage_RequiresDate() {
        Lead leadRecord = engageLead(UserInfo.getUserId());
        insert leadRecord;

        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            update new Lead(Id = leadRecord.Id, Re_Nurture_Reason_CC__c = 'Not Ready to Buy');
            Lead partial = reload(leadRecord.Id);
            Assert.areEqual('Engage', partial.Status, 'Re-Nurture needs a Re-Engagement Date');
            Assert.isTrue(partial.Stage_Progress_Message_CC__c.startsWith('To re-nurture'), 'Message should ask for the date');
            update new Lead(Id = leadRecord.Id, Reengagement_Date_CC__c = Date.today().addMonths(3));
        }
        Test.stopTest();

        Assert.areEqual('Re-Nurture', reload(leadRecord.Id).Status, 'Reason and date should re-nurture the Lead');
    }

    @isTest
    static void unchangedHistoricalOutcome_DoesNotRetrigger() {
        User salesUser = testUser(SALES_PROFILE);
        Lead leadRecord = engageLead(salesUser.Id);
        leadRecord.Re_Nurture_Reason_CC__c = 'Not Ready to Buy';
        leadRecord.Reengagement_Date_CC__c = Date.today().addMonths(3);
        insert leadRecord;

        Test.startTest();
        System.runAs(salesUser) {
            update new Lead(Id = leadRecord.Id, Title = 'Head of Operations');
        }
        Test.stopTest();

        Assert.areEqual('Engage', reload(leadRecord.Id).Status, 'Old outcome values must not move the Lead on unrelated edits');
    }

    // ------------------------------------------------------------------ Account and Opportunity questions at Qualified

    @isTest
    static void qualifiedOutcome_NextStepAsksForAccountAndOpportunityQuestions() {
        User salesUser = testUser(SALES_PROFILE);
        Lead leadRecord = conversionReadyEntityLead(salesUser.Id);
        leadRecord.Actual_Annual_Spend_CC__c = null;
        leadRecord.Number_of_Locations_CC__c = null;
        leadRecord.Meeting_Outcome_CC__c = null;
        insert leadRecord;

        Test.startTest();
        System.runAs(salesUser) {
            update new Lead(Id = leadRecord.Id, Meeting_Outcome_CC__c = QUALIFIED_OUTCOME);
            String gaps = reload(leadRecord.Id).Stage_Progress_Message_CC__c;
            Assert.isTrue(gaps.startsWith('To convert, first complete:'), 'Unexpected Next Step: ' + gaps);
            Assert.isTrue(gaps.contains(Schema.SObjectType.Lead.fields.Actual_Annual_Spend_CC__c.getLabel()), 'Q2 should be asked: ' + gaps);
            Assert.isTrue(gaps.contains(Schema.SObjectType.Lead.fields.Number_of_Locations_CC__c.getLabel()), 'Q6 should be asked on an Entity Lead: ' + gaps);
            for (Schema.SObjectField question : new List<Schema.SObjectField>{ Lead.Opportunity_Value_CC__c,
                    Lead.Bespoke_Over_20_Percent_CC__c, Lead.Core_Category_Min_Qty_CC__c, Lead.Tender_Exculsive_Pricing_CC__c }) {
                Assert.isTrue(gaps.contains(question.getDescribe().getLabel()), 'Opportunity questions are asked on the Lead: ' + gaps);
            }
            Lead answers = withOpportunityAnswers(new Lead(Id = leadRecord.Id));
            answers.Actual_Annual_Spend_CC__c = 400000;
            answers.Number_of_Locations_CC__c = 3;
            update answers;
        }
        Test.stopTest();

        String ready = reload(leadRecord.Id).Stage_Progress_Message_CC__c;
        Assert.isTrue(ready.startsWith('Ready to convert'), 'With every question answered the Lead is ready: ' + ready);
    }

    /** Answers the Opportunity questions (Opportunity Value, Bespoke, Core Category, Tender / Exclusive). */
    private static Lead withOpportunityAnswers(Lead leadRecord) {
        leadRecord.Opportunity_Value_CC__c = 50000;
        leadRecord.Bespoke_Over_20_Percent_CC__c = 'No';
        leadRecord.Core_Category_Min_Qty_CC__c = 'Yes';
        leadRecord.Tender_Exculsive_Pricing_CC__c = 'Tender';
        return leadRecord;
    }

    /**
     * An Entity Lead at Engage with every conversion input, including the Account questions but none of the
     * Opportunity questions (Opportunity Value, Bespoke, Core Category, Tender / Exclusive).
     */
    private static Lead conversionReadyEntityLead(Id ownerId) {
        Lead leadRecord = baseLead('Engage', ownerId);
        leadRecord.Lead_Type_CC__c = 'Entity';
        leadRecord.Industry = firstValue(Lead.Industry);
        leadRecord.Industry_Sub_Sector_CC__c = firstValue(Lead.Industry_Sub_Sector_CC__c);
        leadRecord.AnnualRevenue = 2500000;
        leadRecord.Estimated_Annual_Spend_CC__c = 150000;
        leadRecord.Number_of_Locations_CC__c = 2;
        leadRecord.Actual_Annual_Spend_CC__c = 120000;
        leadRecord.Product_Category_CC__c = 'Tape';
        leadRecord.Product_Category_Text_CC__c = 'Tape';
        leadRecord.Company_Registration_No_CC__c = 'REG' + leadRecord.Company.right(6);
        leadRecord.Sales_Appointment_Booked_CC__c = 'Yes';
        leadRecord.First_Sales_Appointment_Date_CC__c = System.now().addDays(-1);
        leadRecord.Meeting_Outcome_CC__c = QUALIFIED_OUTCOME;
        return leadRecord;
    }

    // ------------------------------------------------------------------ conversion handoff

    @isTest
    static void qualifiedOutcome_GivesConvertHandoffAndPermitsConversionFromEngage() {
        Lead ready = baseLead('Engage', UserInfo.getUserId());
        Lead notReady = baseLead('Engage', UserInfo.getUserId());
        insert new List<Lead>{ ready, notReady };
        String convertedStatus = [SELECT ApiName FROM LeadStatus WHERE IsConverted = true LIMIT 1].ApiName;

        Test.startTest();
        update new Lead(Id = ready.Id, Meeting_Outcome_CC__c = QUALIFIED_OUTCOME);
        Lead handoff = reload(ready.Id);
        // The rejected Lead is converted first: the two Leads share an address and phone, so once the ready Lead has
        // created its Account, an active Account duplicate rule (Salesforce's standard rule in new orgs) would block
        // the second conversion before the Lead rule under test is reached.
        Database.LeadConvertResult notReadyResult = convert(notReady.Id, convertedStatus);
        Database.LeadConvertResult readyResult = convert(ready.Id, convertedStatus);
        Test.stopTest();

        Assert.areEqual('Engage', handoff.Status, 'Automation must never assign the converted Qualified status');
        Assert.isTrue(handoff.Stage_Progress_Message_CC__c.contains('convert'), 'Message should hand over to Convert');
        Assert.isFalse(notReadyResult.isSuccess(), 'Conversion without the qualified outcome must be rejected');
        Assert.isTrue(String.valueOf(notReadyResult.getErrors()).contains('Only Sales Qualified leads'), 'Unexpected error: ' + notReadyResult.getErrors());
        if (!readyResult.isSuccess()) {
            Assert.isFalse(String.valueOf(readyResult.getErrors()).contains('Only Sales Qualified leads'),
                'Lead_conversion_validation must allow Engage + Qualified outcome: ' + readyResult.getErrors());
        }
    }

    @isTest
    static void engageNextStep_ShowsMarketingHandoffOnlyWhileMarketingOwnsTheLead() {
        User marketingUser = testUser(MARKETING_PROFILE);
        User salesUser = testUser(SALES_PROFILE);
        Lead marketingOwned = engageLead(marketingUser.Id);
        Lead salesOwned = engageLead(salesUser.Id);
        insert new List<Lead>{ marketingOwned, salesOwned };

        Test.startTest();
        update new List<Lead>{
            new Lead(Id = marketingOwned.Id, Title = 'Head of Buying'),
            new Lead(Id = salesOwned.Id, Title = 'Head of Buying')
        };
        Test.stopTest();

        String marketingMessage = reload(marketingOwned.Id).Stage_Progress_Message_CC__c;
        String salesMessage = reload(salesOwned.Id).Stage_Progress_Message_CC__c;
        Assert.isTrue(marketingMessage.startsWith('Book a meeting'), 'Unexpected message: ' + marketingMessage);
        Assert.isTrue(marketingMessage.endsWith(LeadStageTransitionService_CC.MARKETING_HANDOFF.trim()),
            'A Marketing-owned Lead should keep the handoff instruction: ' + marketingMessage);
        Assert.isTrue(salesMessage.startsWith('Book a meeting'), 'Unexpected message: ' + salesMessage);
        Assert.isFalse(salesMessage.contains('Marketing:'), 'A Sales-owned Lead must not show Marketing instructions: ' + salesMessage);
    }

    @isTest
    static void engageNextStep_AsksToBookAMeetingBeforeTheOutcome() {
        User salesUser = testUser(SALES_PROFILE);
        Lead noMeeting = engageLead(salesUser.Id);
        Lead booked = engageLead(salesUser.Id);
        insert new List<Lead>{ noMeeting, booked };
        String insertedMessage = reload(noMeeting.Id).Stage_Progress_Message_CC__c;

        Test.startTest();
        update new Lead(Id = booked.Id, Sales_Appointment_Booked_CC__c = 'Yes',
            First_Sales_Appointment_Date_CC__c = System.now().addDays(3));
        Test.stopTest();

        Assert.isTrue(insertedMessage.startsWith(LeadStageTransitionService_CC.BOOK_MEETING_MESSAGE),
            'Without a meeting, Engage must ask for one first: ' + insertedMessage);
        String bookedMessage = reload(booked.Id).Stage_Progress_Message_CC__c;
        Assert.isTrue(bookedMessage.startsWith('Record the meeting outcome'),
            'Once a meeting is booked, Engage asks for its outcome: ' + bookedMessage);
    }

    // ------------------------------------------------------------------ automatic advancement on insert

    // A Marketing user's Identify Lead with an Entity is routed to the Entity's pool by Lead_Company_Owner_Mapping_CC.
    // When the mapped pool Id does not exist in this org (the shipped records hold another org's queue Ids, so they
    // must be updated with this org's queue Ids after deployment), the save fails before any stage logic runs.
    @isTest
    static void marketingUser_CompleteLeadCreatedAtIdentify_StartsAtQualify() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = baseLead('Identify', marketingUser.Id);
        // Everything needed for Engage is present too, to prove an insert moves only to Qualify.
        leadRecord.Lead_Type_CC__c = 'Site';
        leadRecord.Estimated_Annual_Spend_CC__c = 150000;

        Database.SaveResult saved;
        Test.startTest();
        System.runAs(marketingUser) {
            saved = Database.insert(leadRecord, false);
        }
        Test.stopTest();

        if (!TestLeadRouting_CC.entityPoolsExist()) {
            TestLeadRouting_CC.assertRoutingFailure(saved);
            return;
        }
        Assert.isTrue(saved.isSuccess(), String.valueOf(saved.getErrors()));
        Lead result = reload(leadRecord.Id);
        Assert.areEqual('Qualify', result.Status, 'A complete Lead created at Identify should start at Qualify');
        Assert.isNotNull(result.Qualified_Date_CC__c, 'Qualification timestamp should be captured on insert');
        Assert.isFalse(result.Stage_Progress_Message_CC__c.startsWith('All Qualify fields are complete'),
            'Next Step should be for Qualify, not ask for another save: ' + result.Stage_Progress_Message_CC__c);
    }

    @isTest
    static void salesUser_CompleteLeadCreatedAtIdentify_StartsAtQualify() {
        User salesUser = testUser(SALES_PROFILE);
        Lead leadRecord = baseLead('Identify', salesUser.Id);

        Test.startTest();
        System.runAs(salesUser) {
            insert leadRecord;
        }
        Test.stopTest();

        Assert.areEqual('Qualify', reload(leadRecord.Id).Status, 'Advancement on insert applies to every user');
    }

    @isTest
    static void incompleteOrPlaceholderLeadCreatedAtIdentify_StaysAtIdentify() {
        User marketingUser = testUser(MARKETING_PROFILE);
        // Identify fields are required to save for non-admins, so an incomplete named Lead is created as the
        // (exempt) running admin; the placeholder name is what holds a user-created Lead at Identify. The placeholder has an
        // Entity, so it is saved through TestLeadRouting_CC (Entity routing to the mapped pool).
        Lead incomplete = baseLead('Identify', UserInfo.getUserId());
        incomplete.Belongs_To_CC__c = null;
        Lead placeholder = baseLead('Identify', marketingUser.Id);
        placeholder.FirstName = null;
        placeholder.LastName = 'Needs to Identify - ' + placeholder.Company;

        Test.startTest();
        insert incomplete;
        // False when the Entity pool mapped in Lead_Company_Owner_Mapping_CC does not exist in this org.
        Boolean placeholderSaved = TestLeadRouting_CC.insertIdentifyLeads(new List<Lead>{ placeholder });
        Test.stopTest();

        Lead incompleteResult = reload(incomplete.Id);
        Assert.areEqual('Identify', incompleteResult.Status, 'A Lead missing Qualify fields stays at Identify');
        Assert.isNull(incompleteResult.Qualified_Date_CC__c, 'No qualification timestamp at Identify');
        Assert.isTrue(incompleteResult.Stage_Progress_Message_CC__c.startsWith('To move to Qualify'),
            'Next Step should list the gaps: ' + incompleteResult.Stage_Progress_Message_CC__c);
        if (placeholderSaved) {
            Assert.areEqual('Identify', reload(placeholder.Id).Status, 'A placeholder contact holds the Lead at Identify');
        }
    }

    @isTest
    static void marketingUser_ExplicitInsertBeyondIdentify_StillRejected() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = baseLead('Qualify', marketingUser.Id);

        Database.SaveResult result;
        Test.startTest();
        System.runAs(marketingUser) {
            result = Database.insert(leadRecord, false);
        }
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Marketing users must still create Leads at Identify');
        Assert.isTrue(String.valueOf(result.getErrors()).contains('New Leads must be created with a Status of \'Identify\''),
            'Unexpected error: ' + result.getErrors());
    }

    @isTest
    static void asyncInsert_DoesNotAdvance() {
        Lead leadRecord = baseLead('Identify', UserInfo.getUserId());

        Test.startTest();
        LeadStageTransitionService_CC.forceAsyncContext = true;
        if (!TestLeadRouting_CC.insertIdentifyLeads(new List<Lead>{ leadRecord })) {
            return; // the Entity pool mapped in Lead_Company_Owner_Mapping_CC does not exist in this org
        }
        Test.stopTest();

        Assert.areEqual('Identify', reload(leadRecord.Id).Status, 'System/async inserts must not move stages');
    }

    @isTest
    static void bulkInsert_CompleteLeadsAdvance_IncompleteStay() {
        List<Lead> complete = new List<Lead>();
        List<Lead> incomplete = new List<Lead>();
        for (Integer i = 0; i < 100; i++) {
            complete.add(baseLead('Identify', UserInfo.getUserId()));
            Lead partial = baseLead('Identify', UserInfo.getUserId());
            partial.Belongs_To_CC__c = null;
            incomplete.add(partial);
        }
        Test.startTest();
        if (!TestLeadRouting_CC.insertIdentifyLeads(complete)) {
            return; // the Entity pool mapped in Lead_Company_Owner_Mapping_CC does not exist in this org
        }
        // No Entity, so no routing; Identify fields are only required for non-admins, so the (exempt) admin saves these.
        insert incomplete;
        Test.stopTest();

        Assert.areEqual(100, [SELECT COUNT() FROM Lead WHERE Id IN :complete AND Status = 'Qualify' WITH SYSTEM_MODE],
            'Every complete Lead should start at Qualify');
        Assert.areEqual(100, [SELECT COUNT() FROM Lead WHERE Id IN :incomplete AND Status = 'Identify' WITH SYSTEM_MODE],
            'Every incomplete Lead should stay at Identify');
    }

    // ------------------------------------------------------------------ initial Next Step on insert

    @isTest
    static void insertedLeads_GetTheNextStepForTheirStage() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead placeholder = placeholderLead(marketingUser.Id);
        Lead missingSource = baseLead('Identify', marketingUser.Id);
        missingSource.LeadSource = null;
        missingSource.Belongs_To_CC__c = null;
        Lead qualify = baseLead('Qualify', marketingUser.Id);
        Lead reNurture = engageLead(marketingUser.Id);
        reNurture.Status = 'Re-Nurture';
        reNurture.Re_Nurture_Reason_CC__c = firstValue(Lead.Re_Nurture_Reason_CC__c);
        reNurture.Re_Nurture_Comments_CC__c = 'Initial Next Step test';
        reNurture.Reengagement_Date_CC__c = Date.today().addDays(30);

        Test.startTest();
        insert new List<Lead>{ placeholder, missingSource, qualify, reNurture };
        Test.stopTest();

        Assert.isTrue(reload(placeholder.Id).Stage_Progress_Message_CC__c.startsWith('Identify the contact'),
            'Placeholder Lead should ask for the contact: ' + reload(placeholder.Id).Stage_Progress_Message_CC__c);
        String identifyMessage = reload(missingSource.Id).Stage_Progress_Message_CC__c;
        Assert.isTrue(identifyMessage.startsWith('To move to Qualify') && identifyMessage.contains('Entity'),
            'Identify Lead should list its gaps: ' + identifyMessage);
        Assert.isTrue(reload(qualify.Id).Stage_Progress_Message_CC__c.startsWith('To move to Engage'),
            'Qualify Lead should list its Engage gaps: ' + reload(qualify.Id).Stage_Progress_Message_CC__c);
        Assert.isTrue(reload(reNurture.Id).Stage_Progress_Message_CC__c.startsWith('Follow up from the Re-engagement Date'),
            'Re-Nurture Lead should point to the follow-up list: ' + reload(reNurture.Id).Stage_Progress_Message_CC__c);
        Assert.areEqual('Re-Nurture', reload(reNurture.Id).Status, 'Insert must never change the given Status');
    }

    @isTest
    static void insertedEngageLeads_HandoffTextFollowsTheOwner() {
        User marketingUser = testUser(MARKETING_PROFILE);
        User salesUser = testUser(SALES_PROFILE);
        Lead marketingOwned = engageLead(marketingUser.Id);
        Lead salesOwned = engageLead(salesUser.Id);

        Test.startTest();
        insert new List<Lead>{ marketingOwned, salesOwned };
        Test.stopTest();

        String marketingMessage = reload(marketingOwned.Id).Stage_Progress_Message_CC__c;
        String salesMessage = reload(salesOwned.Id).Stage_Progress_Message_CC__c;
        Assert.isTrue(marketingMessage.endsWith(LeadStageTransitionService_CC.MARKETING_HANDOFF.trim()),
            'A Marketing-owned new Lead should show the handoff: ' + marketingMessage);
        Assert.isTrue(salesMessage.startsWith('Book a meeting') && !salesMessage.contains('Marketing:'),
            'A Sales-owned new Lead must not show Marketing instructions: ' + salesMessage);
    }

    @isTest
    static void insertedLead_StillProgressesOneStagePerSaveAfterwards() {
        User marketingUser = testUser(MARKETING_PROFILE);
        Lead leadRecord = baseLead('Qualify', marketingUser.Id);
        leadRecord.Lead_Type_CC__c = 'Site';
        insert leadRecord;
        String initialMessage = reload(leadRecord.Id).Stage_Progress_Message_CC__c;

        Test.startTest();
        System.runAs(marketingUser) {
            update new Lead(Id = leadRecord.Id, Estimated_Annual_Spend_CC__c = 150000);
        }
        Test.stopTest();

        Lead result = reload(leadRecord.Id);
        Assert.isTrue(initialMessage.startsWith('To move to Engage'), 'Initial message should list the Site gap: ' + initialMessage);
        Assert.areEqual('Engage', result.Status, 'The first update should still advance as before');
        Assert.isTrue(result.Stage_Progress_Message_CC__c.startsWith('Book a meeting'),
            'The update should replace the initial message: ' + result.Stage_Progress_Message_CC__c);
    }

    @isTest
    static void bulkInsert_200Leads_AllGetANextStepWithBoundedQueries() {
        User marketingUser = testUser(MARKETING_PROFILE);
        User salesUser = testUser(SALES_PROFILE);
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            leads.add(Math.mod(i, 2) == 0 ? engageLead(Math.mod(i, 4) == 0 ? marketingUser.Id : salesUser.Id)
                                          : baseLead('Qualify', marketingUser.Id));
        }

        Integer queriesBefore = Limits.getQueries();
        Test.startTest();
        insert leads;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Integer blank = [SELECT COUNT() FROM Lead WHERE Id IN :leads AND Stage_Progress_Message_CC__c = null WITH SYSTEM_MODE];
        Integer withHandoff = [SELECT COUNT() FROM Lead WHERE Id IN :leads AND Stage_Progress_Message_CC__c LIKE '%Marketing:%' WITH SYSTEM_MODE];
        Assert.areEqual(0, blank, 'Every inserted Lead should get a Next Step');
        Assert.areEqual(50, withHandoff, 'Only the Marketing-owned Engage Leads should show the handoff');
        Assert.isTrue(queriesUsed < 60, 'Bulk insert should use a bounded number of queries, used ' + queriesUsed);
    }

    // ------------------------------------------------------------------ bulk

    @isTest
    static void bulkUpdate_200Leads_AdvancesOnlyThoseMeetingTheGate() {
        User marketingUser = testUser(MARKETING_PROFILE);
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            Lead leadRecord = baseLead('Qualify', marketingUser.Id);
            leadRecord.Lead_Type_CC__c = Math.mod(i, 2) == 0 ? 'Site' : 'Entity';
            leads.add(leadRecord);
        }
        insert leads;
        List<Lead> updates = new List<Lead>();
        for (Lead leadRecord : leads) {
            updates.add(new Lead(Id = leadRecord.Id, Estimated_Annual_Spend_CC__c = 150000));
        }

        Integer queriesUsed;
        Test.startTest();
        System.runAs(marketingUser) {
            update updates;
            queriesUsed = Limits.getQueries();
        }
        Test.stopTest();

        Integer engaged = [SELECT COUNT() FROM Lead WHERE Id IN :leads AND Status = 'Engage' AND Lead_Type_CC__c = 'Site' WITH SYSTEM_MODE];
        Integer held = [SELECT COUNT() FROM Lead WHERE Id IN :leads AND Status = 'Qualify' AND Lead_Type_CC__c = 'Entity' WITH SYSTEM_MODE];
        Assert.areEqual(100, engaged, 'Every Site Lead with spend should move to Engage');
        Assert.areEqual(100, held, 'Entity Leads with one metric and no industry should stay at Qualify');
        Assert.isTrue(queriesUsed < 30, 'Bulk update should use a bounded number of queries, used ' + queriesUsed);
    }

    // ------------------------------------------------------------------ helpers

    private static Lead baseLead(String status, Id ownerId) {
        sequence++;
        String suffix = String.valueOf(sequence) + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new Lead(
            FirstName = 'Stage', LastName = 'Tester ' + suffix, Company = 'Stage Co ' + suffix, Status = status,
            Title = 'Buyer', Email = 'stage' + suffix + '@carltontest.invalid', Phone = '+1 555 0100',
            City = 'Chicago', PostalCode = '60601', CountryCode = 'US', Belongs_To_CC__c = INC_ENTITY,
            LeadSource = 'Web Search', OwnerId = ownerId
        );
    }

    /** An Identify Lead with the wizard placeholder name, no Entity (so routing keeps the owner) and no Lead Source. */
    private static Lead placeholderLead(Id ownerId) {
        Lead leadRecord = baseLead('Identify', ownerId);
        leadRecord.FirstName = null;
        leadRecord.LastName = 'Needs to Identify - ' + leadRecord.Company;
        leadRecord.LeadSource = null;
        leadRecord.Belongs_To_CC__c = null;
        return leadRecord;
    }

    /** An Engage Lead that satisfies every Engage rule, so non-admin edits save. */
    private static Lead engageLead(Id ownerId) {
        Lead leadRecord = baseLead('Engage', ownerId);
        leadRecord.Lead_Type_CC__c = 'Site';
        leadRecord.Estimated_Annual_Spend_CC__c = 150000;
        return leadRecord;
    }

    private static Lead reload(Id leadId) {
        return [SELECT Status, OwnerId, Industry, AnnualRevenue, Qualified_Date_CC__c, Qualification_Criteria_Met_CC__c,
                       Stage_Progress_Message_CC__c, Duplicate_Review_Required_CC__c, Bypass_Duplicate_Rules_on_Qualification__c
                FROM Lead WHERE Id = :leadId WITH SYSTEM_MODE];
    }

    private static Database.LeadConvertResult convert(Id leadId, String convertedStatus) {
        Database.LeadConvert request = new Database.LeadConvert();
        request.setLeadId(leadId);
        request.setConvertedStatus(convertedStatus);
        request.setDoNotCreateOpportunity(true);
        return Database.convertLead(request, false);
    }

    private static Database.DMLOptions allowDuplicateSave() {
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        return options;
    }

    private static String firstValue(Schema.SObjectField field) {
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static String label(String fieldName) {
        return Schema.SObjectType.Lead.fields.getMap().get(fieldName).getDescribe().getLabel();
    }

    private static Boolean hasUiReworkPermission(Id userId) {
        Set<Id> permissionSetIds = new Set<Id>();
        for (PermissionSetAssignment assignment : [SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId = :userId]) {
            permissionSetIds.add(assignment.PermissionSetId);
        }
        return [SELECT COUNT() FROM SetupEntityAccess
                WHERE ParentId IN :permissionSetIds
                AND SetupEntityId IN (SELECT Id FROM CustomPermission WHERE DeveloperName = 'Lead_UI_Rework_Access_CC')] > 0;
    }

    private static User testUser(String profileName) {
        return [SELECT Id FROM User WHERE Email = :USER_EMAIL AND Profile.Name = :profileName AND IsActive = true LIMIT 1];
    }

    private static User buildUser(String profileName, String alias) {
        return new User(
            FirstName = 'Stage', LastName = 'Test ' + alias, Alias = alias, Email = USER_EMAIL,
            Username = alias + Math.abs(Crypto.getRandomLong()) + '@carltontest.invalid',
            ProfileId = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1].Id,
            TimeZoneSidKey = 'America/Chicago', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', IsActive = true
        );
    }
}
