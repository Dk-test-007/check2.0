global with sharing class BAUOpportunityCloseBatch_CC implements Database.Batchable<SObject> {
    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id,
                   StageName,
                   CloseDate,
            	   RecordType.DeveloperName
            FROM Opportunity
            WHERE BAU_Opportunity_CC__c = TRUE
            AND IsClosed = FALSE
            AND CloseDate < :Date.today()
        ]);
    }

    global void execute(Database.BatchableContext bc,List<Opportunity> opportunities) {
        BAUOpportunityService_CC.closeExpiredBAUOpportunities(opportunities);
    }

    global void finish(Database.BatchableContext bc) {
    }
}