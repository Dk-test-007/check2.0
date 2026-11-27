/**
 * Server side of the Lead UI pilot Return to Engage action (side panel on Lead_Pilot_Record_Page_CC, shown at Re-Nurture).
 *
 * Moves a Re-Nurture Lead back to Engage with one Status-only update, so the Lead trigger and the deployed rules
 * decide as they would for any other save. Everything is checked here, not only by page visibility:
 *   - the existing Sales authorisation used for outcomes (Sales_User_Permission_CC, the Lead validation bypass
 *     setting or the System Administrator profile), so Marketing stays excluded as for Disqualify;
 *   - edit access to the Lead and to Status;
 *   - the Lead is unconverted and at Re-Nurture;
 *   - the Engage gate of LeadStageTransitionService_CC (the same inputs the pilot needs to auto-advance into Engage).
 * The save then runs in user mode: record sharing and field access apply, and the Engage validation rules apply.
 * There is no duplicate check on entry to Engage: the trigger's duplicate checkpoint runs on entry to Qualified.
 * Duplicate rules keep their configured action: an Allow rule's alert does not block (as on the record page), a
 * Block rule still blocks. Neither duplicate-bypass field is set here.
 *
 * Re-Nurture Reason, Comments and Re-engagement Date are left as they are, so the earlier Re-Nurture details stay on
 * the record; Status history records the move. Owner is not changed.
 */
public with sharing class LeadReturnToEngageAction_CC {

    public static final String STATUS_RE_NURTURE = 'Re-Nurture';
    public static final String STATUS_ENGAGE = 'Engage';

    @TestVisible private static final String NOT_SALES = 'Only Sales users can return a Lead to Engage. Ask a Sales user to do it.';
    @TestVisible private static final String NO_ACCESS = 'You do not have access to edit this Lead.';
    @TestVisible private static final String NO_FIELD_ACCESS = 'You do not have edit access to the Lead Status.';
    @TestVisible private static final String CONVERTED = 'This Lead is converted and cannot return to Engage.';
    @TestVisible private static final String NOT_RE_NURTURE = 'Only a Lead at Re-Nurture can return to Engage.';
    @TestVisible private static final String GAPS_PREFIX = 'Before returning to Engage, complete: ';
    @TestVisible private static final String DUPLICATE_MESSAGE = 'This Lead matches an existing record, so it cannot return '
        + 'to Engage. Review the possible duplicates. If it is not a duplicate, tick "'
        + Lead.Bypass_Duplicate_Rules_on_Qualification__c.getDescribe().getLabel() + '" on Additional Details, then try again.';

    private static final String OUTCOME_PERMISSION = 'Sales_User_Permission_CC';
    private static final String ADMIN_PROFILE = 'System Administrator';

    /** What the panel needs to render: whether the user may return this Lead to Engage now, and why not. */
    public class Context {
        @AuraEnabled public Boolean canReturn = false;
        @AuraEnabled public String message;
        @AuraEnabled public String status;
        @AuraEnabled public String company;
    }

    /**
     * Eligibility for the panel. Never throws for an ineligible Lead; explains why instead.
     * @param leadId the Lead shown on the page
     * @return panel context
     */
    @AuraEnabled
    public static Context getContext(Id leadId) {
        Context context = new Context();
        Lead leadRecord = visibleLead(leadId, false);
        if (leadRecord != null) {
            context.status = leadRecord.Status;
            context.company = leadRecord.Company;
        }
        context.message = userProblem();
        if (context.message == null) {
            context.message = recordProblem(leadRecord);
        }
        context.canReturn = context.message == null;
        return context;
    }

    /**
     * Returns the Lead to Engage after re-checking every rule. Nothing is written when any check fails.
     * @param leadId the Re-Nurture Lead
     * @throws AuraHandledException with a user-readable message when a rule is not met or the save fails
     */
    @AuraEnabled
    public static void returnToEngage(Id leadId) {
        String problem = userProblem();
        if (problem == null) {
            problem = recordProblem(visibleLead(leadId, true));
        }
        if (problem != null) {
            throw userError(problem);
        }
        Database.DMLOptions options = new Database.DMLOptions();
        // Duplicate rules keep their own action (Allow alerts do not block; Block rules do). The trigger's duplicate
        // checkpoint runs on entry to Qualified, not here.
        options.DuplicateRuleHeader.allowSave = true;
        options.OptAllOrNone = true;
        try {
            Database.update(new Lead(Id = leadId, Status = STATUS_ENGAGE), options, AccessLevel.USER_MODE);
        } catch (DmlException ex) {
            String message = ex.getDmlMessage(0);
            throw userError(message != null && message.contains(LeadStageTransitionService_CC.DUPLICATE_ERROR)
                ? DUPLICATE_MESSAGE : message);
        }
    }

    // ---------------------------------------------------------------- checks

    private static String userProblem() {
        if (!isOutcomePermitted()) {
            return NOT_SALES;
        }
        return Lead.Status.getDescribe().isUpdateable() ? null : NO_FIELD_ACCESS;
    }

    @TestVisible
    private static String recordProblem(Lead leadRecord) {
        if (leadRecord == null) {
            return NO_ACCESS;
        }
        if (leadRecord.IsConverted) {
            return CONVERTED;
        }
        if (leadRecord.Status != STATUS_RE_NURTURE) {
            return NOT_RE_NURTURE;
        }
        if (!hasEditAccess(leadRecord.Id)) {
            return NO_ACCESS;
        }
        List<String> gaps = LeadStageTransitionService_CC.engageGaps(gateInputs(leadRecord.Id));
        return gaps.isEmpty() ? null : GAPS_PREFIX + String.join(gaps, '; ') + '.';
    }

    /** Mirrors the exemptions of Lead_Progression_Validation_CC and LeadStageTransitionService_CC. */
    private static Boolean isOutcomePermitted() {
        Trigger_Framework_Config_CC__mdt config = Trigger_Framework_Config_CC__mdt.getInstance('Lead');
        return FeatureManagement.checkPermission(OUTCOME_PERMISSION)
            || (config != null && config.Bypass_Validation_CC__c)
            || [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() WITH SYSTEM_MODE].Name == ADMIN_PROFILE;
    }

    // ---------------------------------------------------------------- data

    /** The Lead as the running user sees it (sharing and field access applied); null when not visible. */
    private static Lead visibleLead(Id leadId, Boolean lockRow) {
        if (leadId == null || leadId.getSObjectType() != Lead.SObjectType) {
            return null;
        }
        List<Lead> leads = lockRow
            ? [SELECT Id, Status, IsConverted, Company FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1 FOR UPDATE]
            : [SELECT Id, Status, IsConverted, Company FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1];
        return leads.isEmpty() ? null : leads[0];
    }

    /**
     * The inputs of the Engage gate. System mode so a field the user cannot read does not fail the check; only the
     * missing fields' labels are returned, never their values, and the record is already confirmed visible and editable.
     * The fields come from the Lead stage metadata (LeadStageTransitionService_CC.metadataFieldNames), so a field added
     * to the metadata is queried without a code change.
     */
    private static Lead gateInputs(Id leadId) {
        Set<String> fieldNames = new Set<String>{ 'id', 'lastname', 'status' };
        for (String fieldName : LeadStageTransitionService_CC.metadataFieldNames()) {
            fieldNames.add(fieldName.toLowerCase());
        }
        return Database.query(
            'SELECT ' + String.join(new List<String>(fieldNames), ', ')
            + ' FROM Lead WHERE Id = :leadId WITH SYSTEM_MODE LIMIT 1'
        );
    }

    private static Boolean hasEditAccess(Id leadId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :leadId
            WITH SYSTEM_MODE
        ];
        return !access.isEmpty() && access[0].HasEditAccess;
    }

    private static AuraHandledException userError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}