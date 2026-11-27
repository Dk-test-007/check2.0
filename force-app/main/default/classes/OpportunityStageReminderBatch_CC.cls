global without sharing class OpportunityStageReminderBatch_CC
    implements Database.Batchable<SObject> {

    global Database.QueryLocator start(
        Database.BatchableContext bc
    ) {

        return Database.getQueryLocator([
            SELECT
                Id,
                Name,
                Account.Name,
                StageName,
                Amount,
                OwnerId,
                LastStageChangeDate,
            	CreatedDate,
            	BAU_Opportunity_CC__c,
            	BAU_Month_CC__c,
                Stage_Reminder_Sent_Date_CC__c
            FROM Opportunity
            WHERE IsClosed = false
            AND OwnerId != null
        ]);
    }

    global void execute(
        Database.BatchableContext bc,
        List<Opportunity> scope
    ) {
        OpportunityStageReminderService_CC.sendReminders(scope);
    }

    global void finish(
        Database.BatchableContext bc
    ) {
    }
}