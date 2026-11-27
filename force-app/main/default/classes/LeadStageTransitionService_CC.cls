/**
 * Lead stage progression: the single owner of automatic Lead Status changes and the single reader of the Lead stage
 * metadata.
 *
 * Stage metadata
 *   Lead_Stage_CC__mdt        one record per Lead Status: Stage Order, Stage Type (Path / Exit), Auto Advance.
 *   Lead_Stage_Field_CC__mdt  the fields required at a stage. A Path stage (Identify -> Qualify -> Engage -> Qualified)
 *                             also requires the fields of every lower Path stage. An Exit stage (Disqualified,
 *                             Re-Nurture) requires only its own fields.
 * The same metadata drives the stage-gate validation (LeadTriggerHandler_CC_New.validateLeadStageGates), automatic
 * advancement and the Next Step message, so the three always agree. Code refers to a stage by its record name
 * (statusOf('Engage')), so renaming a Status value only needs the metadata updated.
 *
 * Automatic advancement (before update, every user, not in async jobs)
 *   When the user did not change Status, the Lead moves ONE stage forward if the next Path stage has Auto Advance
 *   ticked and all of its required fields are filled. The following stage is reached on a later save.
 *   Auto Advance is ticked for Qualify and Engage only: Qualified is the converted status and is never set here.
 *
 * Unchanged
 *   - Disqualified / Re-Nurture outcomes when their inputs are entered: only users who may set outcomes (Sales
 *     permission, System Administrator or the bypass).
 *   - The duplicate checkpoint on entry to Qualified. Neither duplicate-bypass field is ever set here.
 *   - A Lead whose contact is still the "Needs to Identify" placeholder never advances.
 */
public inherited sharing class LeadStageTransitionService_CC {

    // ---------------------------------------------------------------- stage metadata (loaded once per transaction)
    // Declared before the STATUS_ constants below, which are read from it.
    private static Map<String, Lead_Stage_CC__mdt> stageByName;
    private static Map<String, Lead_Stage_CC__mdt> stageByStatus;
    private static List<Lead_Stage_CC__mdt> pathStages;
    private static List<Lead_Stage_Field_CC__mdt> requiredFieldRules;
    private static Map<String, Schema.SObjectField> leadFieldMap;

    private static final String STAGE_TYPE_PATH = 'Path';

    // Status values, by Lead_Stage_CC__mdt record name.
    public static final String STATUS_IDENTIFY = statusOf('Identify');
    public static final String STATUS_QUALIFY = statusOf('Qualify');
    public static final String STATUS_ENGAGE = statusOf('Engage');
    public static final String STATUS_QUALIFIED = statusOf('Qualified');
    public static final String STATUS_DISQUALIFIED = statusOf('Disqualified');
    public static final String STATUS_RE_NURTURE = statusOf('Re_Nurture');

    public static final String DUPLICATE_ERROR = 'This Lead matches an existing record.';
    public static final String MEETING_OUTCOME_QUALIFIED = 'Qualified';

    private static final String ADMIN_PROFILE = 'System Administrator';
    private static final String MARKETING_PROFILE = 'Carlton Marketing User';
    private static final Set<String> MARKETING_POOLS = new Set<String>{ 'UK_Marketing_Pool', 'US_Marketing_Pool' };
    @TestVisible
    private static final String MARKETING_HANDOFF = ' Marketing: once the appointment is booked, change Owner to your '
        + 'regional Sales pool or a Sales user in it.';
    /** Engage Next Step before any meeting is booked (Nov 11 UAT feedback: book first, then record the outcome). */
    @TestVisible
    private static final String BOOK_MEETING_MESSAGE = 'Book a meeting with New Event; then record the outcome.';
    private static final String OUTCOME_PERMISSION = 'Sales_User_Permission_CC';
    private static final Integer DUPLICATE_CHUNK_SIZE = 50;
    private static final Integer MESSAGE_LENGTH = 255;
    private static final String PLACEHOLDER_GAP = 'the contact\'s real name (replace the "Needs to Identify" placeholder)';
    private static final String PLACEHOLDER_MESSAGE = 'Identify the contact: replace the "Needs to Identify" placeholder '
        + 'with the contact\'s real name. The Lead stays at Identify until then.';

    private static final List<String> DISQUALIFY_INPUTS = new List<String>{
        'Disqualified_Reason_CC__c', 'Disqualification_Comments_CC__c'
    };
    private static final List<String> RE_NURTURE_INPUTS = new List<String>{
        'Re_Nurture_Reason_CC__c', 'Re_Nurture_Comments_CC__c', 'Reengagement_Date_CC__c'
    };

    /**
     * Next Step at Engage for each active Meeting Outcome other than Qualified - Progress. None of these changes Status
     * by itself: Re-Nurture and Disqualify still need their own reason, and conversion needs Qualified - Progress.
     * Which of the lost-contact, dormant and wrong-contact outcomes should end in Re-Nurture or Disqualify is not an
     * agreed rule, so the text offers both and decides nothing.
     */
    @TestVisible
    private static final Map<String, String> OUTCOME_NEXT_STEPS = new Map<String, String>{
        'Further Nurture Required' => 'Further nurture: enter a Re-Nurture Reason and Re-engagement Date (Other needs '
            + 'comments) and save. A Sales user\'s save moves the Lead to Re-Nurture.',
        'Rebook Meeting' => 'Rebook the meeting: add it as a new Event in Activity and update the appointment fields if '
            + 'needed. The Lead stays at Engage; record the outcome after the meeting.',
        'Incorrect Decision Maker' => 'Find the right decision maker: update the contact name and title, book a meeting '
            + 'with them, then record the new outcome. The Lead stays at Engage.',
        'No Contact / Lost Contact' => 'Contact lost: keep trying and log attempts in Activity. The Lead stays at Engage. '
            + 'If they cannot be reached, enter a Re-Nurture reason and date, or Disqualify. Nothing is decided automatically.',
        'Dormant / No Foreseeable Opportunity' => 'No foreseeable opportunity: enter a Re-Nurture reason and date, or '
            + 'Disqualify with a reason. The Lead stays at Engage until you do; nothing is decided automatically.',
        'Other' => 'Outcome Other: describe it in Activity, then choose the next step: rebook, Re-Nurture (reason and '
            + 'date) or Disqualify. The Lead stays at Engage.'
    };

    @TestVisible private static Boolean forceAsyncContext = false;
    /** Lets tests create Leads with a blank Next Step, as Leads created before the insert fix have. */
    @TestVisible private static Boolean suppressInitialMessages = false;
    private static Set<Id> marketingPoolIds;
    private static Map<Id, Boolean> outcomePermittedByUser = new Map<Id, Boolean>();
    private static List<Lead> advancedOnInsert = new List<Lead>();

    /** The current Lead trigger advances a complete new Identify Lead by one stage before setting Next Step. */
    public static void applyOnInsert(List<Lead> newLeads) {
        if (newLeads == null || isAsyncContext()) return;
        for (Lead leadRecord : newLeads) {
            if (leadRecord.Status == STATUS_IDENTIFY && entryGaps(leadRecord, STATUS_QUALIFY).isEmpty()) {
                leadRecord.Status = STATUS_QUALIFY;
                advancedOnInsert.add(leadRecord);
            }
        }
    }

    public static Boolean wasAdvancedOnInsert(Lead leadRecord) {
        return advancedOnInsert.contains(leadRecord);
    }

    /**
     * Applies automatic advancement, outcomes, the Qualified duplicate checkpoint and progress messages.
     * Bulk-safe: no DML; duplicate matching runs once per 50 Leads entering Qualified, and the Marketing-owner lookup
     * for the Engage Next Step adds at most two queries per batch. Metadata queries do not count against limits.
     * @param newLeads Trigger.new (before update), modified in place
     * @param oldLeadMap Trigger.oldMap
     */
    public static void apply(List<Lead> newLeads, Map<Id, Lead> oldLeadMap) {
        if (newLeads == null || newLeads.isEmpty() || oldLeadMap == null) {
            return;
        }
        Boolean interactive = !isAsyncContext();
        Boolean autoOutcomes = interactive;
        Trigger_Framework_Config_CC__mdt config = Trigger_Framework_Config_CC__mdt.getInstance('Lead');
        // Cycle bookkeeping first, so restart resets and review confirmations are what the gates below see.
        LeadLifecycleCycle_CC.apply(newLeads, oldLeadMap, config != null && config.Bypass_Validation_CC__c);
        List<Lead> manualQualified = new List<Lead>();

        for (Lead leadRecord : newLeads) {
            Lead oldLead = oldLeadMap.get(leadRecord.Id);
            if (oldLead == null) {
                continue;
            }
            // The user changed Status: no automatic change; entry to Qualified gets the duplicate check.
            if (leadRecord.Status != oldLead.Status) {
                if (leadRecord.Status == STATUS_QUALIFIED && oldLead.Status != STATUS_QUALIFIED
                    && !leadRecord.Bypass_Duplicate_Rules_on_Qualification__c) {
                    manualQualified.add(leadRecord);
                }
                continue;
            }
            if (!interactive) {
                continue;
            }

            // 1. Outcome requested in this save: Disqualified from Qualify or Engage (or from Identify
            //    while the contact is the placeholder), Re-Nurture from Engage. A requested outcome stops advancement.
            Boolean outcomeRequested = false;
            if (autoOutcomes) {
                if (oldLead.Status == STATUS_IDENTIFY && isPlaceholderName(leadRecord)) {
                    outcomeRequested = applyOutcome(leadRecord, oldLead, false);
                } else if (oldLead.Status == STATUS_QUALIFY) {
                    outcomeRequested = applyOutcome(leadRecord, oldLead, false);
                } else if (oldLead.Status == STATUS_ENGAGE) {
                    outcomeRequested = applyOutcome(leadRecord, oldLead, true);
                }
            }
            if (outcomeRequested) {
                continue;
            }

            // 2. Automatic advancement (every user): one stage per save, into the next Path stage when that stage
            //    allows auto advance and all of its required fields are filled.
            String nextStatus = nextAutoAdvanceStatus(oldLead.Status);
            if (nextStatus != null && entryGaps(leadRecord, nextStatus).isEmpty()) {
                leadRecord.Status = nextStatus;
            }
        }

        Set<Id> duplicates = findDuplicateIds(manualQualified);
        for (Lead leadRecord : manualQualified) {
            if (duplicates.contains(leadRecord.Id)) {
                leadRecord.addError(DUPLICATE_ERROR);
            }
        }

        Set<Id> marketingOwners = marketingOwnerIds(newLeads);
        for (Lead leadRecord : newLeads) {
            Lead oldLead = oldLeadMap.get(leadRecord.Id);
            if (oldLead == null) {
                continue;
            }
            if (leadRecord.Status != STATUS_QUALIFY) {
                leadRecord.Duplicate_Review_Required_CC__c = false;
            }
            setProgressMessage(leadRecord, oldLead, autoOutcomes, marketingOwners.contains(leadRecord.OwnerId));
        }
        LeadLifecycleCycle_CC.logDispositions(newLeads, oldLeadMap);
    }

    /**
     * Sets the initial Next Step on Leads being inserted, so a new Lead does not show a blank Next Step until its
     * first update. Called from LeadTriggerHandler_CC_New.beforeInsert after owner routing, so the Engage handoff text
     * reflects the routed owner. Never changes Status: a Lead is created at the stage it was given.
     * @param newLeads Trigger.new (before insert), modified in place
     */
    public static void setInitialProgressMessages(List<Lead> newLeads) {
        if (suppressInitialMessages) {
            return;
        }
        stampStageMessages(newLeads);
    }

    /**
     * Sets Stage_Progress_Message_CC__c in memory to the stage message for each Lead's current Status and owner, as
     * the insert path does. No DML, never changes Status. Also used by LeadNextStepBackfill_CC.
     * @param newLeads Leads with every field the stage metadata reads (modified in place)
     */
    public static void stampStageMessages(List<Lead> newLeads) {
        if (newLeads == null || newLeads.isEmpty()) {
            return;
        }
        Set<Id> marketingOwners = marketingOwnerIds(newLeads);
        for (Lead leadRecord : newLeads) {
            leadRecord.Stage_Progress_Message_CC__c =
                stageMessage(leadRecord, marketingOwners.contains(leadRecord.OwnerId))?.left(MESSAGE_LENGTH);
        }
    }

    // ---------------------------------------------------------------- stage metadata API

    /** Status value of a stage, by its Lead_Stage_CC__mdt record name (for example 'Engage'); null if not defined. */
    public static String statusOf(String stageName) {
        loadStageMetadata();
        Lead_Stage_CC__mdt stage = stageByName.get(stageName);
        return stage == null ? null : stage.Status_Value_CC__c;
    }

    /** Stage Order of a Status; 0 when the Status has no stage record. */
    public static Integer stageOrder(String status) {
        loadStageMetadata();
        Lead_Stage_CC__mdt stage = status == null ? null : stageByStatus.get(status);
        return stage == null ? 0 : stage.Stage_Order_CC__c.intValue();
    }

    /** True when status is a Path stage ordered after otherStatus (for example Qualify, Engage, Qualified after Identify). */
    public static Boolean isLaterPathStage(String status, String otherStatus) {
        loadStageMetadata();
        Lead_Stage_CC__mdt stage = status == null ? null : stageByStatus.get(status);
        return stage != null && stage.Stage_Type_CC__c == STAGE_TYPE_PATH && stageOrder(status) > stageOrder(otherStatus);
    }

    /**
     * The required-field records that apply at a Status: the stage's own records plus, for a Path stage, those of
     * every lower Path stage. Empty when the Status has no stage record.
     */
    public static List<Lead_Stage_Field_CC__mdt> requiredFieldsFor(String status) {
        loadStageMetadata();
        List<Lead_Stage_Field_CC__mdt> rules = new List<Lead_Stage_Field_CC__mdt>();
        Lead_Stage_CC__mdt stage = status == null ? null : stageByStatus.get(status);
        if (stage == null) {
            return rules;
        }
        for (Lead_Stage_Field_CC__mdt rule : requiredFieldRules) {
            Lead_Stage_CC__mdt ruleStage = stageByName.get(rule.Lead_Stage_CC__r.DeveloperName);
            if (ruleStage == null) {
                continue;
            }
            Boolean ownStage = ruleStage.DeveloperName == stage.DeveloperName;
            Boolean lowerPathStage = stage.Stage_Type_CC__c == STAGE_TYPE_PATH
                && ruleStage.Stage_Type_CC__c == STAGE_TYPE_PATH
                && ruleStage.Stage_Order_CC__c < stage.Stage_Order_CC__c;
            if (ownStage || lowerPathStage) {
                rules.add(rule);
            }
        }
        return rules;
    }

    /**
     * Checks one required-field record against a Lead.
     *   Step 1 - Condition: the requirement applies only when Condition Field equals Condition Value
     *            (for example Lead Source = Referral). Otherwise it is skipped (treated as met).
     *   Step 2 - Count how many of the listed fields are filled.
     *   Step 3 - Met when that count reaches Minimum Required (blank = 1).
     */
    public static Boolean isRequirementMet(Lead leadRecord, Lead_Stage_Field_CC__mdt rule) {
        // Step 1 - condition
        if (String.isNotBlank(rule.Condition_Field_CC__c)) {
            String actualValue = String.valueOf(leadRecord.get(rule.Condition_Field_CC__c.trim()));
            if (actualValue != rule.Condition_Value_CC__c) {
                return true; // condition not met: this field is not required for this Lead
            }
        }

        // Step 2 - count filled fields (blank = null or empty text, as the formula ISBLANK())
        Integer filled = 0;
        for (String fieldName : fieldNamesOf(rule)) {
            Object value = leadRecord.get(fieldName);
            if (value != null && String.valueOf(value) != '') {
                filled++;
            }
        }

        // Step 3 - compare with the minimum
        Integer minimum = rule.Minimum_Required_CC__c == null ? 1 : rule.Minimum_Required_CC__c.intValue();
        return filled >= minimum;
    }

    /** Keep a compound Country/CountryCode requirement on Country; choices appear at the top of the page. */
    public static String errorFieldOf(Lead_Stage_Field_CC__mdt rule) {
        List<String> fields = fieldNamesOf(rule);
        if (fields.size() == 1) return fields[0];
        if (fields.size() == 2 && fields.contains('Country') && fields.contains('CountryCode')) return 'Country';
        return null;
    }

    /** Labels of the unmet requirements at a Status (used in Next Step messages). */
    public static List<String> missingFields(Lead leadRecord, String status) {
        List<String> missing = new List<String>();
        for (Lead_Stage_Field_CC__mdt rule : requiredFieldsFor(status)) {
            if (!isRequirementMet(leadRecord, rule)) {
                missing.add(requirementLabel(rule));
            }
        }
        return missing;
    }

    /** Every Lead field the stage metadata reads, so a caller can query them before checking a stored Lead. */
    public static Set<String> metadataFieldNames() {
        loadStageMetadata();
        Set<String> fieldNames = new Set<String>();
        for (Lead_Stage_Field_CC__mdt rule : requiredFieldRules) {
            fieldNames.addAll(fieldNamesOf(rule));
            if (String.isNotBlank(rule.Condition_Field_CC__c)) {
                fieldNames.add(rule.Condition_Field_CC__c.trim());
            }
        }
        return fieldNames;
    }

    /**
     * Contact_Name_Unknown_CC__c on the values being saved: Last Name starts with "Needs to Identify" (case and spaces
     * ignored). Evaluated in Apex because a stored formula value is stale in a before trigger.
     */
    public static Boolean isPlaceholderName(Lead leadRecord) {
        String normalised = leadRecord.LastName == null ? '' : leadRecord.LastName.trim().toUpperCase().replace(' ', '');
        return normalised.startsWith('NEEDSTOIDENTIFY');
    }

    // ---------------------------------------------------------------- gates

    /** Missing inputs for Identify -> Qualify (field labels). */
    @TestVisible
    private static List<String> identifyGaps(Lead leadRecord) {
        return entryGaps(leadRecord, STATUS_QUALIFY);
    }

    /**
     * Missing inputs for entering Engage, excluding the duplicate checkpoint (field labels). Also used by the pilot
     * Return to Engage action (LeadReturnToEngageAction_CC), so both routes apply the same gate.
     */
    public static List<String> engageGaps(Lead leadRecord) {
        return entryGaps(leadRecord, STATUS_ENGAGE);
    }

    /** Missing inputs before conversion (Status Qualified). */
    private static List<String> conversionGaps(Lead leadRecord) {
        return entryGaps(leadRecord, STATUS_QUALIFIED);
    }

    /**
     * Everything that keeps a Lead out of a Path stage: the stage's required fields (metadata), plus the restart
     * reviews of this cycle and the placeholder contact name.
     */
    private static List<String> entryGaps(Lead leadRecord, String status) {
        List<String> gaps = missingFields(leadRecord, status);
        if (status == STATUS_QUALIFY && LeadLifecycleCycle_CC.identityReviewPending(leadRecord)) {
            addFirst(gaps, LeadLifecycleCycle_CC.IDENTITY_REVIEW_GAP);
        }
        if ((status == STATUS_ENGAGE || status == STATUS_QUALIFIED)
            && LeadLifecycleCycle_CC.qualificationReviewPending(leadRecord)) {
            addFirst(gaps, LeadLifecycleCycle_CC.QUALIFICATION_REVIEW_GAP);
        }
        if (isPlaceholderName(leadRecord)) {
            addFirst(gaps, PLACEHOLDER_GAP);
        }
        return gaps;
    }

    /** Status of the next Path stage after status, when that stage allows auto advance; otherwise null. */
    private static String nextAutoAdvanceStatus(String status) {
        loadStageMetadata();
        Lead_Stage_CC__mdt current = status == null ? null : stageByStatus.get(status);
        if (current == null || current.Stage_Type_CC__c != STAGE_TYPE_PATH) {
            return null;
        }
        for (Lead_Stage_CC__mdt stage : pathStages) {
            if (stage.Stage_Order_CC__c > current.Stage_Order_CC__c) {
                return stage.Auto_Advance_CC__c ? stage.Status_Value_CC__c : null;
            }
        }
        return null;
    }

    // ---------------------------------------------------------------- outcomes

    /**
     * Moves the Lead to Disqualified (from Qualify or Engage, or from Identify while the contact is
     * still the placeholder) or Re-Nurture (from Engage only) when
     * that outcome's inputs changed in this save and are complete. Any user who can edit the Lead may disqualify;
     * Re-Nurture still needs a user who may set outcomes (Sales).
     * @return true when an outcome was requested in this save (applied or not)
     */
    private static Boolean applyOutcome(Lead leadRecord, Lead oldLead, Boolean allowReNurture) {
        Boolean wantsDisqualify = changedAny(leadRecord, oldLead, DISQUALIFY_INPUTS)
            && String.isNotBlank(leadRecord.Disqualified_Reason_CC__c);
        Boolean wantsReNurture = allowReNurture && wantsReNurture(leadRecord, oldLead);
        if (!wantsDisqualify && !wantsReNurture) {
            return false;
        }
        if (wantsDisqualify && wantsReNurture) {
            return true;
        }
        if (wantsDisqualify) {
            if (missingFields(leadRecord, STATUS_DISQUALIFIED).isEmpty()) {
                leadRecord.Status = STATUS_DISQUALIFIED;
            }
            return true;
        }
        if (isOutcomePermitted() && missingFields(leadRecord, STATUS_RE_NURTURE).isEmpty()) {
            leadRecord.Status = STATUS_RE_NURTURE;
        }
        return true;
    }

    /**
     * Re-Nurture inputs changed in this save, with a reason. After an earlier Re-Nurture was logged (the Lead came
     * back through Return to Engage with its details kept), the reason or the date must change: editing only the old
     * comments must not send the Lead back to Re-Nurture on the stale reason and date.
     */
    private static Boolean wantsReNurture(Lead leadRecord, Lead oldLead) {
        if (String.isBlank(leadRecord.Re_Nurture_Reason_CC__c) || !changedAny(leadRecord, oldLead, RE_NURTURE_INPUTS)) {
            return false;
        }
        return !LeadLifecycleCycle_CC.hasLoggedReNurture(oldLead)
            || leadRecord.Re_Nurture_Reason_CC__c != oldLead.Re_Nurture_Reason_CC__c
            || leadRecord.Reengagement_Date_CC__c != oldLead.Reengagement_Date_CC__c;
    }

    // ---------------------------------------------------------------- messages

    private static void setProgressMessage(Lead leadRecord, Lead oldLead, Boolean autoOutcomes, Boolean marketingOwned) {
        String message = autoOutcomes && leadRecord.Status == oldLead.Status ? outcomeMessage(leadRecord, oldLead) : null;
        if (message == null) {
            message = stageMessage(leadRecord, marketingOwned);
        }
        leadRecord.Stage_Progress_Message_CC__c = message?.left(MESSAGE_LENGTH);
    }

    /**
     * What the Lead needs next at its (new) stage; null when nothing is outstanding. The message is stored and shown
     * to every viewer, so the Marketing handoff instruction depends on who owns the Lead, not on who saved it.
     */
    private static String stageMessage(Lead leadRecord, Boolean marketingOwned) {
        if (leadRecord.Status == STATUS_IDENTIFY) {
            if (isPlaceholderName(leadRecord)) {
                List<String> otherGaps = identifyGaps(leadRecord);
                otherGaps.remove(0);
                String rest = nextGapMessage(' Also complete: ', otherGaps);
                return PLACEHOLDER_MESSAGE + (rest == null ? '' : rest);
            }
            List<String> gaps = identifyGaps(leadRecord);
            if (!LeadLifecycleCycle_CC.identityReviewPending(leadRecord)) {
                return gaps.isEmpty() ? readyMessage(STATUS_QUALIFY)
                    : nextGapMessage('To move to Qualify, complete: ', gaps);
            }
            gaps.remove(gaps.indexOf(LeadLifecycleCycle_CC.IDENTITY_REVIEW_GAP));
            String rest = nextGapMessage(' Also complete: ', gaps);
            return 'Restarted (cycle ' + LeadLifecycleCycle_CC.cycleOf(leadRecord) + '): check the company and contact '
                + 'details, then Confirm identity review. ' + queueOwnerHint(leadRecord) + (rest == null ? '' : rest.trim());
        }
        if (leadRecord.Status == STATUS_RE_NURTURE) {
            return (leadRecord.Reengagement_Date_CC__c == null
                    ? 'No Re-engagement Date is set: add one so this follow-up shows as due. '
                    : 'Follow up from the Re-engagement Date (Re-Nurture Follow-ups list). ')
                + queueOwnerHint(leadRecord) + 'When ready: Restart at Identify to reassess, or Return to Engage (Sales) '
                + 'to resume the existing qualification.';
        }
        if (leadRecord.Status == STATUS_QUALIFY) {
            if (leadRecord.Duplicate_Review_Required_CC__c) {
                return 'Not moved to Engage: this Lead matches an existing record. Review the possible duplicates, '
                    + 'correct the Lead, or tick "' + label('Bypass_Duplicate_Rules_on_Qualification__c') + '" if it is not a duplicate.';
            }
            List<String> gaps = engageGaps(leadRecord);
            return gaps.isEmpty() ? readyMessage(STATUS_ENGAGE)
                : nextGapMessage('To move to Engage, complete: ', gaps);
        }
        if (leadRecord.Status == STATUS_ENGAGE) {
            String otherField = nextGapMessage(' Also complete: ', otherConversionGaps(leadRecord));
            if (String.isBlank(leadRecord.Meeting_Outcome_CC__c) && !hasMeeting(leadRecord)) {
                return BOOK_MEETING_MESSAGE + (otherField == null ? '' : otherField)
                    + (marketingOwned ? MARKETING_HANDOFF : '');
            }
            if (String.isBlank(leadRecord.Meeting_Outcome_CC__c)) {
                return 'Record the meeting outcome with Record Meeting Outcome.' + (otherField == null ? '' : otherField)
                    + (marketingOwned ? MARKETING_HANDOFF : '');
            }
            if (leadRecord.Meeting_Outcome_CC__c != MEETING_OUTCOME_QUALIFIED) {
                return OUTCOME_NEXT_STEPS.containsKey(leadRecord.Meeting_Outcome_CC__c)
                    ? OUTCOME_NEXT_STEPS.get(leadRecord.Meeting_Outcome_CC__c)
                    : 'Outcome ' + leadRecord.Meeting_Outcome_CC__c + ': choose the next step (rebook, Re-Nurture or '
                        + 'Disqualify). The Lead stays at Engage.';
            }
            String gaps = gapMessage('To convert, first complete: ', conversionGaps(leadRecord));
            return gaps == null ? 'Ready to convert: use Convert on the stage bar.' : gaps;
        }
        return null;
    }

    /** Next Step when every field of the next stage is filled: the move happens on the next save. */
    private static String readyMessage(String nextStatus) {
        return 'All ' + nextStatus + ' fields are complete: the Lead moves to ' + nextStatus + ' on its next save.';
    }

    /** Show one actionable field and a count; the field has a 255-character limit. */
    private static String nextGapMessage(String prefix, List<String> gaps) {
        if (gaps == null || gaps.isEmpty()) return null;
        return prefix + gaps[0] + (gaps.size() > 1 ? ' (and ' + (gaps.size() - 1) + ' more)' : '') + '.';
    }

    /** Meeting booking and outcome have their own prominent instructions at Engage. */
    private static List<String> otherConversionGaps(Lead leadRecord) {
        List<String> gaps = conversionGaps(leadRecord);
        removeGap(gaps, label('First_Sales_Appointment_Date_CC__c'));
        removeGap(gaps, label('Sales_Appointment_Booked_CC__c'));
        removeGap(gaps, label('Meeting_Outcome_CC__c'));
        return gaps;
    }

    private static void removeGap(List<String> gaps, String labelText) {
        Integer position = gaps.indexOf(labelText);
        if (position >= 0) gaps.remove(position);
    }

    /** Explains an outcome request that was saved but did not change the stage. */
    private static String outcomeMessage(Lead leadRecord, Lead oldLead) {
        Boolean canDisqualifyHere = leadRecord.Status == STATUS_QUALIFY || leadRecord.Status == STATUS_ENGAGE
            || (leadRecord.Status == STATUS_IDENTIFY && isPlaceholderName(leadRecord));
        Boolean wantsDisqualify = canDisqualifyHere && changedAny(leadRecord, oldLead, DISQUALIFY_INPUTS)
            && String.isNotBlank(leadRecord.Disqualified_Reason_CC__c);
        Boolean wantsReNurture = leadRecord.Status == STATUS_ENGAGE && wantsReNurture(leadRecord, oldLead);
        if (!wantsDisqualify && !wantsReNurture) {
            return null;
        }
        if (wantsDisqualify && wantsReNurture) {
            return 'Saved. Enter either a Disqualified reason or a Re-Nurture reason, not both, to close this stage.';
        }
        if (wantsReNurture && !isOutcomePermitted()) {
            return 'Saved. Moving a Lead to ' + STATUS_RE_NURTURE + ' needs a Sales user; ask Sales to complete it.';
        }
        return wantsDisqualify
            ? gapMessage('To disqualify, complete: ', missingFields(leadRecord, STATUS_DISQUALIFIED))
            : gapMessage('To re-nurture, complete: ', missingFields(leadRecord, STATUS_RE_NURTURE));
    }

    /**
     * A meeting is booked once Sales Appointment Booked is Yes or First Sales Appointment Date is set. Booking an Event
     * on the Lead sets both (EventTriggerHandler_CC). Until then Engage asks for a meeting, not its outcome.
     */
    private static Boolean hasMeeting(Lead leadRecord) {
        return leadRecord.First_Sales_Appointment_Date_CC__c != null || leadRecord.Sales_Appointment_Booked_CC__c == 'Yes';
    }

    /** Who takes the next step when a pool queue owns the Lead (the trigger lets a pool member take it). */
    private static String queueOwnerHint(Lead leadRecord) {
        return leadRecord.OwnerId != null && leadRecord.OwnerId.getSObjectType() == Group.SObjectType
            ? 'Pool-owned: a pool member takes it with Change Owner. '
            : '';
    }

    /**
     * Owners (Carlton Marketing users and the regional Marketing pools) of the Leads whose Next Step is the Engage
     * handoff text. Queries only when such a Lead is in the batch.
     */
    private static Set<Id> marketingOwnerIds(List<Lead> leads) {
        Set<Id> userIds = new Set<Id>();
        Set<Id> queueIds = new Set<Id>();
        for (Lead leadRecord : leads) {
            if (leadRecord.Status != STATUS_ENGAGE || String.isNotBlank(leadRecord.Meeting_Outcome_CC__c)
                || leadRecord.OwnerId == null) {
                continue;
            }
            if (leadRecord.OwnerId.getSObjectType() == User.SObjectType) {
                userIds.add(leadRecord.OwnerId);
            } else {
                queueIds.add(leadRecord.OwnerId);
            }
        }
        Set<Id> marketingOwners = new Set<Id>();
        if (!userIds.isEmpty()) {
            marketingOwners.addAll(new Map<Id, User>([
                SELECT Id FROM User WHERE Id IN :userIds AND Profile.Name = :MARKETING_PROFILE WITH SYSTEM_MODE
            ]).keySet());
        }
        if (!queueIds.isEmpty()) {
            if (marketingPoolIds == null) {
                marketingPoolIds = new Map<Id, Group>([
                    SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName IN :MARKETING_POOLS WITH SYSTEM_MODE
                ]).keySet();
            }
            for (Id queueId : queueIds) {
                if (marketingPoolIds.contains(queueId)) {
                    marketingOwners.add(queueId);
                }
            }
        }
        return marketingOwners;
    }

    private static String gapMessage(String prefix, List<String> gaps) {
        return gaps.isEmpty() ? null : prefix + String.join(gaps, '; ') + '.';
    }

    // ---------------------------------------------------------------- duplicates

    /** Ids of Leads matching another record under the active duplicate rules (self-matches ignored). */
    private static Set<Id> findDuplicateIds(List<Lead> leads) {
        Set<Id> duplicateIds = new Set<Id>();
        for (Integer start = 0; start < leads.size(); start += DUPLICATE_CHUNK_SIZE) {
            List<Lead> chunk = new List<Lead>();
            for (Integer i = start; i < Math.min(start + DUPLICATE_CHUNK_SIZE, leads.size()); i++) {
                chunk.add(leads[i]);
            }
            List<Datacloud.FindDuplicatesResult> results = Datacloud.FindDuplicates.findDuplicates(chunk);
            for (Integer i = 0; i < chunk.size(); i++) {
                if (hasOtherMatch(chunk[i].Id, results[i])) {
                    duplicateIds.add(chunk[i].Id);
                }
            }
        }
        return duplicateIds;
    }

    private static Boolean hasOtherMatch(Id leadId, Datacloud.FindDuplicatesResult result) {
        for (Datacloud.DuplicateResult duplicateResult : result.getDuplicateResults()) {
            for (Datacloud.MatchResult matchResult : duplicateResult.getMatchResults()) {
                for (Datacloud.MatchRecord matchRecord : matchResult.getMatchRecords()) {
                    if (matchRecord.getRecord() != null && matchRecord.getRecord().Id != leadId) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Loads Lead_Stage_CC__mdt and the active Lead_Stage_Field_CC__mdt records once per transaction. A required-field
     * record naming a Lead field that does not exist is skipped (and logged) so a typo cannot block every Lead save.
     */
    private static void loadStageMetadata() {
        if (stageByName != null) {
            return;
        }
        stageByName = new Map<String, Lead_Stage_CC__mdt>();
        stageByStatus = new Map<String, Lead_Stage_CC__mdt>();
        pathStages = new List<Lead_Stage_CC__mdt>();
        for (Lead_Stage_CC__mdt stage : [
            SELECT DeveloperName, Status_Value_CC__c, Stage_Order_CC__c, Stage_Type_CC__c, Auto_Advance_CC__c
            FROM Lead_Stage_CC__mdt WITH SYSTEM_MODE ORDER BY Stage_Order_CC__c
        ]) {
            stageByName.put(stage.DeveloperName, stage);
            stageByStatus.put(stage.Status_Value_CC__c, stage);
            if (stage.Stage_Type_CC__c == STAGE_TYPE_PATH) {
                pathStages.add(stage);
            }
        }
        requiredFieldRules = new List<Lead_Stage_Field_CC__mdt>();
        for (Lead_Stage_Field_CC__mdt rule : [
            SELECT DeveloperName, Field_API_Names_CC__c, Minimum_Required_CC__c, Condition_Field_CC__c,
                   Condition_Value_CC__c, Error_Message_CC__c, Lead_Stage_CC__r.DeveloperName
            FROM Lead_Stage_Field_CC__mdt WHERE Active_CC__c = true WITH SYSTEM_MODE ORDER BY DeveloperName
        ]) {
            if (hasValidFieldNames(rule)) {
                requiredFieldRules.add(rule);
            } else {
                System.debug(LoggingLevel.ERROR, 'Lead_Stage_Field_CC__mdt.' + rule.DeveloperName
                    + ' names a Lead field that does not exist; the requirement is ignored.');
            }
        }
    }

    private static Boolean hasValidFieldNames(Lead_Stage_Field_CC__mdt rule) {
        List<String> fieldNames = fieldNamesOf(rule);
        if (String.isNotBlank(rule.Condition_Field_CC__c)) {
            fieldNames.add(rule.Condition_Field_CC__c.trim());
        }
        if (fieldNames.isEmpty()) {
            return false;
        }
        for (String fieldName : fieldNames) {
            if (!leadFields().containsKey(fieldName)) {
                return false;
            }
        }
        return true;
    }

    /** The field API names listed on a required-field record (comma-separated). */
    public static List<String> fieldNamesOf(Lead_Stage_Field_CC__mdt rule) {
        List<String> fieldNames = new List<String>();
        for (String fieldName : (rule.Field_API_Names_CC__c == null ? '' : rule.Field_API_Names_CC__c).split(',')) {
            if (String.isNotBlank(fieldName)) {
                fieldNames.add(fieldName.trim());
            }
        }
        return fieldNames;
    }

    /** "Title", or for a group "one of Email, Phone, Mobile" / "any 2 of ...". */
    private static String requirementLabel(Lead_Stage_Field_CC__mdt rule) {
        List<String> labels = new List<String>();
        for (String fieldName : fieldNamesOf(rule)) {
            labels.add(label(fieldName));
        }
        if (labels.size() == 1) {
            return labels[0];
        }
        Integer minimum = rule.Minimum_Required_CC__c == null ? 1 : rule.Minimum_Required_CC__c.intValue();
        return (minimum == 1 ? 'one of ' : 'any ' + minimum + ' of ') + String.join(labels, ', ');
    }

    private static Boolean isAsyncContext() {
        return forceAsyncContext || System.isFuture() || System.isQueueable() || System.isBatch() || System.isScheduled();
    }

    /** Mirrors the exemptions of Lead_Progression_Validation_CC (Re-Nurture only; Disqualified is open to all). */
    private static Boolean isOutcomePermitted() {
        Id userId = UserInfo.getUserId();
        if (!outcomePermittedByUser.containsKey(userId)) {
            Trigger_Framework_Config_CC__mdt config = Trigger_Framework_Config_CC__mdt.getInstance('Lead');
            outcomePermittedByUser.put(userId, FeatureManagement.checkPermission(OUTCOME_PERMISSION)
                || (config != null && config.Bypass_Validation_CC__c)
                || [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() WITH SYSTEM_MODE].Name == ADMIN_PROFILE);
        }
        return outcomePermittedByUser.get(userId);
    }

    private static Boolean changedAny(Lead leadRecord, Lead oldLead, List<String> fieldNames) {
        for (String fieldName : fieldNames) {
            if (leadRecord.get(fieldName) != oldLead.get(fieldName)) {
                return true;
            }
        }
        return false;
    }

    /** Puts the gap first (List.add(0, x) fails on an empty list). */
    private static void addFirst(List<String> gaps, String gap) {
        if (gaps.isEmpty()) {
            gaps.add(gap);
        } else {
            gaps.add(0, gap);
        }
    }

    private static Map<String, Schema.SObjectField> leadFields() {
        if (leadFieldMap == null) {
            leadFieldMap = Schema.SObjectType.Lead.fields.getMap();
        }
        return leadFieldMap;
    }

    private static String label(String fieldName) {
        Schema.SObjectField field = leadFields().get(fieldName);
        return field == null ? fieldName : field.getDescribe().getLabel();
    }
}