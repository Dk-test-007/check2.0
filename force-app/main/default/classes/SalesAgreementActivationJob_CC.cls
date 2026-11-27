/**
 * Opportunity UI2: activates a newly planned native Sales Agreement.
 * The platform refuses a status change in the same transaction as other agreement edits and does not allow
 * Draft -> Activated directly, so each step (Draft -> Approved, Approved -> Activated) runs in its own queued job.
 * Progress and failures are written to Plan_Status_CC__c / Plan_Status_Detail_CC__c; resume() re-queues a stalled or
 * failed activation. Runs as the user who won the Opportunity, with their access (user mode).
 */
public with sharing class SalesAgreementActivationJob_CC implements Queueable {

    private final Id agreementId;
    /** Tests run one step at a time (a test cannot chain queued jobs); production chains Approved -> Activated. */
    @TestVisible private static Boolean chainNextStep = true;

    public SalesAgreementActivationJob_CC(Id agreementId) {
        this.agreementId = agreementId;
    }

    public static void enqueue(Id agreementId) {
        System.enqueueJob(new SalesAgreementActivationJob_CC(agreementId));
    }

    /** Re-queues activation for an agreement that is not yet active. */
    @AuraEnabled
    public static String resume(Id agreementId) {
        SalesAgreementPlanService_CC.requirePilot();
        SalesAgreementPlanService_CC.requireEditAccess(agreementId);
        SalesAgreement agreement = [SELECT Status, Plan_Status_CC__c FROM SalesAgreement WHERE Id = :agreementId WITH USER_MODE];
        if (agreement.Status == 'Activated') {
            markActive(agreementId);
            return 'The Sales Agreement is already active.';
        }
        Database.update(new SalesAgreement(Id = agreementId, Plan_Status_CC__c = 'Activation Pending',
            Plan_Status_Detail_CC__c = 'Activation re-queued.'), AccessLevel.USER_MODE);
        enqueue(agreementId);
        return 'Activation re-queued.';
    }

    public void execute(QueueableContext context) {
        SalesAgreement agreement = [SELECT Id, Status FROM SalesAgreement WHERE Id = :agreementId WITH USER_MODE];
        String next = nextStatus(agreement.Status);
        if (next == null) {
            markFailed('Cannot activate an agreement with status ' + agreement.Status + '.');
            return;
        }
        try {
            if (next != agreement.Status) {
                Database.update(new SalesAgreement(Id = agreementId, Status = next), AccessLevel.USER_MODE);
            }
            if (next == ACTIVATED) {
                markActive(agreementId);
            } else if (chainNextStep) {
                enqueue(agreementId);
            }
        } catch (Exception ex) {
            markFailed(ex.getMessage());
        }
    }

    private static final String ACTIVATED = 'Activated';

    /** One activation step: the status this job moves an agreement to, or null when it cannot be activated. */
    @TestVisible
    private static String nextStatus(String current) {
        switch on current {
            when 'Draft', 'Rejected', 'UnderRevision' {
                return 'Approved';
            }
            when 'Approved', 'Activated' {
                return ACTIVATED;
            }
            when else {
                return null;
            }
        }
    }

    private static void markActive(Id agreementId) {
        Database.update(new SalesAgreement(Id = agreementId, Plan_Status_CC__c = 'Active',
            Plan_Status_Detail_CC__c = 'Activated ' + System.now().formatGmt('yyyy-MM-dd HH:mm') + ' UTC.'), AccessLevel.USER_MODE);
    }

    private void markFailed(String message) {
        Database.update(new SalesAgreement(Id = agreementId, Plan_Status_CC__c = 'Activation Failed',
            Plan_Status_Detail_CC__c = message.left(255)), false, AccessLevel.USER_MODE);
    }
}