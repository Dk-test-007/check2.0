/**
 * =============================================================================
 * Class Name    : BAUOpportunity_CC_Test
 * Description   : Unit tests for the BAU Opportunity automation:
 *                 BAUOpportunityService_CC, BAUOpportunityBatch_CC,
 *                 BAUOpportunityCloseBatch_CC, BAUOpportunityQueueable_CC and
 *                 BAUOpportunityScheduler_CC.
 * =============================================================================
 */
@IsTest
private class BAUOpportunity_CC_Test {

    private static final String CRON_EXPRESSION = '0 0 5 * * ?';

    // ------------------------------------------------------------------ helpers

    private static Account createBauEntity(String name, Boolean isBau) {
        Account entity = TestDataFactory_CC.createEntity(name, null, false);
        entity.Is_BAU_Account_CC__c = isBau;
        insert entity;
        return entity;
    }

    private static List<Account> queryAccounts(Set<Id> accountIds) {
        return [
            SELECT Id, Name, OwnerId, Is_BAU_Account_CC__c, Opportunity_Creation_Year_CC__c
            FROM Account
            WHERE Id IN :accountIds
        ];
    }

    private static Integer countBauOpportunities(Id accountId) {
        return [
            SELECT COUNT()
            FROM Opportunity
            WHERE AccountId = :accountId
            AND BAU_Opportunity_CC__c = TRUE
        ];
    }

    /** Number of BAU Opportunities expected for a fresh Account: one per remaining month of the year. */
    private static Integer expectedMonthlyOpportunities() {
        return 13 - Date.today().month();
    }

    private static Date lastDayOfCurrentMonth() {
        Date firstDay = Date.newInstance(Date.today().year(), Date.today().month(), 1);
        return firstDay.addMonths(1).addDays(-1);
    }

    private static void setCalloutMock() {
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{}'));
    }

    // ------------------------------------------------------------------ BAUOpportunityService_CC.createBAUOpportunities

    @IsTest
    static void createBAUOpportunities_CreatesOnePerRemainingMonthAndSkipsExisting() {
        setCalloutMock();
        // A long name forces the Opportunity name to be truncated to fit 120 characters
        String longName = 'BAU Long Entity ' + 'X'.repeat(150);
        Account bauAccount = createBauEntity(longName.left(200), true);
        Account nonBauAccount = createBauEntity('Non BAU Entity ' + TestDataFactory_CC.uniqueSuffix(), false);

        // Existing BAU Opportunity for the current month must not be duplicated
        Opportunity existing = TestDataFactory_CC.createOpportunity(bauAccount.Id, 'BAU', false);
        existing.BAU_Opportunity_CC__c = true;
        existing.CloseDate = lastDayOfCurrentMonth();
        insert existing;

        List<Account> accounts = queryAccounts(new Set<Id>{ bauAccount.Id, nonBauAccount.Id });

        Test.startTest();
        BAUOpportunityService_CC.createBAUOpportunities(accounts);
        Test.stopTest();

        // existing (current month) + one per remaining month after the current one
        Assert.areEqual(expectedMonthlyOpportunities(), countBauOpportunities(bauAccount.Id),
            'One BAU Opportunity per month from the current month to December, without duplicating the existing one');
        Assert.areEqual(0, countBauOpportunities(nonBauAccount.Id), 'Non-BAU Accounts get no BAU Opportunities');

        for (Opportunity opp : [
            SELECT Name, StageName, BAU_Month_CC__c, RecordType.DeveloperName, CloseDate
            FROM Opportunity
            WHERE AccountId = :bauAccount.Id AND Id != :existing.Id
        ]) {
            Assert.isTrue(opp.Name.length() <= 120, 'Opportunity name is truncated to 120 characters: ' + opp.Name);
            Assert.isTrue(opp.Name.contains(' - BAU - '), 'Opportunity name carries the BAU suffix');
            Assert.areEqual('Request', opp.StageName, 'BAU Opportunities start in Request');
            Assert.areEqual('BAU', opp.RecordType.DeveloperName, 'BAU record type is used');
            Assert.isNotNull(opp.BAU_Month_CC__c, 'BAU month is populated');
        }

        Map<Id, Account> updated = new Map<Id, Account>(queryAccounts(new Set<Id>{ bauAccount.Id, nonBauAccount.Id }));
        Assert.areEqual(String.valueOf(Date.today().year()), updated.get(bauAccount.Id).Opportunity_Creation_Year_CC__c,
            'The creation year is stamped on the BAU Account');
        Assert.isNull(updated.get(nonBauAccount.Id).Opportunity_Creation_Year_CC__c,
            'The creation year is not stamped on non-BAU Accounts');
    }

    @IsTest
    static void createBAUOpportunities_NoBauAccounts_DoesNothing() {
        setCalloutMock();
        Account nonBauAccount = createBauEntity('Plain Entity ' + TestDataFactory_CC.uniqueSuffix(), false);

        Test.startTest();
        BAUOpportunityService_CC.createBAUOpportunities(queryAccounts(new Set<Id>{ nonBauAccount.Id }));
        Test.stopTest();

        Assert.areEqual(0, countBauOpportunities(nonBauAccount.Id), 'No Opportunities for non-BAU Accounts');
    }

    @IsTest
    static void createBAUOpportunities_RunTwice_IsIdempotent() {
        setCalloutMock();
        Account bauAccount = createBauEntity('Idempotent Entity ' + TestDataFactory_CC.uniqueSuffix(), true);

        Test.startTest();
        BAUOpportunityService_CC.createBAUOpportunities(queryAccounts(new Set<Id>{ bauAccount.Id }));
        BAUOpportunityService_CC.createBAUOpportunities(queryAccounts(new Set<Id>{ bauAccount.Id }));
        Test.stopTest();

        Assert.areEqual(expectedMonthlyOpportunities(), countBauOpportunities(bauAccount.Id),
            'Running the service twice does not duplicate monthly Opportunities');
    }

    // ------------------------------------------------------------------ BAUOpportunityBatch_CC

    @IsTest
    static void bauBatch_WithAccountIds_CreatesOpportunities() {
        setCalloutMock();
        Account bauAccount = createBauEntity('Batch Entity ' + TestDataFactory_CC.uniqueSuffix(), true);

        Test.startTest();
        Database.executeBatch(new BAUOpportunityBatch_CC(new Set<Id>{ bauAccount.Id }), 200);
        Test.stopTest();

        Assert.areEqual(expectedMonthlyOpportunities(), countBauOpportunities(bauAccount.Id),
            'The batch creates BAU Opportunities for the scoped Account');
    }

    @IsTest
    static void bauBatch_ScheduledExecute_ProcessesAllBauAccounts() {
        setCalloutMock();
        Account bauAccount = createBauEntity('Sched Batch Entity ' + TestDataFactory_CC.uniqueSuffix(), true);

        Test.startTest();
        new BAUOpportunityBatch_CC().execute((SchedulableContext) null);
        Test.stopTest();

        Assert.areEqual(expectedMonthlyOpportunities(), countBauOpportunities(bauAccount.Id),
            'The unscoped batch processes every BAU Entity Account');
    }

    // ------------------------------------------------------------------ BAUOpportunityScheduler_CC

    @IsTest
    static void bauScheduler_ExecuteLaunchesBatch() {
        setCalloutMock();
        Account bauAccount = createBauEntity('Scheduler Entity ' + TestDataFactory_CC.uniqueSuffix(), true);

        Test.startTest();
        new BAUOpportunityScheduler_CC().execute(null);
        Test.stopTest();

        Assert.areEqual(expectedMonthlyOpportunities(), countBauOpportunities(bauAccount.Id),
            'The scheduler launches the BAU Opportunity batch');
    }

    @IsTest
    static void bauScheduler_SystemSchedule_RegistersJob() {
        Test.startTest();
        Id jobId = System.schedule('BAU Opportunity Scheduler Test ' + TestDataFactory_CC.uniqueSuffix(),
            CRON_EXPRESSION, new BAUOpportunityScheduler_CC());
        Test.stopTest();

        CronTrigger ct = [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual(CRON_EXPRESSION, ct.CronExpression, 'The scheduler is registered with the cron expression');
    }

    // ------------------------------------------------------------------ BAUOpportunityQueueable_CC

    @IsTest
    static void bauQueueable_WithAccountIds_EnqueuesBatch() {
        setCalloutMock();
        Account bauAccount = createBauEntity('Queueable Entity ' + TestDataFactory_CC.uniqueSuffix(), true);

        Test.startTest();
        Id jobId = System.enqueueJob(new BAUOpportunityQueueable_CC(new Set<Id>{ bauAccount.Id }));
        Test.stopTest();

        Assert.isNotNull(jobId, 'The queueable is enqueued');
        Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE Id = :jobId], 'The queueable job is recorded');
    }

    @IsTest
    static void bauQueueable_EmptyOrNullIds_DoesNothing() {
        Test.startTest();
        new BAUOpportunityQueueable_CC(new Set<Id>()).execute(null);
        new BAUOpportunityQueueable_CC(null).execute(null);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex'],
            'No batch is launched without Account Ids');
    }

    // ------------------------------------------------------------------ BAUOpportunityCloseBatch_CC / closeExpiredBAUOpportunities

    @IsTest
    static void bauCloseBatch_MovesExpiredBauOpportunitiesToOrder() {
        setCalloutMock();
        Account entity = createBauEntity('Close Entity ' + TestDataFactory_CC.uniqueSuffix(), false);

        Opportunity expired = TestDataFactory_CC.createOpportunity(entity.Id, 'BAU', false);
        expired.BAU_Opportunity_CC__c = true;
        expired.CloseDate = Date.today().addDays(-5);

        Opportunity current = TestDataFactory_CC.createOpportunity(entity.Id, 'BAU', false);
        current.BAU_Opportunity_CC__c = true;
        current.CloseDate = Date.today().addDays(10);
        insert new List<Opportunity>{ expired, current };

        Test.startTest();
        Database.executeBatch(new BAUOpportunityCloseBatch_CC(), 200);
        Test.stopTest();

        Map<Id, Opportunity> results = new Map<Id, Opportunity>([
            SELECT StageName FROM Opportunity WHERE Id IN :new Set<Id>{ expired.Id, current.Id }
        ]);
        Assert.areEqual('Order', results.get(expired.Id).StageName, 'Expired BAU Opportunities move to Order');
        Assert.areEqual('Request', results.get(current.Id).StageName, 'BAU Opportunities not yet expired are untouched');
    }

    @IsTest
    static void closeExpiredBAUOpportunities_NewBusinessMovesToClosedWon() {
        setCalloutMock();
        Account entity = createBauEntity('Close NB Entity ' + TestDataFactory_CC.uniqueSuffix(), false);
        Opportunity newBusiness = TestDataFactory_CC.createOpportunity(entity.Id, 'New_Business', true);

        List<Opportunity> scope = [
            SELECT Id, StageName, CloseDate, RecordType.DeveloperName
            FROM Opportunity
            WHERE Id = :newBusiness.Id
        ];

        Test.startTest();
        BAUOpportunityService_CC.closeExpiredBAUOpportunities(scope);
        Test.stopTest();

        Assert.areEqual('Closed Won', [SELECT StageName FROM Opportunity WHERE Id = :newBusiness.Id].StageName,
            'New Business Opportunities are closed as won');
    }

    @IsTest
    static void closeExpiredBAUOpportunities_NullOrEmpty_DoesNothing() {
        Test.startTest();
        BAUOpportunityService_CC.closeExpiredBAUOpportunities(null);
        BAUOpportunityService_CC.closeExpiredBAUOpportunities(new List<Opportunity>());
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity], 'Nothing is updated for an empty scope');
    }
}