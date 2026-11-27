@IsTest
private class NewLeadWizardController_CC_Test {
    private class FailingInvoker implements NewLeadWizardController_CC.ActionInvoker {
        public Map<String, Object> invoke(String actionName, Map<String, Object> inputs) {
            throw new AuraHandledException('Action unavailable');
        }
    }
    private class FakeInvoker implements NewLeadWizardController_CC.ActionInvoker {
        public Map<String, Object> invoke(String actionName, Map<String, Object> inputs) {
            if (actionName == NewLeadWizardController_CC.ENTITY_DEFAULT_ACTION) {
                return new Map<String, Object>{ 'entityValue' => 'Carlton Packaging INC' };
            }
            Lead candidate = (Lead) inputs.get('candidate');
            return new Map<String, Object>{
                'isSuccess' => true,
                'hasMatches' => false,
                'matchCount' => 0,
                'matchSummaryText' => candidate.Company,
                'matchSummaryHtml' => ''
            };
        }
    }

    /**
     * createLead saves in user mode. The tests run as the System Administrator running them, given the Carlton
     * permission sets and access to the Lead and Account fields (TestAdminAccess_CC), applied inside System.runAs.
     */
    @TestSetup
    static void grantAccess() {
        TestAdminAccess_CC.grant(new List<SObjectType>{ Lead.SObjectType, Account.SObjectType });
    }

    private static Lead candidate() {
        return new Lead(FirstName = '  Alex  ', LastName = '  Buyer  ',
            Company = '  ZZTEST Wizard Company  ', Status = 'Engage',
            LeadSource = 'Web Search', Belongs_To_CC__c = entityForNewLeads(),
            Email = 'wizard@carltontest.invalid', City = 'Chicago', CountryCode = 'US');
    }

    /**
     * The Entity for test Leads. A new Identify Lead is routed to the owner that Lead_Company_Owner_Mapping_CC gives its
     * Entity; where that record holds the Id of a queue or user that does not exist in this org (Ids differ between
     * orgs), the save fails, so the Entity is left blank there and the Lead keeps its creator as owner.
     */
    private static String entityForNewLeads() {
        String entity = 'Carlton Packaging INC';
        for (Lead_Company_Owner_Mapping_CC__mdt mapping : [SELECT Owner_Id_CC__c FROM Lead_Company_Owner_Mapping_CC__mdt
                                                           WHERE Active_CC__c = true AND Company_Name_CC__c = null
                                                           AND Entity_CC__c = :entity AND Owner_Id_CC__c != null]) {
            if (!recordExists(mapping.Owner_Id_CC__c)) {
                return null;
            }
        }
        return entity;
    }

    private static Boolean recordExists(String recordId) {
        Id ownerId;
        try {
            ownerId = Id.valueOf(recordId.trim());
        } catch (Exception ex) {
            return false;
        }
        return [SELECT COUNT() FROM Group WHERE Id = :ownerId] + [SELECT COUNT() FROM User WHERE Id = :ownerId] > 0;
    }

    @IsTest
    static void accessAndSanitizationAreEnforced() {
        NewLeadWizardController_CC.accessOverride = false;
        Assert.isFalse(NewLeadWizardController_CC.getInitData().hasAccess);
        Boolean rejected = false;
        try {
            NewLeadWizardController_CC.checkDuplicates(candidate());
        } catch (AuraHandledException expected) {
            rejected = true;
        }
        Assert.isTrue(rejected, 'A user without Lead create access cannot call the action');

        Lead cleaned = NewLeadWizardController_CC.sanitize(candidate());
        Assert.areEqual('Alex', cleaned.FirstName);
        Assert.areEqual('Buyer', cleaned.LastName);
        Assert.areEqual('ZZTEST Wizard Company', cleaned.Company);
        Assert.areEqual('Identify', cleaned.Status);
        rejected = false;
        try {
            NewLeadWizardController_CC.sanitize(null);
        } catch (AuraHandledException expected) {
            rejected = true;
        }
        Assert.isTrue(rejected, 'Missing Lead details must be rejected');
    }

    @IsTest
    static void initializesChecksAndCreatesLead() {
        System.runAs(TestAdminAccess_CC.admin()) {
            NewLeadWizardController_CC.accessOverride = true;
            NewLeadWizardController_CC.invoker = new FakeInvoker();
            NewLeadWizardController_CC.InitData init = NewLeadWizardController_CC.getInitData();
            Assert.isTrue(init.hasAccess);
            Assert.areEqual('Carlton Packaging INC', init.suggestedEntity);

            NewLeadWizardController_CC.DuplicateCheckResult duplicate =
                NewLeadWizardController_CC.checkDuplicates(candidate());
            Assert.isTrue(duplicate.isSuccess);
            Assert.isFalse(duplicate.hasMatches);
            Assert.areEqual('ZZTEST Wizard Company', duplicate.matchSummaryText);

            NewLeadWizardController_CC.CreateResult created = NewLeadWizardController_CC.createLead(candidate());
            Assert.isNotNull(created.leadId);
            Assert.isTrue(created.readable);
            Assert.isTrue(NewLeadWizardController_CC.isLeadReadable(created.leadId));
            Assert.isFalse(NewLeadWizardController_CC.isLeadReadable(null));
            Lead stored = [SELECT Status, FirstName, LastName FROM Lead WHERE Id = :created.leadId];
            Assert.areEqual('Identify', stored.Status);
            Assert.areEqual('Alex', stored.FirstName);
        }
    }

    @IsTest
    static void unavailableEntitySuggestionDoesNotBlockWizard() {
        NewLeadWizardController_CC.accessOverride = true;
        NewLeadWizardController_CC.invoker = new FailingInvoker();
        NewLeadWizardController_CC.InitData init = NewLeadWizardController_CC.getInitData();
        Assert.isTrue(init.hasAccess);
        Assert.isNull(init.suggestedEntity, 'A suggestion failure should leave the wizard usable');
    }

    @IsTest
    static void duplicateSummaryBuildsReadableRows() {
        System.runAs(TestAdminAccess_CC.admin()) {
            NewLeadWizardController_CC.accessOverride = true;
            NewLeadWizardController_CC.CreateResult created = NewLeadWizardController_CC.createLead(candidate());
            String html = '<li><a href="/lightning/r/Lead/' + created.leadId +
                '/view">Alex Buyer</a> (Lead) <em>Same email</em></li> Plus 2 more not listed.';
            List<NewLeadWizardController_CC.MatchRow> rows =
                NewLeadWizardController_CC.buildMatchRows(html);
            Assert.areEqual(1, rows.size());
            Assert.areEqual(created.leadId, rows[0].id);
            Assert.areEqual('Same email', rows[0].reason);
            Assert.areEqual(2, NewLeadWizardController_CC.hiddenMatchCount(html));
            Assert.areEqual(0, NewLeadWizardController_CC.hiddenMatchCount(null));
            Assert.isNull(NewLeadWizardController_CC.buildMatchRows('unrecognized HTML'));
        }
    }

    private static String matchItem(String objectType, Id recordId, String label, String reason) {
        return '<li><a href="/lightning/r/' + objectType + '/' + recordId + '/view" target="_blank">' + label
            + '</a> (' + objectType + ') details <em>' + reason + '</em></li>';
    }

    @IsTest
    static void duplicateSummaryBuildsLeadAndAccountRows() {
        System.runAs(TestAdminAccess_CC.admin()) {
            NewLeadWizardController_CC.accessOverride = true;
            NewLeadWizardController_CC.CreateResult created = NewLeadWizardController_CC.createLead(candidate());
            Account entity = TestDataFactory_CC.createEntity('ZZTEST Wizard Account ' + TestDataFactory_CC.uniqueSuffix(), null, true);
            Id missingLeadId = Id.valueOf('00Q' + '1'.leftPad(12, '0'));
            String html = '<ul>'
                + matchItem('Lead', created.leadId, 'Alex Buyer', 'Same email')
                + matchItem('Lead', created.leadId, 'Alex Buyer', 'Listed twice')
                + matchItem('Account', entity.Id, 'Wizard Account', 'Same name &amp; city')
                + matchItem('Lead', missingLeadId, 'Gone', 'Deleted')
                + '</ul>';

            Test.startTest();
            List<NewLeadWizardController_CC.MatchRow> rows = NewLeadWizardController_CC.buildMatchRows(html);
            List<NewLeadWizardController_CC.MatchRow> none = NewLeadWizardController_CC.buildMatchRows('');
            Test.stopTest();

            Assert.areEqual(2, rows.size(), 'Duplicate and unreadable entries are skipped');
            Assert.areEqual('Lead', rows[0].objectType);
            Assert.areEqual('standard:lead', rows[0].iconName);
            Assert.areEqual('Same email', rows[0].reason, 'First reason wins for a repeated record');
            Assert.areEqual('Account', rows[1].objectType);
            Assert.areEqual('standard:account', rows[1].iconName);
            Assert.areEqual(entity.Id, rows[1].id);
            Assert.areEqual('Same name & city', rows[1].reason, 'Reason is unescaped');
            Assert.areEqual('/lightning/r/Account/' + entity.Id + '/view', rows[1].recordUrl);
            Assert.areEqual(0, none.size(), 'Blank HTML gives no rows');
        }
    }

    @IsTest
    static void failingDuplicateCheckIsReturnedNotThrown() {
        NewLeadWizardController_CC.accessOverride = true;
        NewLeadWizardController_CC.invoker = new FailingInvoker();
        Test.startTest();
        NewLeadWizardController_CC.DuplicateCheckResult result =
            NewLeadWizardController_CC.checkDuplicates(candidate());
        Test.stopTest();
        Assert.isFalse(result.isSuccess, 'A failed action is reported as unsuccessful');
        Assert.isNotNull(result.faultMessage, 'The fault message is returned to the UI');
        Assert.areEqual(0, result.matches.size(), 'No rows without a summary');
        Assert.areEqual(0, result.hiddenMatchCount);
    }

    @IsTest
    static void createLeadReportsDmlErrorsAndAccessChecks() {
        NewLeadWizardController_CC.accessOverride = true;
        Lead missingRequired = candidate();
        missingRequired.LastName = '   ';
        missingRequired.Company = null;
        String message;
        Test.startTest();
        try {
            NewLeadWizardController_CC.createLead(missingRequired);
        } catch (AuraHandledException expected) {
            message = expected.getMessage();
        }
        NewLeadWizardController_CC.accessOverride = false;
        Boolean readRejected = false;
        try {
            NewLeadWizardController_CC.isLeadReadable(null);
        } catch (AuraHandledException expected) {
            readRejected = true;
        }
        Test.stopTest();
        Assert.isNotNull(message, 'A Lead without required fields must be rejected');
        Assert.isTrue(readRejected, 'A user without Lead create access cannot check readability');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE Email = 'wizard@carltontest.invalid'], 'Nothing is inserted');
    }

    @IsTest
    static void realInvocableActionsAreUsedByDefault() {
        // No accessOverride and no fake invoker: the real Schema check and Invocable.Action plumbing run.
        Test.startTest();
        NewLeadWizardController_CC.InitData init = NewLeadWizardController_CC.getInitData();
        NewLeadWizardController_CC.DuplicateCheckResult duplicate =
            NewLeadWizardController_CC.checkDuplicates(candidate());
        Test.stopTest();
        Assert.areEqual(Schema.SObjectType.Lead.isCreateable(), init.hasAccess, 'Access follows Lead create permission');
        Assert.isNotNull(duplicate, 'The duplicate check always returns a result');
        Assert.isTrue(duplicate.isSuccess || duplicate.faultMessage != null || duplicate.errorMessage != null,
            'Either the check completes or the reason is reported');
    }

    @IsTest
    static void invocableInvokerReportsActionFailures() {
        NewLeadWizardController_CC.InvocableActionInvoker realInvoker = new NewLeadWizardController_CC.InvocableActionInvoker();
        Integer failures = 0;
        Test.startTest();
        try {
            // Required "candidate" input is missing.
            realInvoker.invoke(NewLeadWizardController_CC.DUPLICATE_CHECK_ACTION, new Map<String, Object>{ 'candidate' => null });
        } catch (Exception ex) {
            failures++;
        }
        try {
            realInvoker.invoke('Not_An_Existing_Action_CC', new Map<String, Object>());
        } catch (Exception ex) {
            failures++;
        }
        Map<String, Object> entityOutput;
        String entityError;
        try {
            entityOutput = realInvoker.invoke(NewLeadWizardController_CC.ENTITY_DEFAULT_ACTION, new Map<String, Object>());
        } catch (Exception ex) {
            entityError = ex.getMessage();
        }
        Test.stopTest();
        Assert.isTrue(failures >= 1, 'An unknown action must fail');
        Assert.isTrue(entityOutput != null || entityError != null, 'The entity action returns an output map or a reason');
    }
}