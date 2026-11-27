/**
 * Server side of the Lead UI pilot Disqualify action (side panel on Lead_Pilot_Record_Page_CC).
 *
 * One call validates and saves Status, reason and comments in a single all-or-nothing update, so the
 * existing Lead trigger automation runs once. Everything is enforced here, not only by page visibility,
 * so a direct call gets the same answer:
 *   - no Sales-only restriction: Sales and Marketing users can both disqualify;
 *   - edit access to the Lead and edit access to Status, Disqualified Reason and Disqualification Comments;
 *   - the Lead is unconverted and at Identify, Qualify or Engage;
 *   - an active Disqualified Reason, and comments when the reason is Other.
 * Positive qualification inputs are deliberately not required.
 *
 * Disqualified_By_Pilot_Action_CC__c marks the save. Users have no edit access to it; it is set here only,
 * and Disqualification_Stage_Validation_CC accepts Identify -> Disqualified for a named contact only when it
 * changes in the same save. Other routes keep their deployed rules.
 */
public with sharing class LeadDisqualifyAction_CC {

    public static final String STATUS_DISQUALIFIED = 'Disqualified';
    public static final String REASON_OTHER = 'Other';
    public static final Set<String> ACTIVE_STATUSES = new Set<String>{ 'Identify', 'Qualify', 'Engage' };

    @TestVisible private static final String NO_ACCESS = 'You do not have access to edit this Lead.';
    @TestVisible private static final String NO_FIELD_ACCESS = 'You do not have edit access to the Lead Status, Disqualified Reason or Disqualification Comments.';
    @TestVisible private static final String CONVERTED = 'This Lead is converted and cannot be disqualified.';
    @TestVisible private static final String NOT_ACTIVE = 'Only a Lead at Identify, Qualify or Engage can be disqualified here.';
    @TestVisible private static final String REASON_REQUIRED = 'Choose a Disqualified Reason.';
    @TestVisible private static final String REASON_INVALID = 'Choose an active Disqualified Reason from the list.';
    @TestVisible private static final String COMMENTS_REQUIRED = 'Enter Disqualification Comments when the reason is Other.';
    @TestVisible private static final String COMMENTS_TOO_LONG = 'Disqualification Comments are too long.';

    /** What the panel needs to render: whether the user may disqualify this Lead now and the reason choices. */
    public class Context {
        @AuraEnabled public Boolean canDisqualify = false;
        @AuraEnabled public String message;
        @AuraEnabled public String status;
        @AuraEnabled public String company;
        @AuraEnabled public String currentReason;
        @AuraEnabled public String currentComments;
        @AuraEnabled public String otherReasonValue = REASON_OTHER;
        @AuraEnabled public Integer commentsMaxLength;
        @AuraEnabled public List<Option> reasons = new List<Option>();
    }

    /** A Disqualified Reason picklist choice. */
    public class Option {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        Option(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    /**
     * Eligibility and choices for the panel. Never throws for an ineligible Lead; explains why instead.
     * @param leadId the Lead shown on the page
     * @return panel context
     */
    @AuraEnabled
    public static Context getContext(Id leadId) {
        Context context = new Context();
        context.commentsMaxLength = Lead.Disqualification_Comments_CC__c.getDescribe().getLength();
        context.reasons = activeReasons();
        Lead leadRecord = visibleLead(leadId, false);
        if (leadRecord != null) {
            context.status = leadRecord.Status;
            context.company = leadRecord.Company;
            context.currentReason = leadRecord.Disqualified_Reason_CC__c;
            context.currentComments = leadRecord.Disqualification_Comments_CC__c;
        }
        context.message = userProblem();
        if (context.message == null) {
            context.message = recordProblem(leadRecord);
        }
        context.canDisqualify = context.message == null;
        return context;
    }

    /**
     * Disqualifies the Lead after re-checking every rule. Nothing is written when any check fails.
     * @param leadId the Lead to disqualify
     * @param reason an active Disqualified Reason value
     * @param comments Disqualification Comments (required when reason is Other); saved as entered
     * @throws AuraHandledException with a user-readable message when a rule is not met or the save fails
     */
    @AuraEnabled
    public static void disqualify(Id leadId, String reason, String comments) {
        String problem = userProblem();
        if (problem == null) {
            problem = inputProblem(reason, comments);
        }
        if (problem == null) {
            problem = recordProblem(visibleLead(leadId, true));
        }
        if (problem != null) {
            throw userError(problem);
        }
        Lead change = new Lead(
            Id = leadId,
            Status = STATUS_DISQUALIFIED,
            Disqualified_Reason_CC__c = reason,
            Disqualification_Comments_CC__c = String.isBlank(comments) ? null : comments.trim(),
            Disqualified_By_Pilot_Action_CC__c = true
        );
        try {
            // System mode only to set the action marker, which users cannot edit. Record edit access and
            // field edit access for the user-entered values were checked above.
            Database.update(change, true, AccessLevel.SYSTEM_MODE);
        } catch (DmlException ex) {
            throw userError(ex.getDmlMessage(0));
        }
    }

    // ---------------------------------------------------------------- checks

    private static String userProblem() {
        DescribeFieldResult status = Lead.Status.getDescribe();
        DescribeFieldResult reason = Lead.Disqualified_Reason_CC__c.getDescribe();
        DescribeFieldResult comments = Lead.Disqualification_Comments_CC__c.getDescribe();
        if (!status.isUpdateable() || !reason.isUpdateable() || !comments.isUpdateable()) {
            return NO_FIELD_ACCESS;
        }
        return null;
    }

    private static String inputProblem(String reason, String comments) {
        if (String.isBlank(reason)) {
            return REASON_REQUIRED;
        }
        Boolean known = false;
        for (Option option : activeReasons()) {
            known = known || option.value == reason;
        }
        if (!known) {
            return REASON_INVALID;
        }
        if (reason == REASON_OTHER && String.isBlank(comments)) {
            return COMMENTS_REQUIRED;
        }
        if (comments != null && comments.trim().length() > Lead.Disqualification_Comments_CC__c.getDescribe().getLength()) {
            return COMMENTS_TOO_LONG;
        }
        return null;
    }

    @TestVisible
    private static String recordProblem(Lead leadRecord) {
        if (leadRecord == null) {
            return NO_ACCESS;
        }
        if (leadRecord.IsConverted) {
            return CONVERTED;
        }
        if (!ACTIVE_STATUSES.contains(leadRecord.Status)) {
            return NOT_ACTIVE;
        }
        return hasEditAccess(leadRecord.Id) ? null : NO_ACCESS;
    }

    // ---------------------------------------------------------------- data

    /** The Lead as the running user sees it (sharing and field access applied); null when not visible. */
    private static Lead visibleLead(Id leadId, Boolean lockRow) {
        if (leadId == null || leadId.getSObjectType() != Lead.SObjectType) {
            return null;
        }
        List<Lead> leads = lockRow
            ? [SELECT Id, Status, IsConverted, Company, Disqualified_Reason_CC__c, Disqualification_Comments_CC__c
               FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1 FOR UPDATE]
            : [SELECT Id, Status, IsConverted, Company, Disqualified_Reason_CC__c, Disqualification_Comments_CC__c
               FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1];
        return leads.isEmpty() ? null : leads[0];
    }

    private static Boolean hasEditAccess(Id leadId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :leadId
            WITH SYSTEM_MODE
        ];
        return !access.isEmpty() && access[0].HasEditAccess;
    }

    private static List<Option> activeReasons() {
        List<Option> options = new List<Option>();
        for (Schema.PicklistEntry entry : Lead.Disqualified_Reason_CC__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                options.add(new Option(entry.getLabel(), entry.getValue()));
            }
        }
        return options;
    }

    private static AuraHandledException userError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}