/**
 * Server side of the Lead UI pilot reactivation card (side panel on Lead_Pilot_Record_Page_CC):
 *   - Restart at Identify, offered at Re-Nurture: a full reassessment in a new lifecycle cycle;
 *   - Confirm identity review (at Identify) and Confirm qualification review (at Qualify) for a restarted Lead.
 *
 * Who may restart (UI2 assumption, 29 Oct 2026, not an agreed client policy): any user who can edit the
 * Lead and its Status, so Marketing and Sales users both qualify. The deployed rules already allow
 * Re-Nurture -> Identify for every user; the Sales-only rule for Disqualify and Return to Engage is not changed.
 *
 * Every check runs here, not only in page visibility: Status and field edit access, record
 * visibility (WITH USER_MODE), UserRecordAccess edit access, unconverted and the expected Status, re-checked under a
 * row lock on confirm. The save itself is a USER_MODE update: sharing, field access, validation rules and the Lead
 * trigger apply. The trigger (LeadLifecycleCycle_CC) logs the restart and resets the cycle-specific values. The owner,
 * a Marketing user or pool queue after Re-Nurture, is not changed.
 */
public with sharing class LeadRestartAtIdentifyAction_CC {

    public static final String STATUS_RE_NURTURE = 'Re-Nurture';
    public static final String STATUS_IDENTIFY = 'Identify';
    public static final String STATUS_QUALIFY = 'Qualify';
    public static final String REVIEW_IDENTITY = 'identity';
    public static final String REVIEW_QUALIFICATION = 'qualification';

    @TestVisible private static final String NO_ACCESS = 'You do not have access to edit this Lead.';
    @TestVisible private static final String NO_FIELD_ACCESS = 'You do not have edit access to the fields this action changes.';
    @TestVisible private static final String CONVERTED = 'This Lead is converted and cannot be restarted.';
    @TestVisible private static final String NOT_RE_NURTURE = 'Only a Lead at Re-Nurture can be restarted at Qualify.';
    @TestVisible private static final String NOTE_REQUIRED = 'Enter why the Lead is being restarted.';
    @TestVisible private static final String NO_REVIEW = 'There is no review to confirm for this Lead at its current stage.';
    @TestVisible private static final String UNKNOWN_REVIEW = 'Unknown review.';

    private static final Integer NOTE_LENGTH = 500;

    /** What the card needs to render. */
    public class Context {
        @AuraEnabled public Boolean canRestart = false;
        @AuraEnabled public String restartMessage;
        @AuraEnabled public String pendingReview;
        @AuraEnabled public Boolean canConfirm = false;
        @AuraEnabled public String reviewMessage;
        @AuraEnabled public String status;
        @AuraEnabled public String company;
        @AuraEnabled public Integer cycle;
        @AuraEnabled public Boolean ownedByQueue = false;
    }

    /**
     * Card context. Never throws for an ineligible Lead; explains why instead.
     * @param leadId the Lead shown on the page
     * @return card context
     */
    @AuraEnabled
    public static Context getContext(Id leadId) {
        Context context = new Context();
        Lead leadRecord = visibleLead(leadId, false);
        String userProblem = userProblem(new List<Schema.SObjectField>{ Lead.Status });
        if (leadRecord != null) {
            context.status = leadRecord.Status;
            context.company = leadRecord.Company;
            context.cycle = LeadLifecycleCycle_CC.cycleOf(leadRecord);
            context.ownedByQueue = leadRecord.OwnerId != null && leadRecord.OwnerId.getSObjectType() == Group.SObjectType;
        }
        if (leadRecord != null && leadRecord.Status == STATUS_RE_NURTURE) {
            context.restartMessage = userProblem != null ? userProblem : restartProblem(leadRecord);
            context.canRestart = context.restartMessage == null;
        }
        context.pendingReview = pendingReview(leadRecord);
        if (context.pendingReview != null) {
            context.reviewMessage = userProblem(new List<Schema.SObjectField>{ reviewField(context.pendingReview) });
            if (context.reviewMessage == null) {
                context.reviewMessage = editProblem(leadRecord);
            }
            context.canConfirm = context.reviewMessage == null;
        }
        return context;
    }

    /**
     * Restarts a Re-Nurture Lead at Qualify after re-checking every rule under a row lock. Nothing is written when a
     * check fails, so a stale confirmation (the Lead was already restarted or returned) is rejected.
     * @param leadId the Re-Nurture Lead
     * @param note why the Lead is being restarted (kept in Lifecycle History)
     * @throws AuraHandledException with a user-readable message
     */
    @AuraEnabled
    public static void restart(Id leadId, String note) {
        String problem = userProblem(new List<Schema.SObjectField>{ Lead.Status });
        if (problem == null && String.isBlank(note)) {
            problem = NOTE_REQUIRED;
        }
        if (problem == null) {
            Lead leadRecord = visibleLead(leadId, true);
            problem = leadRecord == null ? NO_ACCESS : restartProblem(leadRecord);
        }
        if (problem != null) {
            throw userError(problem);
        }
        LeadLifecycleCycle_CC.noteRestart(leadId, note.trim().left(NOTE_LENGTH));
        // The restarted Lead resumes at Qualify (Identify details are kept); the qualification review still applies.
        save(new Lead(Id = leadId, Status = STATUS_QUALIFY));
    }

    /**
     * Confirms this cycle's identity (at Identify) or qualification (at Qualify) review. The same save lets the Lead
     * advance one stage when the rest of the stage gate is already met.
     * @param leadId the restarted Lead
     * @param review 'identity' or 'qualification'
     * @return the Status after the save
     * @throws AuraHandledException with a user-readable message
     */
    @AuraEnabled
    public static String confirmReview(Id leadId, String review) {
        Schema.SObjectField field = reviewField(review);
        if (field == null) {
            throw userError(UNKNOWN_REVIEW);
        }
        String problem = userProblem(new List<Schema.SObjectField>{ field });
        Lead leadRecord;
        if (problem == null) {
            leadRecord = visibleLead(leadId, true);
            problem = leadRecord == null ? NO_ACCESS : (pendingReview(leadRecord) != review ? NO_REVIEW : editProblem(leadRecord));
        }
        if (problem != null) {
            throw userError(problem);
        }
        Lead change = new Lead(Id = leadId);
        change.put(field, true);
        save(change);
        return [SELECT Status FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1].Status;
    }

    // ---------------------------------------------------------------- checks

    private static String userProblem(List<Schema.SObjectField> fields) {
        for (Schema.SObjectField field : fields) {
            if (!field.getDescribe().isUpdateable()) {
                return NO_FIELD_ACCESS;
            }
        }
        return null;
    }

    @TestVisible
    private static String restartProblem(Lead leadRecord) {
        if (leadRecord.IsConverted) {
            return CONVERTED;
        }
        if (leadRecord.Status != STATUS_RE_NURTURE) {
            return NOT_RE_NURTURE;
        }
        return hasEditAccess(leadRecord.Id) ? null : NO_ACCESS;
    }

    private static String editProblem(Lead leadRecord) {
        if (leadRecord.IsConverted) {
            return CONVERTED;
        }
        return hasEditAccess(leadRecord.Id) ? null : NO_ACCESS;
    }

    /** The review this Lead is waiting for at its current stage, or null. */
    private static String pendingReview(Lead leadRecord) {
        if (leadRecord == null || leadRecord.IsConverted) {
            return null;
        }
        if (leadRecord.Status == STATUS_IDENTIFY && LeadLifecycleCycle_CC.identityReviewPending(leadRecord)) {
            return REVIEW_IDENTITY;
        }
        if (leadRecord.Status == STATUS_QUALIFY && LeadLifecycleCycle_CC.qualificationReviewPending(leadRecord)) {
            return REVIEW_QUALIFICATION;
        }
        return null;
    }

    private static Schema.SObjectField reviewField(String review) {
        if (review == REVIEW_IDENTITY) {
            return Lead.Identity_Review_Confirmed_CC__c;
        }
        return review == REVIEW_QUALIFICATION ? Lead.Qualification_Review_Confirmed_CC__c : null;
    }

    // ---------------------------------------------------------------- data

    /**
     * The Lead as the running user sees it (sharing applied); null when not visible. The cycle fields are read in
     * system mode only after the record itself was confirmed visible, so a missing field permission cannot hide state.
     */
    private static Lead visibleLead(Id leadId, Boolean lockRow) {
        if (leadId == null || leadId.getSObjectType() != Lead.SObjectType) {
            return null;
        }
        List<Lead> visible = lockRow
            ? [SELECT Id FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1 FOR UPDATE]
            : [SELECT Id FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1];
        if (visible.isEmpty()) {
            return null;
        }
        return [
            SELECT Id, Status, IsConverted, Company, OwnerId, Lifecycle_Cycle_CC__c, Identity_Review_Confirmed_CC__c,
                   Qualification_Review_Confirmed_CC__c
            FROM Lead WHERE Id = :leadId WITH SYSTEM_MODE LIMIT 1
        ];
    }

    private static Boolean hasEditAccess(Id leadId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :leadId
            WITH SYSTEM_MODE
        ];
        return !access.isEmpty() && access[0].HasEditAccess;
    }

    private static void save(Lead change) {
        Database.DMLOptions options = new Database.DMLOptions();
        // Duplicate rules keep their own action, as on the record page; no bypass field is set here.
        options.DuplicateRuleHeader.allowSave = true;
        options.OptAllOrNone = true;
        try {
            Database.update(change, options, AccessLevel.USER_MODE);
        } catch (DmlException ex) {
            throw userError(ex.getDmlMessage(0));
        }
    }

    private static AuraHandledException userError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}