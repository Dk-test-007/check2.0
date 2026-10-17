global with sharing class BAUOpportunityScheduler_CC
    implements Schedulable {

    global void execute(SchedulableContext sc) {
        Database.executeBatch(
            new BAUOpportunityBatch_CC(),
            200
        );
    }
}