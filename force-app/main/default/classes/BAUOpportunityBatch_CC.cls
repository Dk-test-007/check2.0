global without sharing class BAUOpportunityBatch_CC implements Database.Batchable<SObject>, Schedulable {

    private Set<Id> accountIds;

    global BAUOpportunityBatch_CC() {
        this.accountIds = new Set<Id>();
    }

    global BAUOpportunityBatch_CC(Set<Id> accountIds) {
        this.accountIds = accountIds;
    }

    global void execute(SchedulableContext sc) {
        Database.executeBatch(new BAUOpportunityBatch_CC(), 200);
    }

    global Database.QueryLocator start(Database.BatchableContext bc) {
        String query = 'SELECT Id, Name, OwnerId, Is_BAU_Account_CC__c, Opportunity_Creation_Year_CC__c FROM Account WHERE RecordType.DeveloperName = \'Entity\' AND Is_BAU_Account_CC__c = TRUE';

        if (!accountIds.isEmpty()) {
            query += ' AND Id IN :accountIds';
        }

        return Database.getQueryLocator(query);
    }

    global void execute(Database.BatchableContext bc, List<Account> accounts) {
        BAUOpportunityService_CC.createBAUOpportunities(accounts);
    }

    global void finish(Database.BatchableContext bc) {
    }
}