/**
 * One-off backfill of Next Step (Stage_Progress_Message_CC__c) on open Leads created before Next Step was set on
 * insert. Writes only that field, and only on the approved Leads.
 *
 * Safety:
 * - Runs as a batch, so LeadStageTransitionService_CC never auto-advances Status during the save; the Lead trigger
 *   recomputes the same text in beforeUpdate.
 * - Skips a Lead whose Status or Owner differs from the approved dry run, that already has a Next Step, or whose
 *   computed text is empty. Never changes Status, Owner or any other field.
 * - The Lead duplicate rule is Allow + Alert on update, so the save allows it (DuplicateRuleHeader.allowSave).
 * - Partial success: a record rejected by a validation rule is recorded and left unchanged. No exception escapes,
 *   so no Apex exception email is sent.
 */
public inherited sharing class LeadNextStepBackfill_CC implements Database.Batchable<SObject>, Database.Stateful {

    private static final List<String> OPEN_STATUSES = new List<String>{ 'Identify', 'Qualify', 'Engage', 'Re-Nurture' };

    private final Map<Id, String> approvedKeyById;
    public List<String> updated = new List<String>();
    public List<String> skipped = new List<String>();
    public List<String> failed = new List<String>();

    /**
     * @param approvedKeyById Lead Id => key(Status, OwnerId) from the approved dry run (see approvalKey)
     */
    public LeadNextStepBackfill_CC(Map<Id, String> approvedKeyById) {
        this.approvedKeyById = approvedKeyById == null ? new Map<Id, String>() : approvedKeyById;
    }

    /** The key the dry run records, so a Lead that moved stage or owner after approval is skipped. */
    public static String approvalKey(String status, Id ownerId) {
        return status + '|' + String.valueOf(ownerId);
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        Set<Id> approvedIds = approvedKeyById.keySet();
        return Database.getQueryLocator([
            SELECT Id FROM Lead
            WHERE Id IN :approvedIds AND IsConverted = false AND Status IN :OPEN_STATUSES
              AND Stage_Progress_Message_CC__c = null
        ]);
    }

    public void execute(Database.BatchableContext context, List<Lead> scope) {
        try {
            Set<Id> ids = new Map<Id, Lead>(scope).keySet();
            List<String> fieldNames = new List<String>(Schema.SObjectType.Lead.fields.getMap().keySet());
            List<Lead> current = (List<Lead>) Database.query(
                'SELECT ' + String.join(fieldNames, ',') + ' FROM Lead WHERE Id IN :ids');
            List<Lead> computed = new List<Lead>();
            for (Lead leadRecord : current) {
                computed.add(leadRecord.clone(true, true, false, false));
            }
            LeadStageTransitionService_CC.stampStageMessages(computed);

            List<Lead> changes = new List<Lead>();
            for (Integer i = 0; i < current.size(); i++) {
                Lead leadRecord = current[i];
                String reason = skipReason(leadRecord, computed[i].Stage_Progress_Message_CC__c);
                if (reason != null) {
                    skipped.add(leadRecord.Id + '|' + reason);
                } else {
                    changes.add(new Lead(Id = leadRecord.Id,
                        Stage_Progress_Message_CC__c = computed[i].Stage_Progress_Message_CC__c));
                }
            }
            save(changes);
        } catch (Exception ex) {
            for (Lead leadRecord : scope) {
                failed.add(leadRecord.Id + '|' + ex.getTypeName() + ': ' + ex.getMessage());
            }
        }
    }

    public void finish(Database.BatchableContext context) {
        System.debug(LoggingLevel.INFO, 'LeadNextStepBackfill_CC: updated=' + updated.size() + ' skipped='
            + skipped.size() + ' failed=' + failed.size() + '\nUPDATED ' + String.join(updated, ',')
            + '\nSKIPPED ' + String.join(skipped, ',') + '\nFAILED ' + String.join(failed, ','));
    }

    private String skipReason(Lead leadRecord, String message) {
        if (approvedKeyById.get(leadRecord.Id) != approvalKey(leadRecord.Status, leadRecord.OwnerId)) {
            return 'status or owner changed since approval';
        }
        if (String.isNotBlank(leadRecord.Stage_Progress_Message_CC__c)) {
            return 'already has a Next Step';
        }
        if (String.isBlank(message)) {
            return 'no Next Step for this stage';
        }
        return null;
    }

    private void save(List<Lead> changes) {
        if (changes.isEmpty()) {
            return;
        }
        Database.DMLOptions options = new Database.DMLOptions();
        options.optAllOrNone = false;
        options.DuplicateRuleHeader.allowSave = true;
        List<Database.SaveResult> results = Database.update(changes, options);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                updated.add(changes[i].Id);
            } else {
                failed.add(changes[i].Id + '|' + String.valueOf(results[i].getErrors()[0].getMessage()));
            }
        }
    }
}