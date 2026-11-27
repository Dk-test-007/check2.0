public without sharing class ContractExpirationBatch_CC implements Schedulable, Database.Batchable<SObject> {

    public static final String STATUS_ACTIVE = 'Active';
    public static final String STATUS_EXPIRED = 'Expired';

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ContractExpirationBatch_CC(), 200);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([SELECT Id, Status, EndDate FROM Contract WHERE Status = :STATUS_ACTIVE AND EndDate <= :Date.today()]);
    }

    public void execute(Database.BatchableContext bc, List<Contract> contracts) {
        List<Contract> contractsToExpire = new List<Contract>();

        for (Contract contractRecord : contracts) {
            contractsToExpire.add(new Contract(Id = contractRecord.Id, Status = STATUS_EXPIRED));
        }

        List<Database.SaveResult> results = Database.update(contractsToExpire, false);
        List<Id> failedIds = new List<Id>();
        List<String> errors = new List<String>();

        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                failedIds.add(contractsToExpire[i].Id);
                errors.add(contractsToExpire[i].Id + ': ' + results[i].getErrors()[0].getMessage());
            }
        }

        if (!failedIds.isEmpty()) {
            Logger_CC.log(Logger_CC.ERROR, 'ContractExpirationBatch_CC failed to expire ' + failedIds.size() + ' contract(s): ' + String.join(errors, '; '), failedIds);
        }
    }

    public void finish(Database.BatchableContext bc) {
    }
}