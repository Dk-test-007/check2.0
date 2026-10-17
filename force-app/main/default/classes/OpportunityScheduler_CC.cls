global with sharing class OpportunityScheduler_CC implements Schedulable {

    global void execute(SchedulableContext sc) {
        Database.executeBatch(new BAUOpportunityCloseBatch_CC(),200);
        Database.executeBatch(new OpportunityStageReminderBatch_CC(), 200);
    }
}