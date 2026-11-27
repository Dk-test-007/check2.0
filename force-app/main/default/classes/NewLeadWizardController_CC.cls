/**
 * Server side of the newLeadWizard LWC (replacement for the "New Lead Wizard" screen flow).
 *
 * Responsibilities
 *  - Check on every entry point (not only in the UI) that the running user can create Leads.
 *  - Call the existing invocable actions LeadEntityDefault_CC and LeadQuickEntryDuplicateCheck_CC
 *    through Invocable.Action, so their inner Request/Result class names are not hard-coded here.
 *  - Create the Lead in user mode (CRUD, FLS and sharing of the running user, like the flow's
 *    DefaultMode) and report whether the running user can still read it after automatic routing.
 */
public with sharing class NewLeadWizardController_CC {

    @TestVisible static final String DUPLICATE_CHECK_ACTION = 'LeadQuickEntryDuplicateCheck_CC';
    @TestVisible static final String ENTITY_DEFAULT_ACTION = 'LeadEntityDefault_CC';
    @TestVisible static final String INITIAL_STATUS = 'Identify';
    @TestVisible static final String NO_ACCESS_MESSAGE = 'You do not have permission to create Leads.';

    /** Fields the wizard may set. Anything else sent by the client is ignored. */
    private static final List<Schema.SObjectField> WRITABLE_FIELDS = new List<Schema.SObjectField>{
        Lead.Company,
        Lead.Belongs_To_CC__c,
        Lead.LeadSource,
        Lead.Lead_Source_Other_CC__c,
        Lead.Trade_Show_Expo_Name__c,
        Lead.Referrer_Name_CC__c,
        Lead.Referrer_Type_CC__c,
        Lead.Referrer_Company_CC__c,
        Lead.Referrer_Email_CC__c,
        Lead.LinkedIn_Profile_URL_CC__c,
        Lead.ZoomInfo_Profile_URL_CC__c,
        Lead.Lead_Type_CC__c,
        Lead.Street,
        Lead.City,
        Lead.PostalCode,
        Lead.CountryCode,
        Lead.StateCode,
        Lead.FirstName,
        Lead.LastName,
        Lead.Title,
        Lead.Email,
        Lead.Phone,
        Lead.MobilePhone
    };

    // ---- Test seams --------------------------------------------------------------------------
    @TestVisible private static Boolean accessOverride;
    @TestVisible private static ActionInvoker invoker = new InvocableActionInvoker();

    // ---- DTOs --------------------------------------------------------------------------------
    public class InitData {
        @AuraEnabled public Boolean hasAccess = false;
        @AuraEnabled public String suggestedEntity;
    }

    public class DuplicateCheckResult {
        @AuraEnabled public Boolean isSuccess = false;
        @AuraEnabled public Boolean hasMatches = false;
        @AuraEnabled public Decimal matchCount;
        @AuraEnabled public String matchSummaryHtml;
        @AuraEnabled public String matchSummaryText;
        @AuraEnabled public String errorMessage;
        /** Equivalent of $Flow.FaultMessage when the action itself failed. */
        @AuraEnabled public String faultMessage;
        /** Structured rows for the datatable; null when they could not be built (UI falls back to the HTML). */
        @AuraEnabled public List<MatchRow> matches;
        /** "Plus N more not listed." from the duplicate check. */
        @AuraEnabled public Integer hiddenMatchCount = 0;
    }

    /** One possible match, re-read as the running user. */
    public class MatchRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String objectType;
        @AuraEnabled public String iconName;
        @AuraEnabled public String name;
        @AuraEnabled public String recordUrl;
        @AuraEnabled public String company;
        @AuraEnabled public String city;
        @AuraEnabled public String postalCode;
        @AuraEnabled public String status;
        @AuraEnabled public String owner;
        @AuraEnabled public String reason;

        public MatchRow(SObject record, String reason) {
            this.id = record.Id;
            this.reason = reason;
            if (record instanceof Lead) {
                Lead leadRecord = (Lead) record;
                this.objectType = 'Lead';
                this.iconName = 'standard:lead';
                this.name = leadRecord.Name;
                this.company = leadRecord.Company;
                this.city = leadRecord.City;
                this.postalCode = leadRecord.PostalCode;
                this.status = leadRecord.Status;
                this.owner = leadRecord.Owner?.Name;
            } else {
                Account accountRecord = (Account) record;
                this.objectType = 'Account';
                this.iconName = 'standard:account';
                this.name = accountRecord.Name;
                this.company = accountRecord.Name;
                this.city = accountRecord.BillingCity;
                this.postalCode = accountRecord.BillingPostalCode;
                this.owner = accountRecord.Owner?.Name;
            }
            this.recordUrl = '/lightning/r/' + this.objectType + '/' + this.id + '/view';
        }
    }

    /**
     * Matches one list item of LeadQuickEntryDuplicateCheck_CC.buildSummary:
     * <li><a href="/lightning/r/{Object}/{Id}/view" ...>name</a> (Object) details <em>reason</em></li>
     */
    private static final Pattern MATCH_ITEM = Pattern.compile(
        '<li><a href="/lightning/r/(Lead|Account)/([a-zA-Z0-9]{15,18})/view"[^>]*>.*?</a>.*?<em>(.*?)</em></li>'
    );
    private static final Pattern MATCH_OVERFLOW = Pattern.compile('Plus (\\d+) more not listed\\.');

    public class CreateResult {
        @AuraEnabled public Id leadId;
        @AuraEnabled public Boolean readable = false;
    }

    // ---- Entry points ------------------------------------------------------------------------

    /** Access check + Suggest_Entity. Suggestion failures fall through silently, as in the flow. */
    @AuraEnabled
    public static InitData getInitData() {
        InitData data = new InitData();
        data.hasAccess = hasAccess();
        if (data.hasAccess) {
            try {
                Object entity = invoker.invoke(ENTITY_DEFAULT_ACTION, new Map<String, Object>()).get('entityValue');
                data.suggestedEntity = entity == null ? null : String.valueOf(entity);
            } catch (Exception e) {
                data.suggestedEntity = null;
            }
        }
        return data;
    }

    /** Check_Duplicates. A failure of the action is returned (not thrown) so the UI can offer Retry/Back/Stop. */
    @AuraEnabled
    public static DuplicateCheckResult checkDuplicates(Lead candidate) {
        requireAccess();
        Lead clean = sanitize(candidate);
        DuplicateCheckResult result = new DuplicateCheckResult();
        try {
            Map<String, Object> output = invoker.invoke(
                DUPLICATE_CHECK_ACTION,
                new Map<String, Object>{ 'candidate' => clean }
            );
            result.isSuccess = asBoolean(output.get('isSuccess'));
            result.hasMatches = asBoolean(output.get('hasMatches'));
            result.matchCount = asDecimal(output.get('matchCount'));
            result.matchSummaryHtml = asString(output.get('matchSummaryHtml'));
            result.matchSummaryText = asString(output.get('matchSummaryText'));
            result.errorMessage = asString(output.get('errorMessage'));
        } catch (Exception e) {
            result.isSuccess = false;
            result.faultMessage = e.getMessage();
        }
        result.matches = buildMatchRows(result.matchSummaryHtml);
        result.hiddenMatchCount = hiddenMatchCount(result.matchSummaryHtml);
        return result;
    }

    /**
     * Turns the duplicate check's HTML list into rows for lightning-datatable. Only the record Ids and match
     * reasons are taken from the HTML; every displayed value is re-read WITH USER_MODE (the same fields the
     * duplicate check itself reads, so no extra field access is needed). Returns null if anything fails,
     * so the UI shows the original HTML instead.
     */
    @TestVisible
    private static List<MatchRow> buildMatchRows(String html) {
        if (String.isBlank(html)) {
            return new List<MatchRow>();
        }
        try {
            List<Id> orderedIds = new List<Id>();
            Map<Id, String> reasonById = new Map<Id, String>();
            Set<Id> leadIds = new Set<Id>();
            Set<Id> accountIds = new Set<Id>();

            Matcher item = MATCH_ITEM.matcher(html);
            while (item.find()) {
                Id recordId = Id.valueOf(item.group(2));
                if (reasonById.containsKey(recordId)) {
                    continue;
                }
                orderedIds.add(recordId);
                reasonById.put(recordId, item.group(3).unescapeHtml4());
                if (item.group(1) == 'Lead') {
                    leadIds.add(recordId);
                } else {
                    accountIds.add(recordId);
                }
            }
            if (orderedIds.isEmpty()) {
                return null; // HTML present but not in the expected shape
            }

            Map<Id, SObject> records = new Map<Id, SObject>();
            if (!leadIds.isEmpty()) {
                records.putAll([
                    SELECT Id, Name, Company, City, PostalCode, toLabel(Status), Owner.Name
                    FROM Lead
                    WHERE Id IN :leadIds
                    WITH USER_MODE
                ]);
            }
            if (!accountIds.isEmpty()) {
                records.putAll([
                    SELECT Id, Name, BillingCity, BillingPostalCode, Owner.Name
                    FROM Account
                    WHERE Id IN :accountIds
                    WITH USER_MODE
                ]);
            }

            List<MatchRow> rows = new List<MatchRow>();
            for (Id recordId : orderedIds) {
                SObject record = records.get(recordId);
                if (record != null) {
                    rows.add(new MatchRow(record, reasonById.get(recordId)));
                }
            }
            return rows;
        } catch (Exception e) {
            return null;
        }
    }

    @TestVisible
    private static Integer hiddenMatchCount(String html) {
        if (String.isBlank(html)) {
            return 0;
        }
        Matcher overflow = MATCH_OVERFLOW.matcher(html);
        return overflow.find() ? Integer.valueOf(overflow.group(1)) : 0;
    }

    /** Create_Lead + Get_Created_Lead (as running user). */
    @AuraEnabled
    public static CreateResult createLead(Lead candidate) {
        requireAccess();
        Lead toInsert = sanitize(candidate);
        try {
            Database.insert(toInsert, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            List<String> messages = new List<String>();
            for (Integer i = 0; i < e.getNumDml(); i++) {
                messages.add(e.getDmlMessage(i));
            }
            throw auraError(String.join(messages, ' '));
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
        CreateResult result = new CreateResult();
        result.leadId = toInsert.Id;
        result.readable = isReadable(toInsert.Id);
        return result;
    }

    /** Decide_Already_Created path: re-check readability without inserting again. */
    @AuraEnabled
    public static Boolean isLeadReadable(Id leadId) {
        requireAccess();
        return isReadable(leadId);
    }

    // ---- Helpers -----------------------------------------------------------------------------

    @TestVisible
    private static Boolean hasAccess() {
        if (Test.isRunningTest() && accessOverride != null) {
            return accessOverride;
        }
        return Schema.SObjectType.Lead.isCreateable();
    }

    private static void requireAccess() {
        if (!hasAccess()) {
            throw auraError(NO_ACCESS_MESSAGE);
        }
    }

    /** Copies only allow-listed fields, trims text, blanks become null, Status is forced to Identify. */
    @TestVisible
    private static Lead sanitize(Lead candidate) {
        if (candidate == null) {
            throw auraError('No Lead details were received.');
        }
        Lead clean = new Lead();
        for (Schema.SObjectField field : WRITABLE_FIELDS) {
            Object value = candidate.get(field);
            if (value instanceof String) {
                String text = ((String) value).trim();
                value = String.isBlank(text) ? null : text;
            }
            if (value != null) {
                clean.put(field, value);
            }
        }
        clean.Status = INITIAL_STATUS;
        return clean;
    }

    private static Boolean isReadable(Id leadId) {
        if (leadId == null) {
            return false;
        }
        try {
            return ![SELECT Id FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1].isEmpty();
        } catch (Exception e) {
            return false; // flow fault connector goes to the "no access" screen
        }
    }

    private static Boolean asBoolean(Object value) {
        return value == null ? false : Boolean.valueOf(value);
    }

    private static Decimal asDecimal(Object value) {
        return value == null ? null : Decimal.valueOf(String.valueOf(value));
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    // ---- Invocable action plumbing -----------------------------------------------------------

    public interface ActionInvoker {
        Map<String, Object> invoke(String actionName, Map<String, Object> inputs);
    }

    public class ActionException extends Exception {}

    /** Calls an Apex invocable action by name (Invocable.Action, API 60+). */
    public class InvocableActionInvoker implements ActionInvoker {
        public Map<String, Object> invoke(String actionName, Map<String, Object> inputs) {
            Invocable.Action action = Invocable.Action.createCustomAction('apex', actionName);
            for (String name : inputs.keySet()) {
                action.setInvocationParameter(name, inputs.get(name));
            }
            List<Invocable.Action.Result> results = action.invoke();
            if (results == null || results.isEmpty()) {
                throw new ActionException('The action ' + actionName + ' returned no result.');
            }
            Invocable.Action.Result result = results[0];
            if (!result.isSuccess()) {
                List<String> messages = new List<String>();
                for (Invocable.Action.Error err : result.getErrors()) {
                    messages.add(err.getMessage());
                }
                throw new ActionException(String.join(messages, ' '));
            }
            Map<String, Object> output = result.getOutputParameters();
            return output == null ? new Map<String, Object>() : output;
        }
    }
}