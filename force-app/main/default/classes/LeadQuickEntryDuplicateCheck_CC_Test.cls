/**
 * =============================================================================
 * Class Name    : LeadQuickEntryDuplicateCheck_CC_Test
 * Description   : Tests for LeadQuickEntryDuplicateCheck_CC (New Lead Wizard).
 *                 Relies on the org's active Lead_Duplicate_Rule /
 *                 Lead_Duplicate_Fields_Matching_Rule (FirstName, LastName,
 *                 Email_List_CC__c, Product_Category_Text_CC__c,
 *                 LinkedIn_Profile_URL_CC__c; exact; blanks match).
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 * 1          27/10/2026   Aaron Blackledge   Initial version (UI rework)
 * =============================================================================
 */
@IsTest
private class LeadQuickEntryDuplicateCheck_CC_Test {

    private static final String EXISTING_COMPANY = 'Zylophane Widgets Limited';
    private static final String EXISTING_FIRST = 'Quentin';
    private static final String EXISTING_LAST = 'Quickentrytest';
    private static final String EXISTING_EMAIL = 'quentin.quickentrytest@carltontest.invalid';
    private static final String PLACEHOLDER_PREFIX = 'Needs to Identify - ';
    private static final Integer BULK_SIZE = 251;

    @TestSetup
    static void setupData() {
        insert new List<Lead>{
            buildLead(EXISTING_FIRST, EXISTING_LAST, EXISTING_COMPANY, EXISTING_EMAIL),
            buildLead(null, PLACEHOLDER_PREFIX + 'Zylophane Widgets', 'Zylophane Widgets', null),
            buildLead('Una', 'Unrelatedtest', 'Unrelated Holdings Corp', 'una.unrelated@carltontest.invalid')
        };
    }

    private static Lead buildLead(String firstName, String lastName, String company, String email) {
        return new Lead(
            FirstName = firstName,
            LastName = lastName,
            Company = company,
            Email = email,
            Status = 'Identify',
            City = 'Chicago',
            PostalCode = '60601',
            CountryCode = 'US'
        );
    }

    private static List<LeadQuickEntryDuplicateCheck_CC.Response> check(List<Lead> candidates) {
        List<LeadQuickEntryDuplicateCheck_CC.Request> requests = new List<LeadQuickEntryDuplicateCheck_CC.Request>();
        for (Lead candidate : candidates) {
            LeadQuickEntryDuplicateCheck_CC.Request request = new LeadQuickEntryDuplicateCheck_CC.Request();
            request.candidate = candidate;
            requests.add(request);
        }
        return LeadQuickEntryDuplicateCheck_CC.checkForDuplicates(requests);
    }

    private static Lead existingLead(String lastName) {
        return [SELECT Id, Company FROM Lead WHERE LastName = :lastName LIMIT 1];
    }

    @IsTest
    static void shouldReturnRuleMatch_WhenCandidateMatchesExistingLeadNameAndEmail() {
        Lead existing = existingLead(EXISTING_LAST);
        Lead candidate = buildLead(EXISTING_FIRST, EXISTING_LAST, 'Completely Different Company', EXISTING_EMAIL);

        Test.startTest();
        LeadQuickEntryDuplicateCheck_CC.Response response = check(new List<Lead>{ candidate })[0];
        Test.stopTest();

        Assert.isTrue(response.isSuccess, 'Check should complete: ' + response.errorMessage);
        Assert.isTrue(response.hasMatches, 'Existing Lead with same name and email should match the active rule');
        Assert.areEqual(1, response.matchCount, 'Exactly the one existing Lead should be listed');
        Assert.isTrue(response.matchSummaryHtml.contains(existing.Id), 'Summary should link to the matching Lead');
        Assert.isTrue(response.matchSummaryText.contains('Matches an active duplicate rule'), 'Reason should be the duplicate rule');
    }

    @IsTest
    static void shouldMatchOnlySameCompanyPlaceholder_WhenContactUnknown() {
        Lead existingPlaceholder = existingLead(PLACEHOLDER_PREFIX + 'Zylophane Widgets');
        Lead sameCompany = buildLead(null, PLACEHOLDER_PREFIX + 'Zylophane Widgets', 'Zylophane Widgets', null);
        Lead otherCompany = buildLead(null, PLACEHOLDER_PREFIX + 'Brand New Prospect', 'Brand New Prospect', null);

        Test.startTest();
        List<LeadQuickEntryDuplicateCheck_CC.Response> responses = check(new List<Lead>{ sameCompany, otherCompany });
        Test.stopTest();

        Assert.isTrue(responses[0].hasMatches, 'Same-company placeholder should match the existing unknown-contact Lead');
        Assert.isTrue(responses[0].matchSummaryHtml.contains(existingPlaceholder.Id), 'Match should be the same-company placeholder Lead');
        Assert.isTrue(responses[1].isSuccess, 'Other-company check should complete');
        Assert.isFalse(responses[1].hasMatches, 'Company-specific placeholder must not match unrelated unknown-contact Leads');
    }

    @IsTest
    static void shouldReturnCompanyMatch_WhenSearchFindsSameCompanyWithDifferentSuffix() {
        Lead sameCompany = existingLead(EXISTING_LAST);
        Lead unrelated = existingLead('Unrelatedtest');
        Test.setFixedSearchResults(new List<Id>{ sameCompany.Id, unrelated.Id });
        Lead candidate = buildLead('Ada', 'Differentperson', 'Zylophane Widgets Ltd.', 'ada@carltontest.invalid');

        Test.startTest();
        LeadQuickEntryDuplicateCheck_CC.Response response = check(new List<Lead>{ candidate })[0];
        Test.stopTest();

        Assert.isTrue(response.isSuccess, 'Check should complete: ' + response.errorMessage);
        Assert.areEqual(1, response.matchCount, 'Only the same-company Lead should be listed');
        Assert.isTrue(response.matchSummaryHtml.contains(sameCompany.Id), 'Same company with Limited vs Ltd. should match');
        Assert.isFalse(response.matchSummaryHtml.contains(unrelated.Id), 'Search hits for other companies must be filtered out');
        Assert.isTrue(response.matchSummaryText.contains('Similar company name'), 'Reason should be the company search');
    }

    @IsTest
    static void shouldReportCompletedWithNoMatches_WhenNothingSimilarExists() {
        Lead candidate = buildLead('Nobody', 'Nomatchtest', 'Nothing Similar Anywhere', 'nobody@carltontest.invalid');

        Test.startTest();
        LeadQuickEntryDuplicateCheck_CC.Response response = check(new List<Lead>{ candidate })[0];
        Test.stopTest();

        Assert.isTrue(response.isSuccess, 'No matches is a completed check');
        Assert.isFalse(response.hasMatches, 'Nothing should match');
        Assert.areEqual(0, response.matchCount, 'Match count should be zero');
        Assert.isNull(response.errorMessage, 'A completed check has no error message');
    }

    @IsTest
    static void shouldReportNotCompleted_WhenDuplicateRuleCheckFails() {
        LeadQuickEntryDuplicateCheck_CC.forceRuleCheckFailure = true;
        Lead candidate = buildLead(EXISTING_FIRST, EXISTING_LAST, 'Completely Different Company', EXISTING_EMAIL);

        Test.startTest();
        LeadQuickEntryDuplicateCheck_CC.Response response = check(new List<Lead>{ candidate })[0];
        Test.stopTest();

        Assert.isFalse(response.isSuccess, 'A failed rule check must not be reported as success');
        Assert.isFalse(response.hasMatches, 'No matches can be claimed when the rule check failed');
        Assert.isTrue(response.errorMessage.contains('Simulated duplicate rule failure.'), 'Error should explain the failure');
        Assert.isNotNull(response.errorType, 'Error type should be returned');
    }

    @IsTest
    static void shouldReportNotCompleted_WhenCandidateIsMissing() {
        Test.startTest();
        LeadQuickEntryDuplicateCheck_CC.Response response = check(new List<Lead>{ null })[0];
        Test.stopTest();

        Assert.isFalse(response.isSuccess, 'A missing candidate cannot be checked');
        Assert.isTrue(response.errorMessage.contains('No candidate Lead'), 'Error should explain the missing candidate');
    }

    @IsTest
    static void shouldReturnEmptyList_WhenNoRequests() {
        Test.startTest();
        List<LeadQuickEntryDuplicateCheck_CC.Response> responses =
            LeadQuickEntryDuplicateCheck_CC.checkForDuplicates(new List<LeadQuickEntryDuplicateCheck_CC.Request>());
        Test.stopTest();

        Assert.areEqual(0, responses.size(), 'No requests should produce no responses');
    }

    @IsTest
    static void shouldCheckEveryRequestWithOneSearch_WhenBulkCrossesFindDuplicatesChunks() {
        List<Lead> candidates = new List<Lead>();
        for (Integer index = 0; index < BULK_SIZE; index++) {
            candidates.add(buildLead('Bulk', 'Bulktest' + index, 'Bulk Prospect ' + index, null));
        }

        Test.startTest();
        List<LeadQuickEntryDuplicateCheck_CC.Response> responses = check(candidates);
        Integer searchesUsed = Limits.getSoslQueries();
        Test.stopTest();

        Assert.areEqual(BULK_SIZE, responses.size(), 'One response per request, in order');
        for (LeadQuickEntryDuplicateCheck_CC.Response response : responses) {
            Assert.isTrue(response.isSuccess, 'Every bulk request should complete: ' + response.errorMessage);
        }
        Assert.areEqual(1, searchesUsed, 'Company search must run once for the whole batch');
    }

    @IsTest
    static void shouldNormaliseCompanyNames_WhenLegalSuffixesAndPunctuationDiffer() {
        Assert.areEqual('ACME FOODS', LeadQuickEntryDuplicateCheck_CC.normaliseCompany('Acme Foods Ltd.'), 'Ltd. suffix removed');
        Assert.areEqual('ACME FOODS', LeadQuickEntryDuplicateCheck_CC.normaliseCompany('  acme-foods, Inc '), 'Punctuation and Inc removed');
        Assert.areEqual('LIMITED', LeadQuickEntryDuplicateCheck_CC.normaliseCompany('Limited'), 'A lone suffix is kept');
        Assert.areEqual('', LeadQuickEntryDuplicateCheck_CC.normaliseCompany(null), 'Blank company yields blank core');
    }

    @IsTest
    static void shouldEscapeSoslReservedCharacters_WhenBuildingSearch() {
        Assert.areEqual('A\\&B', LeadQuickEntryDuplicateCheck_CC.escapeSosl('A&B'), 'Ampersand must be escaped');
        Assert.areEqual('Plain', LeadQuickEntryDuplicateCheck_CC.escapeSosl('Plain'), 'Plain text unchanged');
    }

    @IsTest
    static void shouldReportNotCompleted_WhenCompanyTooShortToSearch() {
        Lead candidate = buildLead('Shorty', 'Shortcompanytest', 'X', 'shorty@carltontest.invalid');

        Test.startTest();
        LeadQuickEntryDuplicateCheck_CC.Response response = check(new List<Lead>{ candidate })[0];
        Test.stopTest();

        Assert.isFalse(response.isSuccess, 'A skipped company search must not be reported as a completed check');
        Assert.areEqual('IncompleteCheck', response.errorType, 'Should be classified as an incomplete check');
        Assert.isTrue(response.errorMessage.contains('too short'), 'Message should explain the skipped search');
    }

    @IsTest
    static void shouldReportNotCompleted_WhenAccountsCannotBeSearched() {
        LeadQuickEntryDuplicateCheck_CC.forceAccountInaccessible = true;
        Lead candidate = buildLead('Acc', 'Noaccounttest', 'Nothing Similar Anywhere', 'acc@carltontest.invalid');

        Test.startTest();
        LeadQuickEntryDuplicateCheck_CC.Response response = check(new List<Lead>{ candidate })[0];
        Test.stopTest();

        Assert.isFalse(response.isSuccess, 'Lead-only search must not be reported as a completed check');
        Assert.areEqual('IncompleteCheck', response.errorType, 'Should be classified as an incomplete check');
        Assert.isTrue(response.errorMessage.contains('Accounts could not be searched'), 'Message should name the missing Account search');
    }

    @IsTest
    static void shouldReportNotCompleted_WhenCompanySearchHitsLimitWithoutMatch() {
        List<Lead> fillers = new List<Lead>();
        for (Integer index = 0; index < LeadQuickEntryDuplicateCheck_CC.SOSL_RESULT_LIMIT; index++) {
            fillers.add(buildLead('Filler', 'Fillertest' + index, 'Filler Holdings ' + index, null));
        }
        insert fillers;
        List<Id> fillerIds = new List<Id>();
        for (Lead filler : fillers) {
            fillerIds.add(filler.Id);
        }
        Test.setFixedSearchResults(fillerIds);
        Lead candidate = buildLead('Quinn', 'Quasartest', 'Quasar Nomatch', 'quinn@carltontest.invalid');

        Test.startTest();
        LeadQuickEntryDuplicateCheck_CC.Response response = check(new List<Lead>{ candidate })[0];
        Test.stopTest();

        Assert.isFalse(response.isSuccess, 'A search cut off at its limit with no usable match is not a completed check');
        Assert.isFalse(response.hasMatches, 'Unrelated search hits must not be listed');
        Assert.isTrue(response.errorMessage.contains('too many results'), 'Message should explain the truncated search');
    }

    @IsTest
    static void shouldOnlySupportLeadAndAccountMatches_WhenClassifyingRuleMatches() {
        Lead existing = existingLead(EXISTING_LAST);

        Assert.isTrue(LeadQuickEntryDuplicateCheck_CC.isSupportedMatchType(existing.Id), 'Lead matches are supported');
        Assert.isFalse(LeadQuickEntryDuplicateCheck_CC.isSupportedMatchType(UserInfo.getUserId()), 'Other object types are not displayable');
        Assert.isFalse(LeadQuickEntryDuplicateCheck_CC.isSupportedMatchType(null), 'Null is not a match');
    }
}
