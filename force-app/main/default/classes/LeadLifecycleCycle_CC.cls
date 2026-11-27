/**
 * Lead lifecycle cycles for the Re-Nurture -> Identify reactivation loop. Called only from
 * LeadStageTransitionService_CC.apply (before update), which stays the single owner of automatic Status changes.
 *
 * A cycle is one pass through Identify -> Qualify -> Engage. Lifecycle_Cycle_CC__c is blank for the first pass.
 *
 * Restart at Identify (Re-Nurture -> Identify, normally through LeadRestartAtIdentifyAction_CC):
 *   - writes a history entry first: actor, time, note, the Re-Nurture reason/comments/date, meeting outcome and owner;
 *   - then resets only the cycle-specific controls: Meeting Outcome, the Re-Nurture reason/comments/date, the duplicate
 *     bypass and hold, and both review confirmations. Company, contact, address, qualification answers, appointment
 *     fields, activity and the owner are kept;
 *   - adds one to Lifecycle_Cycle_CC__c.
 * While the cycle is above 1, the identity review (confirmed at Identify) and the qualification review (confirmed at
 * Qualify) gate automatic progression (see LeadStageTransitionService_CC), explicit Status moves and conversion, for
 * every user. So old completed fields and an old outcome cannot skip the new cycle's reviews or make it convertible.
 *
 * Return to Engage (Re-Nurture -> Engage) keeps the established qualification and the Re-Nurture
 * details, as deployed, but clears the previous Meeting Outcome after logging it, so the new meeting needs a new outcome.
 *
 * Every entry to Re-Nurture is logged for every user, so repeated cycles keep each reason and comment
 * (Re-Nurture Reason and Comments are not field-history tracked). No SOQL or DML: bulk safe.
 */
public inherited sharing class LeadLifecycleCycle_CC {

    public static final String IDENTITY_REVIEW_GAP = 'the identity review for this cycle (Confirm identity review)';
    public static final String QUALIFICATION_REVIEW_GAP = 'the qualification review for this cycle (Confirm qualification review)';
    @TestVisible static final String IDENTITY_BLOCK = 'This Lead was restarted at Identify: confirm the identity review for '
        + 'this cycle before it moves past Identify.';
    @TestVisible static final String QUALIFICATION_BLOCK = 'This Lead was restarted at Identify: confirm the qualification '
        + 'review for this cycle at Qualify before it moves to Engage.';
    @TestVisible static final String CONVERSION_BLOCK = 'This Lead was restarted at Identify: confirm the identity and '
        + 'qualification reviews for this cycle before converting it.';
    @TestVisible static final String IDENTITY_WRONG_STAGE = 'Confirm the identity review while the Lead is at Identify.';
    @TestVisible static final String QUALIFICATION_WRONG_STAGE = 'Confirm the qualification review while the Lead is at Qualify.';

    @TestVisible static final String EVENT_RE_NURTURE = 'RE-NURTURE';
    @TestVisible static final String EVENT_RESTART = 'RESTART AT IDENTIFY';
    @TestVisible static final String EVENT_RETURN = 'RETURN TO ENGAGE';
    @TestVisible static final String EVENT_IDENTITY = 'IDENTITY REVIEW CONFIRMED';
    @TestVisible static final String EVENT_QUALIFICATION = 'QUALIFICATION REVIEW CONFIRMED';

    private static final String STATUS_IDENTIFY = 'Identify';
    private static final String STATUS_QUALIFY = 'Qualify';
    private static final String STATUS_ENGAGE = 'Engage';
    private static final String STATUS_QUALIFIED = 'Qualified';
    private static final String STATUS_RE_NURTURE = 'Re-Nurture';
    private static final Integer HISTORY_LENGTH = 32768;
    private static final Integer TEXT_LENGTH = 500;

    /** Restart notes from LeadRestartAtIdentifyAction_CC for the save in progress, by Lead Id. */
    private static Map<Id, String> restartNotes = new Map<Id, String>();

    /**
     * Records the user's reason for a restart about to be saved, for the history entry.
     * @param leadId the Lead being restarted
     * @param note the user's reason
     */
    public static void noteRestart(Id leadId, String note) {
        restartNotes.put(leadId, note);
    }

    /**
     * Cycle bookkeeping and enforcement for one before-update batch. Runs before automatic progression so the
     * reset controls and confirmations are what the gates see.
     * @param newLeads Trigger.new, modified in place
     * @param oldLeadMap Trigger.oldMap
     * @param bypassValidation the Lead validation bypass setting (data loads), which also bypasses the review checks
     */
    public static void apply(List<Lead> newLeads, Map<Id, Lead> oldLeadMap, Boolean bypassValidation) {
        for (Lead leadRecord : newLeads) {
            Lead oldLead = oldLeadMap.get(leadRecord.Id);
            if (oldLead == null) {
                continue;
            }
            Boolean statusChanged = leadRecord.Status != oldLead.Status;
            if (statusChanged && oldLead.Status == STATUS_RE_NURTURE
                && (leadRecord.Status == STATUS_IDENTIFY || leadRecord.Status == STATUS_QUALIFY)) {
                restart(leadRecord, oldLead);
            } else if (statusChanged && oldLead.Status == STATUS_RE_NURTURE && leadRecord.Status == STATUS_ENGAGE) {
                returnToEngage(leadRecord, oldLead);
            }
            if (cycleOf(leadRecord) > 1) {
                checkConfirmations(leadRecord, oldLead);
                if (!bypassValidation) {
                    enforceReviews(leadRecord, oldLead);
                }
            }
        }
        restartNotes.clear();
    }

    /**
     * Logs every entry to Re-Nurture, explicit or automatic, for every user. Runs after automatic progression, so an
     * Engage -> Re-Nurture move made by LeadStageTransitionService_CC in this save is included.
     * @param newLeads Trigger.new, modified in place
     * @param oldLeadMap Trigger.oldMap
     */
    public static void logDispositions(List<Lead> newLeads, Map<Id, Lead> oldLeadMap) {
        for (Lead leadRecord : newLeads) {
            Lead oldLead = oldLeadMap.get(leadRecord.Id);
            if (oldLead != null && leadRecord.Status == STATUS_RE_NURTURE && oldLead.Status != STATUS_RE_NURTURE) {
                log(leadRecord, EVENT_RE_NURTURE, cycleOf(leadRecord), 'from ' + oldLead.Status + '; ' + dispositionText(leadRecord)
                    + '; meeting outcome: ' + valueOrNone(leadRecord.Meeting_Outcome_CC__c) + '; owner: ' + leadRecord.OwnerId);
            }
        }
    }

    /** True when this cycle's identity review is still outstanding. Safe on partially queried Leads. */
    public static Boolean identityReviewPending(Lead leadRecord) {
        return cycleOf(leadRecord) > 1 && !isTrue(leadRecord, 'Identity_Review_Confirmed_CC__c');
    }

    /** True when this cycle's qualification review is still outstanding. Safe on partially queried Leads. */
    public static Boolean qualificationReviewPending(Lead leadRecord) {
        return cycleOf(leadRecord) > 1 && !isTrue(leadRecord, 'Qualification_Review_Confirmed_CC__c');
    }

    /** True when an earlier entry to Re-Nurture was logged, so the saved Re-Nurture values may be from that entry. */
    public static Boolean hasLoggedReNurture(Lead leadRecord) {
        Object history = populated(leadRecord, 'Lifecycle_History_CC__c');
        return history != null && ((String) history).contains('| ' + EVENT_RE_NURTURE + ' |');
    }

    /** The current cycle number; 1 when blank or not queried. */
    public static Integer cycleOf(Lead leadRecord) {
        Object cycle = populated(leadRecord, 'Lifecycle_Cycle_CC__c');
        return cycle == null ? 1 : Integer.valueOf(cycle);
    }

    // ---------------------------------------------------------------- transitions

    private static void restart(Lead leadRecord, Lead oldLead) {
        Integer nextCycle = cycleOf(oldLead) + 1;
        String note = restartNotes.get(leadRecord.Id);
        log(leadRecord, EVENT_RESTART, nextCycle, 'note: ' + valueOrNone(note == null ? null : note.left(TEXT_LENGTH))
            + '; previous ' + dispositionText(oldLead) + '; previous meeting outcome: ' + valueOrNone(oldLead.Meeting_Outcome_CC__c)
            + (oldLead.Bypass_Duplicate_Rules_on_Qualification__c ? '; duplicate confirmation cleared for a new check' : '')
            + '; owner kept: ' + leadRecord.OwnerId);
        leadRecord.Lifecycle_Cycle_CC__c = nextCycle;
        // The restart action resumes at Qualify because the saved Identify details remain valid.
        leadRecord.Identity_Review_Confirmed_CC__c = leadRecord.Status == STATUS_QUALIFY;
        leadRecord.Qualification_Review_Confirmed_CC__c = false;
        leadRecord.Meeting_Outcome_CC__c = null;
        leadRecord.Re_Nurture_Reason_CC__c = null;
        leadRecord.Re_Nurture_Comments_CC__c = null;
        leadRecord.Reengagement_Date_CC__c = null;
        leadRecord.Bypass_Duplicate_Rules_on_Qualification__c = false;
        leadRecord.Duplicate_Review_Required_CC__c = false;
    }

    private static void returnToEngage(Lead leadRecord, Lead oldLead) {
        log(leadRecord, EVENT_RETURN, cycleOf(leadRecord), 'Re-Nurture details kept; previous meeting outcome: '
            + valueOrNone(oldLead.Meeting_Outcome_CC__c)
            + (String.isBlank(oldLead.Meeting_Outcome_CC__c) ? '' : ' (cleared: record the new meeting outcome)'));
        leadRecord.Meeting_Outcome_CC__c = null;
    }

    // ---------------------------------------------------------------- reviews

    private static void checkConfirmations(Lead leadRecord, Lead oldLead) {
        if (leadRecord.Identity_Review_Confirmed_CC__c && !oldLead.Identity_Review_Confirmed_CC__c) {
            if (oldLead.Status != STATUS_IDENTIFY
                && !(oldLead.Status == STATUS_RE_NURTURE && leadRecord.Status == STATUS_QUALIFY)) {
                leadRecord.Identity_Review_Confirmed_CC__c.addError(IDENTITY_WRONG_STAGE);
            } else if (oldLead.Status == STATUS_IDENTIFY) {
                log(leadRecord, EVENT_IDENTITY, cycleOf(leadRecord), 'at Identify');
            }
        }
        if (leadRecord.Qualification_Review_Confirmed_CC__c && !oldLead.Qualification_Review_Confirmed_CC__c) {
            if (oldLead.Status != STATUS_QUALIFY) {
                leadRecord.Qualification_Review_Confirmed_CC__c.addError(QUALIFICATION_WRONG_STAGE);
            } else {
                log(leadRecord, EVENT_QUALIFICATION, cycleOf(leadRecord), 'at Qualify');
            }
        }
    }

    /** Explicit Status moves and conversion cannot skip this cycle's reviews. */
    private static void enforceReviews(Lead leadRecord, Lead oldLead) {
        if (leadRecord.IsConverted && !oldLead.IsConverted) {
            if (identityReviewPending(leadRecord) || qualificationReviewPending(leadRecord)) {
                leadRecord.addError(CONVERSION_BLOCK);
            }
            return;
        }
        if (leadRecord.Status == oldLead.Status) {
            return;
        }
        Boolean intoEngage = leadRecord.Status == STATUS_ENGAGE || leadRecord.Status == STATUS_QUALIFIED;
        Boolean forwardFromIdentify = oldLead.Status == STATUS_IDENTIFY && (leadRecord.Status == STATUS_QUALIFY || intoEngage);
        if (forwardFromIdentify && identityReviewPending(leadRecord)) {
            leadRecord.addError(IDENTITY_BLOCK);
        } else if ((oldLead.Status == STATUS_IDENTIFY || oldLead.Status == STATUS_QUALIFY) && intoEngage
            && qualificationReviewPending(leadRecord)) {
            leadRecord.addError(QUALIFICATION_BLOCK);
        }
    }

    // ---------------------------------------------------------------- history

    private static void log(Lead leadRecord, String event, Integer cycle, String detail) {
        String entry = '[' + Datetime.now().formatGmt('yyyy-MM-dd HH:mm') + ' UTC] | ' + event + ' | cycle ' + cycle
            + ' | by ' + UserInfo.getName() + ' (' + UserInfo.getUserId() + ') | ' + detail;
        String existing = leadRecord.Lifecycle_History_CC__c;
        leadRecord.Lifecycle_History_CC__c = (String.isBlank(existing) ? entry : entry + '\n' + existing).left(HISTORY_LENGTH);
    }

    private static String dispositionText(Lead leadRecord) {
        return 'reason: ' + valueOrNone(leadRecord.Re_Nurture_Reason_CC__c)
            + '; re-engage: ' + (leadRecord.Reengagement_Date_CC__c == null ? 'none' : String.valueOf(leadRecord.Reengagement_Date_CC__c))
            + '; comments: ' + valueOrNone(leadRecord.Re_Nurture_Comments_CC__c == null ? null : leadRecord.Re_Nurture_Comments_CC__c.left(TEXT_LENGTH));
    }

    private static String valueOrNone(String value) {
        return String.isBlank(value) ? 'none' : value.replace('\n', ' ');
    }

    // ---------------------------------------------------------------- helpers

    private static Object populated(Lead leadRecord, String fieldName) {
        return leadRecord.getPopulatedFieldsAsMap().get(fieldName);
    }

    private static Boolean isTrue(Lead leadRecord, String fieldName) {
        return populated(leadRecord, fieldName) == true;
    }
}