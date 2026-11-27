/**
 * =============================================================================
 * Class Name    : OpportunitySchedulerTest_CC
 * Description   : Unit tests for OpportunityScheduler_CC. Verifies that scheduling
 *                 registers a CronTrigger and that execute() launches
 *                 OpportunityStageReminderBatch_CC.
 * =============================================================================
 */
@IsTest
private class OpportunitySchedulerTest_CC {

    @TestSetup
    static void setupData() {
        Account entity = TestDataFactory_CC.createEntity('Scheduler Entity ' + TestDataFactory_CC.uniqueSuffix(), null, true);
        Opportunity expiredBau = TestDataFactory_CC.createOpportunity(entity.Id, 'BAU', false);
        expiredBau.Name = 'Scheduler Expired BAU';
        expiredBau.BAU_Opportunity_CC__c = true;
        expiredBau.CloseDate = Date.today().addDays(-3);
        insert expiredBau;
    }

    /**
     * System.schedule registers the job with the given cron expression and, when fired,
     * enqueues the active stage reminder batch.
     */
    @IsTest
    static void testScheduleRegistersJobAndEnqueuesBatches() {
        String cron = '0 0 6 * * ?';
        Test.startTest();
        Id cronId = System.schedule('OpportunitySchedulerTest ' + TestDataFactory_CC.uniqueSuffix(), cron, new OpportunityScheduler_CC());
        Test.stopTest();

        CronTrigger ct = [SELECT CronExpression, NextFireTime, CronJobDetail.JobType FROM CronTrigger WHERE Id = :cronId];
        Assert.areEqual(cron, ct.CronExpression, 'Cron expression should match');
        Assert.isNotNull(ct.NextFireTime, 'Next fire time should be set');
        Assert.areEqual('7', ct.CronJobDetail.JobType, 'Job should be a Scheduled Apex job');

        Set<String> batchClasses = new Set<String>();
        for (AsyncApexJob job : [SELECT ApexClass.Name FROM AsyncApexJob WHERE JobType = 'BatchApex']) {
            batchClasses.add(job.ApexClass.Name);
        }
        Assert.isTrue(batchClasses.contains('OpportunityStageReminderBatch_CC'), 'Stage reminder batch should be enqueued: ' + batchClasses);
    }

    /**
     * Calling execute() directly runs the active reminder batch. The BAU close
     * batch is disabled in OpportunityScheduler_CC.
     */
    @IsTest
    static void testExecuteRunsBothBatches() {
        Test.startTest();
        new OpportunityScheduler_CC().execute(null);
        Test.stopTest();

        List<AsyncApexJob> jobs = [SELECT ApexClass.Name, Status FROM AsyncApexJob WHERE JobType = 'BatchApex'];
        Assert.areEqual(1, jobs.size(), 'The active reminder batch should be launched');
        for (AsyncApexJob job : jobs) {
            Assert.areEqual('Completed', job.Status, job.ApexClass.Name + ' should complete');
        }
        Assert.isFalse([SELECT StageName FROM Opportunity WHERE Name = 'Scheduler Expired BAU'].StageName == 'Order',
            'The disabled close batch should not move the BAU Opportunity to Order');
    }
}