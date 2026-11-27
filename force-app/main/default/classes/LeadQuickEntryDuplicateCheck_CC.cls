/**
 * =============================================================================
 * Class Name    : LeadQuickEntryDuplicateCheck_CC
 * Description   : Read-only duplicate check for the New Lead Wizard
 *                 (Screen Flow Lead_Quick_Entry_CC). Runs before the Lead is
 *                 created so the user can correct, stop or knowingly continue.
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 * 1          27/10/2026   Aaron Blackledge   Initial version (UI rework)
 *
 * =============================================================================
 * Behaviour
 * =============================================================================
 * 1. Rule matches: Datacloud.FindDuplicates on the unsaved candidate, i.e. the
 *    same active Lead duplicate rules the trigger handler uses after insert and
 *    on entry to Qualified. Email_List_CC__c / Product_Category_Text_CC__c are
 *    derived with the handler's own public helpers so the candidate is compared
 *    exactly as the saved record would be.
 * 2. Company matches: no active rule matches on Company, so a SOSL phrase
 *    search finds unconverted Leads and Accounts whose company/name contains
 *    the entered company (legal suffixes such as Ltd/Inc ignored).
 * 3. Access: every record returned to the flow is re-read WITH USER_MODE, which
 *    enforces object, field and record (sharing) access for the running user.
 *    Records the user cannot read are never named, linked or counted.
 * 4. Never writes data and never sets any duplicate-bypass field.
 * 5. isSuccess = false means the check could not be completed; that is distinct
 *    from isSuccess = true and hasMatches = false (checked, nothing found).
 *    The check is reported as NOT completed when any part could not run fully:
 *    - Lead or Account not searchable for the user, or a query/search error;
 *    - the company name is too short to search;
 *    - the company search reached its row limit and found nothing usable (the
 *      real match could be beyond the cut-off);
 *    - a duplicate rule matched a record type this check cannot display;
 *    - a duplicate rule matched records the user cannot read (named nowhere).
 *    Accessible matches found before the problem are still listed.
 * =============================================================================
 */
public with sharing class LeadQuickEntryDuplicateCheck_CC {

    @TestVisible
    private static final Integer FIND_DUPLICATES_BATCH_SIZE = 50;
    @TestVisible
    private static final Integer MAX_MATCHES_PER_OBJECT = 10;
    private static final Integer MIN_COMPANY_CORE_LENGTH = 2;
    @TestVisible
    private static final Integer MAX_SEARCH_EXPRESSION_LENGTH = 9000;
    /** Must equal the literal LIMIT used in each SOSL RETURNING clause below. */
    @TestVisible
    private static final Integer SOSL_RESULT_LIMIT = 50;
    private static final String INCOMPLETE = 'IncompleteCheck';

    private static final String REASON_RULE = 'Matches an active duplicate rule';
    private static final String REASON_COMPANY = 'Similar company name';

    private static final Set<String> LEGAL_SUFFIXES = new Set<String>{
        'LTD', 'LIMITED', 'INC', 'INCORPORATED', 'LLC', 'LLP', 'PLC', 'CORP',
        'CORPORATION', 'CO', 'COMPANY', 'GMBH', 'SA', 'BV', 'GROUP'
    };
    private static final String SOSL_RESERVED = '\\?&|!{}[]()^~*:"\'+-';

    /** Test hook: forces the duplicate-rule step to fail so error handling can be verified. */
    @TestVisible
    private static Boolean forceRuleCheckFailure = false;
    /** Test hook: simulates a user without Account read access. */
    @TestVisible
    private static Boolean forceAccountInaccessible = false;

    /**
     * Flow input.
     */
    public class Request {
        @InvocableVariable(label='Candidate Lead' description='Unsaved Lead assembled by the wizard. It is not inserted.' required=true)
        public Lead candidate;
    }

    /**
     * Flow output.
     */
    public class Response {
        @InvocableVariable(label='Check Completed' description='False when the check could not be completed. Not the same as no matches.')
        public Boolean isSuccess = true;
        @InvocableVariable(label='Has Matches' description='True when at least one accessible possible match was found.')
        public Boolean hasMatches = false;
        @InvocableVariable(label='Match Count' description='Number of accessible possible matches listed.')
        public Integer matchCount = 0;
        @InvocableVariable(label='Match Summary (HTML)' description='HTML list with links. All record values are HTML-escaped.')
        public String matchSummaryHtml = '';
        @InvocableVariable(label='Match Summary (Text)' description='Plain-text list of the same matches.')
        public String matchSummaryText = '';
        @InvocableVariable(label='Error Message' description='Why the check could not be completed.')
        public String errorMessage;
        @InvocableVariable(label='Error Type' description='Exception type when the check failed.')
        public String errorType;
    }

    /** Signals an unusable request without failing the other requests in the batch. */
    public class DuplicateCheckException extends Exception {}

    /**
     * Checks each candidate Lead for possible duplicates without inserting it.
     *
     * @param requests one request per flow interview; bulk-safe
     * @return one response per request, in the same order
     * @example
     * List<LeadQuickEntryDuplicateCheck_CC.Response> results =
     *     LeadQuickEntryDuplicateCheck_CC.checkForDuplicates(requests);
     */
    @InvocableMethod(
        label='Check New Lead for Possible Duplicates'
        description='Read-only. Uses active Lead duplicate rules plus a company-name search. Returns only records the running user can read.'
        category='Lead'
    )
    public static List<Response> checkForDuplicates(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        List<Lead> candidates = new List<Lead>();
        for (Request request : requests) {
            Response response = new Response();
            responses.add(response);
            Lead candidate = request?.candidate;
            if (candidate == null || String.isBlank(candidate.Company)) {
                markFailed(response, new DuplicateCheckException('No candidate Lead with a Company was supplied.'));
                candidates.add(null);
            } else {
                candidates.add(prepareCandidate(candidate));
            }
        }

        if (!Schema.SObjectType.Lead.isAccessible()) {
            for (Response response : responses) {
                markFailed(response, new DuplicateCheckException('You do not have access to Leads, so duplicates could not be checked.'));
            }
            return responses;
        }

        Map<Integer, Set<Id>> ruleMatchIdsByIndex = findRuleMatchIds(candidates, responses);
        Map<Integer, List<SObject>> companyMatchesByIndex = findCompanyMatches(candidates, responses);
        Map<Id, SObject> accessibleRuleMatches = readAccessibleRecords(ruleMatchIdsByIndex, responses);

        for (Integer index = 0; index < responses.size(); index++) {
            if (candidates[index] == null) {
                continue;
            }
            buildSummary(
                responses[index],
                ruleMatchIdsByIndex.get(index),
                accessibleRuleMatches,
                companyMatchesByIndex.get(index)
            );
        }
        return responses;
    }

    /**
     * Copies the wizard's candidate and derives the fields the active matching
     * rule compares, using the trigger handler's own public helpers.
     */
    private static Lead prepareCandidate(Lead source) {
        Lead candidate = source.clone(false, true, false, false);
        List<Lead> wrapper = new List<Lead>{ candidate };
        LeadTriggerHandler_CC_New.sortEmailValues(wrapper, null);
        LeadTriggerHandler_CC_New.sortProductCategories(wrapper, null);
        return candidate;
    }

    /**
     * Runs FindDuplicates in chunks of 50 (platform limit). A failing chunk marks
     * only its own responses as failed.
     */
    private static Map<Integer, Set<Id>> findRuleMatchIds(List<Lead> candidates, List<Response> responses) {
        Map<Integer, Set<Id>> matchIdsByIndex = new Map<Integer, Set<Id>>();
        List<Lead> chunk = new List<Lead>();
        List<Integer> chunkIndexes = new List<Integer>();

        for (Integer index = 0; index < candidates.size(); index++) {
            if (candidates[index] == null) {
                continue;
            }
            chunk.add(candidates[index]);
            chunkIndexes.add(index);
            if (chunk.size() == FIND_DUPLICATES_BATCH_SIZE) {
                processRuleChunk(chunk, chunkIndexes, matchIdsByIndex, responses);
                chunk = new List<Lead>();
                chunkIndexes = new List<Integer>();
            }
        }
        if (!chunk.isEmpty()) {
            processRuleChunk(chunk, chunkIndexes, matchIdsByIndex, responses);
        }
        return matchIdsByIndex;
    }

    private static void processRuleChunk(
        List<Lead> chunk,
        List<Integer> chunkIndexes,
        Map<Integer, Set<Id>> matchIdsByIndex,
        List<Response> responses
    ) {
        try {
            if (forceRuleCheckFailure) {
                throw new DuplicateCheckException('Simulated duplicate rule failure.');
            }
            List<Datacloud.FindDuplicatesResult> results = Datacloud.FindDuplicates.findDuplicates(chunk);
            for (Integer position = 0; position < results.size(); position++) {
                Set<Id> matchIds = new Set<Id>();
                for (Datacloud.DuplicateResult duplicateResult : results[position].getDuplicateResults()) {
                    for (Datacloud.MatchResult matchResult : duplicateResult.getMatchResults()) {
                        for (Datacloud.MatchRecord matchRecord : matchResult.getMatchRecords()) {
                            if (matchRecord.getRecord()?.Id != null) {
                                matchIds.add(matchRecord.getRecord().Id);
                            }
                        }
                    }
                }
                matchIdsByIndex.put(chunkIndexes[position], matchIds);
            }
        } catch (Exception checkError) {
            for (Integer index : chunkIndexes) {
                markFailed(responses[index], checkError);
            }
        }
    }

    /**
     * One SOSL phrase search for all candidates, then each hit is assigned to the
     * candidate(s) whose normalised company core it contains. Any condition that
     * prevents a full company search marks the request as not completed.
     */
    private static Map<Integer, List<SObject>> findCompanyMatches(List<Lead> candidates, List<Response> responses) {
        Map<Integer, List<SObject>> matchesByIndex = new Map<Integer, List<SObject>>();
        Map<Integer, String> coreByIndex = new Map<Integer, String>();
        List<String> phrases = new List<String>();
        Set<String> seenCores = new Set<String>();

        for (Integer index = 0; index < candidates.size(); index++) {
            if (candidates[index] == null) {
                continue;
            }
            String core = normaliseCompany(candidates[index].Company);
            if (core.length() < MIN_COMPANY_CORE_LENGTH) {
                markIncomplete(responses[index], 'The company name is too short to search for similar companies.');
                continue;
            }
            coreByIndex.put(index, core);
            if (seenCores.add(core)) {
                phrases.add('"' + escapeSosl(core) + '"');
            }
        }
        if (phrases.isEmpty()) {
            return matchesByIndex;
        }

        String searchExpression = String.join(phrases, ' OR ');
        if (searchExpression.length() > MAX_SEARCH_EXPRESSION_LENGTH) {
            markAllIncomplete(responses, coreByIndex.keySet(), 'Too many companies to search in one request.');
            return matchesByIndex;
        }

        Boolean accountsSearchable = Schema.SObjectType.Account.isAccessible() && !forceAccountInaccessible;
        if (!accountsSearchable) {
            markAllIncomplete(responses, coreByIndex.keySet(), 'Accounts could not be searched because you do not have access to Accounts.');
        }

        List<List<SObject>> hitsByObject;
        try {
            hitsByObject = searchCompanies(searchExpression, accountsSearchable);
        } catch (Exception searchError) {
            for (Integer index : coreByIndex.keySet()) {
                markFailed(responses[index], searchError);
            }
            return matchesByIndex;
        }

        Boolean truncated = false;
        List<SObject> hits = new List<SObject>();
        for (List<SObject> objectHits : hitsByObject) {
            truncated |= objectHits.size() >= SOSL_RESULT_LIMIT;
            hits.addAll(objectHits);
        }

        for (Integer index : coreByIndex.keySet()) {
            List<SObject> matches = new List<SObject>();
            for (SObject hit : hits) {
                String hitName = hit instanceof Lead ? ((Lead) hit).Company : ((Account) hit).Name;
                if (normaliseCompany(hitName).contains(coreByIndex.get(index))) {
                    matches.add(hit);
                }
            }
            if (truncated && matches.isEmpty()) {
                markIncomplete(responses[index], 'The company search returned too many results to be sure there is no match. Refine the company name.');
            }
            matchesByIndex.put(index, matches);
        }
        return matchesByIndex;
    }

    /**
     * SOSL in user mode: enforces object, field and sharing access.
     * Returns one list per searched object. LIMIT literals must equal SOSL_RESULT_LIMIT.
     */
    private static List<List<SObject>> searchCompanies(String searchExpression, Boolean includeAccounts) {
        if (includeAccounts) {
            return [
                FIND :searchExpression IN ALL FIELDS
                RETURNING
                    Lead(Id, Name, Company, City, PostalCode, Status, Owner.Name WHERE IsConverted = false ORDER BY LastModifiedDate DESC LIMIT 50),
                    Account(Id, Name, BillingCity, BillingPostalCode, Owner.Name ORDER BY Name LIMIT 50)
                WITH USER_MODE
            ];
        }
        return [
            FIND :searchExpression IN ALL FIELDS
            RETURNING
                Lead(Id, Name, Company, City, PostalCode, Status, Owner.Name WHERE IsConverted = false ORDER BY LastModifiedDate DESC LIMIT 50)
            WITH USER_MODE
        ];
    }

    /**
     * Re-reads rule-matched records in user mode so only records the caller can
     * read (object, field and sharing) are ever described back to the flow.
     * Matches of unsupported object types mark the request as not completed.
     */
    private static Map<Id, SObject> readAccessibleRecords(Map<Integer, Set<Id>> matchIdsByIndex, List<Response> responses) {
        Map<Id, SObject> recordsById = new Map<Id, SObject>();
        Set<Id> leadIds = new Set<Id>();
        Set<Id> accountIds = new Set<Id>();
        for (Integer index : matchIdsByIndex.keySet()) {
            for (Id matchId : matchIdsByIndex.get(index)) {
                if (matchId.getSObjectType() == Lead.SObjectType) {
                    leadIds.add(matchId);
                } else if (matchId.getSObjectType() == Account.SObjectType) {
                    accountIds.add(matchId);
                } else {
                    markIncomplete(responses[index], 'A duplicate rule matched a record type this check cannot display.');
                }
            }
        }
        if (leadIds.isEmpty() && accountIds.isEmpty()) {
            return recordsById;
        }
        try {
            if (!leadIds.isEmpty()) {
                recordsById.putAll([
                    SELECT Id, Name, Company, City, PostalCode, Status, IsConverted, Owner.Name
                    FROM Lead
                    WHERE Id IN :leadIds
                    WITH USER_MODE
                ]);
            }
            if (!accountIds.isEmpty()) {
                recordsById.putAll([
                    SELECT Id, Name, BillingCity, BillingPostalCode, Owner.Name
                    FROM Account
                    WHERE Id IN :accountIds
                    WITH USER_MODE
                ]);
            }
        } catch (Exception readError) {
            for (Integer index : matchIdsByIndex.keySet()) {
                if (!matchIdsByIndex.get(index).isEmpty()) {
                    markFailed(responses[index], readError);
                }
            }
        }
        return recordsById;
    }

    private static void buildSummary(
        Response response,
        Set<Id> ruleMatchIds,
        Map<Id, SObject> readableRuleMatches,
        List<SObject> companyMatches
    ) {
        Map<Id, String> reasonById = new Map<Id, String>();
        Map<Id, SObject> recordById = new Map<Id, SObject>();
        Integer unreadableRuleMatches = 0;

        for (Id matchId : ruleMatchIds ?? new Set<Id>()) {
            if (!isSupportedMatchType(matchId)) {
                continue;
            }
            SObject record = readableRuleMatches.get(matchId);
            if (record == null) {
                unreadableRuleMatches++;
            } else if (!(record instanceof Lead) || !((Lead) record).IsConverted) {
                recordById.put(matchId, record);
                reasonById.put(matchId, REASON_RULE);
            }
        }
        if (unreadableRuleMatches > 0 && response.isSuccess) {
            markIncomplete(response, 'A duplicate rule matched records you do not have access to review.');
        }
        for (SObject record : companyMatches ?? new List<SObject>()) {
            if (!recordById.containsKey(record.Id)) {
                recordById.put(record.Id, record);
                reasonById.put(record.Id, REASON_COMPANY);
            }
        }

        List<String> htmlItems = new List<String>();
        List<String> textItems = new List<String>();
        Map<SObjectType, Integer> shownByType = new Map<SObjectType, Integer>();
        Integer notShown = 0;

        for (Id recordId : recordById.keySet()) {
            SObjectType recordType = recordId.getSObjectType();
            Integer shown = shownByType.get(recordType) ?? 0;
            if (shown >= MAX_MATCHES_PER_OBJECT) {
                notShown++;
                continue;
            }
            shownByType.put(recordType, shown + 1);
            String[] parts = describeRecord(recordById.get(recordId));
            String reason = reasonById.get(recordId);
            htmlItems.add(
                '<li><a href="/lightning/r/' + parts[0] + '/' + recordId + '/view" target="_blank">'
                    + parts[1].escapeHtml4() + '</a> (' + parts[0] + ') ' + parts[2].escapeHtml4()
                    + ' <em>' + reason.escapeHtml4() + '</em></li>'
            );
            textItems.add('- ' + parts[0] + ': ' + parts[1] + ' ' + parts[2] + ' [' + reason + ']');
        }

        response.matchCount = htmlItems.size();
        response.hasMatches = !htmlItems.isEmpty();
        if (response.hasMatches) {
            String overflow = notShown > 0 ? 'Plus ' + notShown + ' more not listed.' : '';
            response.matchSummaryHtml = '<ul>' + String.join(htmlItems, '') + '</ul>'
                + (String.isBlank(overflow) ? '' : '<p>' + overflow + '</p>');
            response.matchSummaryText = String.join(textItems, '\n')
                + (String.isBlank(overflow) ? '' : '\n' + overflow);
        }
    }

    @TestVisible
    private static Boolean isSupportedMatchType(Id recordId) {
        SObjectType recordType = recordId?.getSObjectType();
        return recordType == Lead.SObjectType || recordType == Account.SObjectType;
    }

    /** Returns [object label, display name, details] for a Lead or Account. */
    private static String[] describeRecord(SObject record) {
        if (record instanceof Lead) {
            Lead leadRecord = (Lead) record;
            return new String[]{
                'Lead',
                leadRecord.Name ?? '',
                joinNonBlank(new List<String>{
                    leadRecord.Company, leadRecord.City, leadRecord.PostalCode,
                    leadRecord.Status, leadRecord.Owner?.Name == null ? null : 'Owner: ' + leadRecord.Owner.Name
                })
            };
        }
        Account accountRecord = (Account) record;
        return new String[]{
            'Account',
            accountRecord.Name ?? '',
            joinNonBlank(new List<String>{
                accountRecord.BillingCity, accountRecord.BillingPostalCode,
                accountRecord.Owner?.Name == null ? null : 'Owner: ' + accountRecord.Owner.Name
            })
        };
    }

    private static String joinNonBlank(List<String> values) {
        List<String> kept = new List<String>();
        for (String value : values) {
            if (String.isNotBlank(value)) {
                kept.add(value);
            }
        }
        return String.join(kept, ' · ');
    }

    /**
     * Upper-cases, replaces punctuation with spaces, collapses whitespace and
     * drops trailing legal suffixes ("Acme Foods Ltd." -> "ACME FOODS").
     */
    @TestVisible
    private static String normaliseCompany(String company) {
        if (String.isBlank(company)) {
            return '';
        }
        String cleaned = company.toUpperCase().replaceAll('[^A-Z0-9& ]', ' ').normalizeSpace();
        List<String> tokens = cleaned.split(' ');
        while (tokens.size() > 1 && LEGAL_SUFFIXES.contains(tokens[tokens.size() - 1])) {
            tokens.remove(tokens.size() - 1);
        }
        return String.join(tokens, ' ');
    }

    @TestVisible
    private static String escapeSosl(String value) {
        String escaped = '';
        for (Integer position = 0; position < value.length(); position++) {
            String character = value.substring(position, position + 1);
            escaped += SOSL_RESERVED.contains(character) ? '\\' + character : character;
        }
        return escaped;
    }

    private static void markIncomplete(Response response, String message) {
        markFailed(response, new DuplicateCheckException(message));
        response.errorType = INCOMPLETE;
    }

    private static void markAllIncomplete(List<Response> responses, Set<Integer> indexes, String message) {
        for (Integer index : indexes) {
            markIncomplete(responses[index], message);
        }
    }

    private static void markFailed(Response response, Exception error) {
        response.isSuccess = false;
        response.errorType = error.getTypeName();
        String message = error.getMessage();
        response.errorMessage = String.isBlank(response.errorMessage)
            ? message
            : response.errorMessage + ' ' + message;
    }
}