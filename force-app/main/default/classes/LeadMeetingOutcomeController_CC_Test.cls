/**
 * Tests for LeadMeetingOutcomeController_CC. Expected requirements are derived from the Lead stage metadata through
 * LeadStageTransitionService_CC, so the tests keep passing when an administrator adds or removes a required field.
 */
@isTest
private class LeadMeetingOutcomeController_CC_Test {

    /**
     * The controller reads the Lead in user mode and offers only fields the user can read. The tests run as the System
     * Administrator running them, with the Carlton permission sets and Lead field access (TestAdminAccess_CC); each test
     * runs inside System.runAs so the access applies to the controller and to the expectations alike.
     */
    @TestSetup
    static void grantAccess() {
        TestAdminAccess_CC.grant(new List<SObjectType>{ Lead.SObjectType });
    }

    private static Lead engageLead(String company) {
        // Inserted by the running (System Administrator) user, who is exempt from the stage-gate validation.
        Lead leadRecord = new Lead(LastName = 'Outcome', FirstName = 'Test', Company = company, Status = 'Engage');
        insert leadRecord;
        return leadRecord;
    }

    private static Boolean isReadable(String fieldName) {
        Schema.SObjectField field = Schema.SObjectType.Lead.fields.getMap().get(fieldName);
        return field != null && field.getDescribe().isAccessible();
    }

    private static Map<String, LeadMeetingOutcomeController_CC.Requirement> byKey(LeadMeetingOutcomeController_CC.OutcomeForm form) {
        Map<String, LeadMeetingOutcomeController_CC.Requirement> result = new Map<String, LeadMeetingOutcomeController_CC.Requirement>();
        for (LeadMeetingOutcomeController_CC.Requirement requirement : form.requirements) {
            result.put(requirement.key, requirement);
        }
        return result;
    }

    /** True when the popup has nothing to ask for this rule: only card fields, or no field the user can read. */
    private static Boolean nothingToAsk(Lead_Stage_Field_CC__mdt rule) {
        for (String fieldName : LeadStageTransitionService_CC.fieldNamesOf(rule)) {
            if (!LeadMeetingOutcomeController_CC.CARD_FIELDS.contains(fieldName) && isReadable(fieldName)) {
                return false;
            }
        }
        return true;
    }

    @isTest
    static void qualified_ReturnsOnlyItsOwnRules() {
        System.runAs(TestAdminAccess_CC.admin()) {
            Lead leadRecord = engageLead('Outcome Qualified Co');
            String qualified = LeadStageTransitionService_CC.statusOf('Qualified');

            Test.startTest();
            LeadMeetingOutcomeController_CC.OutcomeForm form =
                LeadMeetingOutcomeController_CC.getOutcomeForm(leadRecord.Id, 'Qualified');
            Test.stopTest();

            Assert.areEqual(qualified, form.targetStatus, 'Target status comes from the stage metadata');
            Map<String, LeadMeetingOutcomeController_CC.Requirement> returned = byKey(form);
            for (Lead_Stage_Field_CC__mdt rule : LeadStageTransitionService_CC.requiredFieldsFor(qualified)) {
                Boolean ownStage = LeadStageTransitionService_CC.statusOf(rule.Lead_Stage_CC__r.DeveloperName) == qualified;
                // Earlier-stage rules are never asked in the popup; the Lead trigger enforces them on save.
                Boolean expected = ownStage && !nothingToAsk(rule);
                Assert.areEqual(expected, returned.containsKey(rule.DeveloperName),
                    rule.DeveloperName + (expected ? ' should' : ' should not') + ' be in the popup');
                if (expected) {
                    Assert.isTrue(returned.get(rule.DeveloperName).ownStage, rule.DeveloperName + ' ownStage');
                }
            }
            for (LeadMeetingOutcomeController_CC.Requirement requirement : form.requirements) {
                Assert.isFalse(requirement.fieldNames.contains('Meeting_Outcome_CC__c'), 'The card sets Meeting Outcome itself');
                Assert.isFalse(requirement.fieldNames.isEmpty(), requirement.key + ' has no fields to ask for');
                Assert.isTrue(requirement.minimumRequired >= 1, requirement.key + ' minimum');
            }
        }
    }

    @isTest
    static void qualified_UnmetEarlierRule_IsNotAsked() {
        System.runAs(TestAdminAccess_CC.admin()) {
            Lead leadRecord = engageLead('Outcome Earlier Co');
            String qualified = LeadStageTransitionService_CC.statusOf('Qualified');

            Test.startTest();
            Map<String, LeadMeetingOutcomeController_CC.Requirement> returned =
                byKey(LeadMeetingOutcomeController_CC.getOutcomeForm(leadRecord.Id, 'Qualified'));
            Test.stopTest();

            for (Lead_Stage_Field_CC__mdt rule : LeadStageTransitionService_CC.requiredFieldsFor(qualified)) {
                Boolean ownStage = LeadStageTransitionService_CC.statusOf(rule.Lead_Stage_CC__r.DeveloperName) == qualified;
                if (!ownStage) {
                    Assert.isFalse(returned.containsKey(rule.DeveloperName),
                        rule.DeveloperName + ' is an earlier-stage rule and must not be asked, met or not');
                }
            }
        }
    }

    @isTest
    static void disqualified_ReturnsOnlyItsOwnRules_WithConditions() {
        System.runAs(TestAdminAccess_CC.admin()) {
            Lead leadRecord = engageLead('Outcome Disqualified Co');
            String disqualified = LeadStageTransitionService_CC.statusOf('Disqualified');

            Test.startTest();
            LeadMeetingOutcomeController_CC.OutcomeForm form =
                LeadMeetingOutcomeController_CC.getOutcomeForm(leadRecord.Id, 'Disqualified');
            Test.stopTest();

            Assert.areEqual(disqualified, form.targetStatus);
            Assert.areEqual(LeadStageTransitionService_CC.requiredFieldsFor(disqualified).size(), form.requirements.size(),
                'An Exit stage asks for its own requirements only');
            for (LeadMeetingOutcomeController_CC.Requirement requirement : form.requirements) {
                Assert.isTrue(requirement.ownStage, requirement.key);
                if (requirement.conditionField != null) {
                    Assert.isTrue(form.values.containsKey(requirement.conditionField),
                        'The condition field value is returned so the popup can apply the condition: ' + requirement.key);
                }
            }
        }
    }

    @isTest
    static void reNurture_ReturnsCurrentValues() {
        System.runAs(TestAdminAccess_CC.admin()) {
            Lead leadRecord = engageLead('Outcome Re-Nurture Co');
            Date reengagement = Date.today().addMonths(2);
            update new Lead(Id = leadRecord.Id, Reengagement_Date_CC__c = reengagement);

            Test.startTest();
            LeadMeetingOutcomeController_CC.OutcomeForm form =
                LeadMeetingOutcomeController_CC.getOutcomeForm(leadRecord.Id, 'Re_Nurture');
            Test.stopTest();

            Assert.areEqual(LeadStageTransitionService_CC.statusOf('Re_Nurture'), form.targetStatus);
            if (form.values.containsKey('Reengagement_Date_CC__c')) {
                Assert.areEqual(reengagement, form.values.get('Reengagement_Date_CC__c'), 'Current values pre-fill the popup');
            }
        }
    }

    @isTest
    static void qualified_FormCarriesTheDuplicateMessage() {
        System.runAs(TestAdminAccess_CC.admin()) {
            Lead leadRecord = engageLead('Outcome Duplicate Message Co');
            LeadMeetingOutcomeController_CC.OutcomeForm form =
                LeadMeetingOutcomeController_CC.getOutcomeForm(leadRecord.Id, 'Qualified');
            Assert.areEqual(LeadStageTransitionService_CC.DUPLICATE_ERROR, form.duplicateError,
                'The popup recognises a duplicate block by the trigger message');
        }
    }

    @isTest
    static void duplicateCheck_ListsOtherRecordsOnly() {
        System.runAs(TestAdminAccess_CC.admin()) {
            // Two identical Leads; saved past any blocking duplicate rule so the check has something to find.
            Database.DMLOptions options = new Database.DMLOptions();
            options.DuplicateRuleHeader.allowSave = true;
            List<Lead> twins = new List<Lead>{
                new Lead(LastName = 'Twin', FirstName = 'Dup', Company = 'Outcome Twin Co', Email = 'dup.twin@example.com',
                    Status = 'Engage'),
                new Lead(LastName = 'Twin', FirstName = 'Dup', Company = 'Outcome Twin Co', Email = 'dup.twin@example.com',
                    Status = 'Engage')
            };
            Database.insert(twins, options);

            Test.startTest();
            LeadMeetingOutcomeController_CC.DuplicateCheck check = LeadMeetingOutcomeController_CC.getDuplicateCheck(twins[0].Id);
            Test.stopTest();

            Assert.areEqual(Schema.SObjectType.Lead.fields.Bypass_Duplicate_Rules_on_Qualification__c.isUpdateable(),
                check.canBypass, 'canBypass follows field-level security');
            Assert.isTrue(check.matches.size() <= LeadMeetingOutcomeController_CC.MAX_DUPLICATE_MATCHES, 'List is capped');
            // Which records match depends on the org's active duplicate rules; the Lead itself is never listed.
            for (LeadMeetingOutcomeController_CC.DuplicateMatch match : check.matches) {
                Assert.areNotEqual(twins[0].Id, match.recordId, 'The Lead never matches itself');
                Assert.isNotNull(match.objectLabel, 'Each match names its object');
            }
        }
    }

    @isTest
    static void duplicateCheck_RejectsNonLeadIds() {
        System.runAs(TestAdminAccess_CC.admin()) {
            try {
                LeadMeetingOutcomeController_CC.getDuplicateCheck(UserInfo.getUserId());
                Assert.fail('A non-Lead Id must be rejected');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Lead record'), e.getMessage());
            }
        }
    }

    @isTest
    static void invalidInput_Throws() {
        System.runAs(TestAdminAccess_CC.admin()) {
            Lead leadRecord = engageLead('Outcome Invalid Co');
            for (String stage : new List<String>{ 'Engage', 'Identify', null }) {
                try {
                    LeadMeetingOutcomeController_CC.getOutcomeForm(leadRecord.Id, stage);
                    Assert.fail('Stage ' + stage + ' must be rejected');
                } catch (AuraHandledException e) {
                    Assert.isTrue(e.getMessage().contains('Unknown outcome stage'), e.getMessage());
                }
            }
            try {
                LeadMeetingOutcomeController_CC.getOutcomeForm(UserInfo.getUserId(), 'Qualified');
                Assert.fail('A non-Lead Id must be rejected');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Lead record'), e.getMessage());
            }
        }
    }
}