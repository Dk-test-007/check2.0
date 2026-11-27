/**
 * Server side of the Record Meeting Outcome card (leadMeetingOutcome_CC and its popup leadMeetingOutcomeModal_CC).
 *
 * Returns the fields a Lead needs before it can enter an outcome stage: Qualified, Disqualified or Re-Nurture. They are
 * read from the Lead stage metadata (Lead_Stage_Field_CC__mdt) through LeadStageTransitionService_CC, the same source
 * the Lead trigger validates against, so the popup asks for exactly what the save will enforce. Adding or removing a
 * required field in the metadata changes the popup with no code change.
 *
 *   - Only the target stage's own requirements are returned (pre-filled with the Lead's current values). Earlier
 *     stages' requirements are not asked here; the Lead trigger still enforces them on save.
 *   - Status, Meeting Outcome and Meeting Outcome Sub Reason are set by the card itself and never asked for here.
 *
 * Nothing is saved here: the card saves through Lightning Data Service, so sharing, field-level security and the Lead
 * trigger apply exactly as for a record page save.
 */
public with sharing class LeadMeetingOutcomeController_CC {

    /** Lead_Stage_CC__mdt record names the card can move a Lead to. */
    @TestVisible
    private static final Set<String> TARGET_STAGES = new Set<String>{ 'Qualified', 'Disqualified', 'Re_Nurture' };

    /**
     * Fields the card or the Lead trigger sets itself; a requirement made only of these is not shown in the popup.
     * Product_Category_Text_CC__c is filled by the trigger from Product Category on save.
     */
    @TestVisible
    private static final Set<String> CARD_FIELDS = new Set<String>{
        'Status', 'Meeting_Outcome_CC__c', 'Meeting_Outcome_Sub_Reason_CC__c', 'Product_Category_Text_CC__c'
    };

    /** What the popup renders for one target stage. */
    public class OutcomeForm {
        /** The Lead Status the card sets (Lead_Stage_CC__mdt.Status_Value_CC__c). */
        @AuraEnabled public String targetStatus;
        @AuraEnabled public List<Requirement> requirements = new List<Requirement>();
        /** Current Lead value of every field the requirements list or test, for the fields the user can read. */
        @AuraEnabled public Map<String, Object> values = new Map<String, Object>();
        /** The Lead trigger's message when a move into Qualified is blocked as a duplicate, so the popup can spot it. */
        @AuraEnabled public String duplicateError = LeadStageTransitionService_CC.DUPLICATE_ERROR;
    }

    /** Records the Lead matches under the active duplicate rules, as the popup lists them. */
    public class DuplicateCheck {
        @AuraEnabled public List<DuplicateMatch> matches = new List<DuplicateMatch>();
        /** More matches exist than are listed. */
        @AuraEnabled public Boolean moreMatches = false;
        /** True when the user can tick Bypass_Duplicate_Rules_on_Qualification__c. */
        @AuraEnabled public Boolean canBypass = false;
        /** Bypass_Duplicate_Rules_on_Qualification__c is already ticked on the Lead, so the move will not be blocked. */
        @AuraEnabled public Boolean bypassed = false;
    }

    public class DuplicateMatch {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public String objectLabel;
    }

    @TestVisible
    private static final Integer MAX_DUPLICATE_MATCHES = 10;

    /** One Lead_Stage_Field_CC__mdt record, as the popup needs it. */
    public class Requirement {
        @AuraEnabled public String key;
        @AuraEnabled public List<String> fieldNames;
        /** How many of fieldNames must be filled (blank in the metadata = 1). */
        @AuraEnabled public Integer minimumRequired;
        /** When set, the requirement applies only while conditionField equals conditionValue. */
        @AuraEnabled public String conditionField;
        @AuraEnabled public String conditionValue;
        @AuraEnabled public String message;
        /** Always true: only the target stage's own requirements are returned. */
        @AuraEnabled public Boolean ownStage;
    }

    /**
     * @param leadId the Lead the card is on
     * @param targetStage Lead_Stage_CC__mdt record name: Qualified, Disqualified or Re_Nurture
     * @return the target Status, the requirements to show and the Lead's current values
     */
    @AuraEnabled
    public static OutcomeForm getOutcomeForm(Id leadId, String targetStage) {
        if (leadId == null || leadId.getSObjectType() != Lead.SObjectType) {
            throw newAuraException('Open this from a Lead record.');
        }
        if (!TARGET_STAGES.contains(targetStage)) {
            throw newAuraException('Unknown outcome stage: ' + targetStage + '.');
        }
        String targetStatus = LeadStageTransitionService_CC.statusOf(targetStage);
        if (targetStatus == null) {
            throw newAuraException('The Lead stage ' + targetStage + ' is not defined in Lead Stage metadata.');
        }

        // Only fields the user can read are queried, shown or returned. A requirement on a field the user cannot read
        // cannot be filled here either; the Lead trigger still enforces it on save and names it in the error.
        List<Requirement> candidates = new List<Requirement>();
        Set<String> fieldNames = new Set<String>();
        for (Lead_Stage_Field_CC__mdt rule : LeadStageTransitionService_CC.requiredFieldsFor(targetStatus)) {
            // Only the target stage's own requirements are asked. Earlier stages' requirements were met to reach this
            // stage; any that are not are still enforced by the Lead trigger on save.
            if (LeadStageTransitionService_CC.statusOf(rule.Lead_Stage_CC__r.DeveloperName) != targetStatus) {
                continue;
            }
            List<String> askFields = readable(formFieldsOf(rule));
            if (askFields.isEmpty()) {
                continue;
            }
            String conditionField = String.isBlank(rule.Condition_Field_CC__c) ? null : rule.Condition_Field_CC__c.trim();
            fieldNames.addAll(askFields);
            if (conditionField != null && isReadable(conditionField)) {
                fieldNames.add(conditionField);
            }
            candidates.add(toRequirement(rule, askFields, true));
        }

        OutcomeForm form = new OutcomeForm();
        form.targetStatus = targetStatus;
        Lead leadRecord = queryLead(leadId, fieldNames);
        form.requirements.addAll(candidates);
        for (String fieldName : fieldNames) {
            form.values.put(fieldName, leadRecord.get(fieldName));
        }
        return form;
    }

    /**
     * The records the saved Lead matches under the active duplicate rules: the same check the Lead trigger runs on
     * entry to Qualified (LeadStageTransitionService_CC), so the popup can warn before the save is blocked. Matches
     * the user cannot see are not listed. A duplicate-rule failure returns no matches; the trigger still decides on save.
     * @param leadId the Lead the card is on
     */
    @AuraEnabled
    public static DuplicateCheck getDuplicateCheck(Id leadId) {
        if (leadId == null || leadId.getSObjectType() != Lead.SObjectType) {
            throw newAuraException('Open this from a Lead record.');
        }
        DuplicateCheck check = new DuplicateCheck();
        check.canBypass = Schema.SObjectType.Lead.fields.Bypass_Duplicate_Rules_on_Qualification__c.isUpdateable();
        if (isReadable('Bypass_Duplicate_Rules_on_Qualification__c')) {
            Lead leadRecord = queryLead(leadId, new Set<String>{ 'Bypass_Duplicate_Rules_on_Qualification__c' });
            check.bypassed = leadRecord.Bypass_Duplicate_Rules_on_Qualification__c;
        }

        Map<Schema.SObjectType, Set<Id>> idsByType = new Map<Schema.SObjectType, Set<Id>>();
        List<Id> orderedIds = new List<Id>();
        try {
            for (Datacloud.FindDuplicatesResult result : Datacloud.FindDuplicatesByIds.findDuplicatesByIds(new List<Id>{ leadId })) {
                for (Datacloud.DuplicateResult duplicateResult : result.getDuplicateResults()) {
                    for (Datacloud.MatchResult matchResult : duplicateResult.getMatchResults()) {
                        for (Datacloud.MatchRecord matchRecord : matchResult.getMatchRecords()) {
                            Id matchId = matchRecord.getRecord() == null ? null : matchRecord.getRecord().Id;
                            if (matchId == null || matchId == leadId || orderedIds.contains(matchId)) {
                                continue;
                            }
                            orderedIds.add(matchId);
                            if (!idsByType.containsKey(matchId.getSObjectType())) {
                                idsByType.put(matchId.getSObjectType(), new Set<Id>());
                            }
                            idsByType.get(matchId.getSObjectType()).add(matchId);
                        }
                    }
                }
            }
        } catch (Exception e) {
            // No active duplicate rule for Lead, or the rules could not run: nothing to warn about here.
            return check;
        }

        // Names of the matches the user can see (with sharing, user mode).
        Map<Id, String> nameById = new Map<Id, String>();
        Map<Id, String> labelById = new Map<Id, String>();
        for (Schema.SObjectType objectType : idsByType.keySet()) {
            Schema.DescribeSObjectResult describe = objectType.getDescribe();
            if (!describe.isAccessible()) {
                continue;
            }
            Set<Id> ids = idsByType.get(objectType);
            String nameField = describe.fields.getMap().containsKey('name') ? 'Name' : 'Id';
            String soql = 'SELECT Id' + (nameField == 'Name' ? ', Name' : '') + ' FROM ' + describe.getName()
                + ' WHERE Id IN :ids WITH USER_MODE';
            for (SObject record : Database.query(soql)) {
                nameById.put(record.Id, String.valueOf(record.get(nameField)));
                labelById.put(record.Id, describe.getLabel());
            }
        }
        for (Id matchId : orderedIds) {
            if (!nameById.containsKey(matchId)) {
                continue;
            }
            if (check.matches.size() == MAX_DUPLICATE_MATCHES) {
                check.moreMatches = true;
                break;
            }
            DuplicateMatch match = new DuplicateMatch();
            match.recordId = matchId;
            match.name = nameById.get(matchId);
            match.objectLabel = labelById.get(matchId);
            check.matches.add(match);
        }
        return check;
    }

    // ---------------------------------------------------------------- helpers

    /** The fields of a requirement the popup asks for: all of them except those the card sets itself. */
    private static List<String> formFieldsOf(Lead_Stage_Field_CC__mdt rule) {
        List<String> fieldNames = new List<String>();
        for (String fieldName : LeadStageTransitionService_CC.fieldNamesOf(rule)) {
            if (!CARD_FIELDS.contains(fieldName)) {
                fieldNames.add(fieldName);
            }
        }
        return fieldNames;
    }

    private static List<String> readable(List<String> fieldNames) {
        List<String> result = new List<String>();
        for (String fieldName : fieldNames) {
            if (isReadable(fieldName)) {
                result.add(fieldName);
            }
        }
        return result;
    }

    private static Map<String, Schema.SObjectField> leadFieldMap;

    private static Boolean isReadable(String fieldName) {
        if (leadFieldMap == null) {
            leadFieldMap = Schema.SObjectType.Lead.fields.getMap();
        }
        Schema.SObjectField field = leadFieldMap.get(fieldName);
        return field != null && field.getDescribe().isAccessible();
    }

    private static Requirement toRequirement(Lead_Stage_Field_CC__mdt rule, List<String> askFields, Boolean ownStage) {
        Requirement requirement = new Requirement();
        requirement.key = rule.DeveloperName;
        requirement.fieldNames = askFields;
        requirement.minimumRequired = rule.Minimum_Required_CC__c == null ? 1 : rule.Minimum_Required_CC__c.intValue();
        requirement.conditionField = String.isBlank(rule.Condition_Field_CC__c) ? null : rule.Condition_Field_CC__c.trim();
        requirement.conditionValue = rule.Condition_Value_CC__c;
        requirement.message = rule.Error_Message_CC__c;
        requirement.ownStage = ownStage;
        return requirement;
    }

    /** Reads the Lead with the given (readable) fields. Record access follows sharing (with sharing class). */
    private static Lead queryLead(Id leadId, Set<String> fieldNames) {
        Set<String> selected = new Set<String>{ 'Id', 'Status' };
        selected.addAll(fieldNames);
        List<Lead> leads = Database.query(
            'SELECT ' + String.join(new List<String>(selected), ', ') + ' FROM Lead WHERE Id = :leadId LIMIT 1'
        );
        if (leads.isEmpty()) {
            throw newAuraException('This Lead was not found or you do not have access to it.');
        }
        return leads[0];
    }

    /** AuraHandledException whose getMessage() also returns the text, so tests can assert on it. */
    private static AuraHandledException newAuraException(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}