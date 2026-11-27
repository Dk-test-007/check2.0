@IsTest
private class ContractExpirationBatch_CCTest {
    private static final String CRON_EXPRESSION = '0 0 1 * * ?';

    @TestSetup
    static void setupData() {
        Id entityId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Entity').getRecordTypeId();
        Account entity = new Account(Name = 'Contract Entity', RecordTypeId = entityId, Type = 'Customer');
        insert entity;

        Date today = Date.today();

        Contract pastActive = new Contract(Name = 'Past Active', AccountId = entity.Id, StartDate = today.addDays(-30), EndDate = today.addDays(-1));
        Contract endingToday = new Contract(Name = 'Ending Today', AccountId = entity.Id, StartDate = today.addDays(-30), EndDate = today);
        Contract futureActive = new Contract(Name = 'Future Active', AccountId = entity.Id, StartDate = today.addDays(-30), EndDate = today.addDays(30));
        Contract pastDraft = new Contract(Name = 'Past Draft', AccountId = entity.Id, StartDate = today.addDays(-30), EndDate = today.addDays(-1));
        insert new List<Contract>{ pastActive, endingToday, futureActive, pastDraft };

        pastActive.Status = ContractExpirationBatch_CC.STATUS_ACTIVE;
        endingToday.Status = ContractExpirationBatch_CC.STATUS_ACTIVE;
        futureActive.Status = ContractExpirationBatch_CC.STATUS_ACTIVE;
        update new List<Contract>{ pastActive, endingToday, futureActive };
    }

    private static Map<String, Contract> getContractsByName() {
        Map<String, Contract> contractsByName = new Map<String, Contract>();

        for (Contract contractRecord : [
            SELECT Id, Name, Status, EndDate
            FROM Contract
        ]) {
            contractsByName.put(contractRecord.Name, contractRecord);
        }

        return contractsByName;
    }

    /**
     * The status the batch can give an ended contract. The batch writes 'Expired'; when the org's Contract Status
     * picklist has no such value (it is named 'Contract Expired' in some orgs), the save is refused and logged, so
     * the contract stays Active.
     */
    private static String expectedEndedStatus() {
        for (Schema.PicklistEntry entry : Contract.Status.getDescribe().getPicklistValues()) {
            if (entry.isActive() && entry.getValue() == ContractExpirationBatch_CC.STATUS_EXPIRED) {
                return ContractExpirationBatch_CC.STATUS_EXPIRED;
            }
        }
        return ContractExpirationBatch_CC.STATUS_ACTIVE;
    }

    @IsTest
    static void testBatchExpiresOnlyContractsEndingToday() {
        Test.startTest();
        Database.executeBatch(new ContractExpirationBatch_CC(), 200);
        Test.stopTest();

        Map<String, Contract> contractsByName = getContractsByName();
        String endedStatus = expectedEndedStatus();

        System.assertEquals(
            endedStatus,
            contractsByName.get('Past Active').Status,
            'Active contracts whose End Date has passed should expire (the batch selects End Date on or before today).'
        );
        System.assertEquals(
            endedStatus,
            contractsByName.get('Ending Today').Status,
            'Active contracts ending today should become Expired.'
        );
        System.assertEquals(
            'Active',
            contractsByName.get('Future Active').Status,
            'Active contracts with a future End Date should remain Active.'
        );
        System.assertEquals(
            'Draft',
            contractsByName.get('Past Draft').Status,
            'Draft contracts should not be expired.'
        );
    }

    @IsTest
    static void testScheduleDaily() {
        Test.startTest();

        String jobId = System.schedule(
            'Contract Expiration Batch - Daily 1 AM Test',
            CRON_EXPRESSION,
            new ContractExpirationBatch_CC()
        );

        CronTrigger scheduledJob = [
            SELECT Id, CronExpression, State
            FROM CronTrigger
            WHERE Id = :jobId
        ];

        System.assertEquals(
            CRON_EXPRESSION,
            scheduledJob.CronExpression,
            'The job should be scheduled daily at 1 AM.'
        );

        Test.stopTest();
    }

    @IsTest
    static void testSchedulableExecute() {
        Test.startTest();
        new ContractExpirationBatch_CC().execute((SchedulableContext)null);
        Test.stopTest();

        Map<String, Contract> contractsByName = getContractsByName();

        System.assertEquals(
            expectedEndedStatus(),
            contractsByName.get('Ending Today').Status,
            'Schedulable execution should launch the batch and expire contracts ending today.'
        );
    }
}
