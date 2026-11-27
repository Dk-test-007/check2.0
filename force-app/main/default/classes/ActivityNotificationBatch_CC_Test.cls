/**
 * =============================================================================
 * Class Name    : ActivityNotificationBatch_CC_Test
 * Description   : Unit tests for ActivityNotificationBatch_CC: upcoming and overdue
 *                 reminders for Events and Tasks, run as a batch, through the
 *                 Schedulable entry point and by calling execute() directly.
 * =============================================================================
 */
@IsTest
private class ActivityNotificationBatch_CC_Test {

    private static final String CRON_EXPRESSION = '0 0 * * * ?';

    private static User createOwner(String aliasSeed) {
        return TestDataFactory_CC.createUser('System Administrator', aliasSeed, true);
    }

    private static Account createAccount() {
        return TestDataFactory_CC.createEntity('Activity Entity ' + TestDataFactory_CC.uniqueSuffix(), null, true);
    }

    /** One upcoming Event (starts within the hour) and one just-ended Event (overdue). */
    private static List<Event> createEvents(Id ownerId, Id whatId) {
        Datetime now = System.now();
        Event upcoming = new Event(
            Subject = 'Upcoming customer meeting',
            OwnerId = ownerId,
            WhatId = whatId,
            StartDateTime = now.addMinutes(30),
            EndDateTime = now.addMinutes(90)
        );
        Event ended = new Event(
            Subject = 'Ended customer meeting',
            OwnerId = ownerId,
            StartDateTime = now.addMinutes(-90),
            EndDateTime = now.addMinutes(-30)
        );
        List<Event> events = new List<Event>{ upcoming, ended };
        insert events;
        return events;
    }

    /** One Task due today (reminder) and one overdue Task. */
    private static List<Task> createTasks(Id ownerId, Id whatId) {
        Task dueToday = new Task(
            Subject = 'Call customer today',
            OwnerId = ownerId,
            WhatId = whatId,
            Priority = 'High',
            Status = 'Open',
            ActivityDate = Date.today()
        );
        Task overdue = new Task(
            Subject = 'Overdue follow up',
            OwnerId = ownerId,
            Status = 'Open',
            ActivityDate = Date.today().addDays(-3)
        );
        List<Task> tasks = new List<Task>{ dueToday, overdue };
        insert tasks;
        return tasks;
    }

    // ------------------------------------------------------------------ batch runs

    @IsTest
    static void eventBatch_RunsForUpcomingAndOverdueEvents() {
        User owner = createOwner('evtbatch');
        Account acc = createAccount();
        createEvents(owner.Id, acc.Id);

        Test.startTest();
        Id jobId = Database.executeBatch(new ActivityNotificationBatch_CC('Event'), 200);
        Test.stopTest();

        AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE Id = :jobId];
        Assert.areEqual('Completed', job.Status, 'The Event batch completes');
        Assert.areEqual(0, job.NumberOfErrors, 'The Event batch completes without errors');
    }

    @IsTest
    static void taskBatch_RunsForDueAndOverdueTasks() {
        User owner = createOwner('tskbatch');
        Account acc = createAccount();
        createTasks(owner.Id, acc.Id);

        Test.startTest();
        Id jobId = Database.executeBatch(new ActivityNotificationBatch_CC('Task'), 200);
        Test.stopTest();

        AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE Id = :jobId];
        Assert.areEqual('Completed', job.Status, 'The Task batch completes');
        Assert.areEqual(0, job.NumberOfErrors, 'The Task batch completes without errors');
    }

    // ------------------------------------------------------------------ direct execute (deterministic scope)

    @IsTest
    static void execute_Events_SendsReminderAndOverdueEmails() {
        User owner = createOwner('evtexec');
        Account acc = createAccount();
        List<Event> events = createEvents(owner.Id, acc.Id);

        List<Event> scope = [
            SELECT Id, Subject, OwnerId, Owner.FirstName, Owner.Email, StartDateTime, EndDateTime, ActivityDate, WhatId
            FROM Event
            WHERE Id IN :events
        ];
        Assert.areEqual(2, scope.size(), 'Both Events are in scope');

        ActivityNotificationBatch_CC batch = new ActivityNotificationBatch_CC();
        Test.startTest();
        Integer emailsBefore = Limits.getEmailInvocations();
        batch.execute((Database.BatchableContext) null, scope);
        Integer emailsAfter = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(emailsBefore + 1, emailsAfter, 'Event notifications are sent in one call');
    }

    @IsTest
    static void execute_Tasks_SendsReminderAndOverdueEmails() {
        User owner = createOwner('tskexec');
        Account acc = createAccount();
        List<Task> tasks = createTasks(owner.Id, acc.Id);
        // A Task without a due date exercises the 'N/A' due date path
        Task noDueDate = new Task(Subject = 'No due date', OwnerId = owner.Id, Status = 'Open');
        insert noDueDate;

        Set<Id> taskIds = new Set<Id>{ tasks[0].Id, tasks[1].Id, noDueDate.Id };
        List<Task> scope = [
            SELECT Id, Subject, OwnerId, Owner.FirstName, Owner.Email, ActivityDate, Priority, WhatId
            FROM Task
            WHERE Id IN :taskIds
        ];
        Assert.areEqual(3, scope.size(), 'All Tasks are in scope');

        ActivityNotificationBatch_CC batch = new ActivityNotificationBatch_CC('Task');
        Test.startTest();
        Integer emailsBefore = Limits.getEmailInvocations();
        batch.execute((Database.BatchableContext) null, scope);
        Integer emailsAfter = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(emailsBefore + 1, emailsAfter, 'Task notifications are sent in one call');
    }

    @IsTest
    static void execute_EmptyScope_SendsNothing() {
        ActivityNotificationBatch_CC batch = new ActivityNotificationBatch_CC('Task');
        Test.startTest();
        Integer emailsBefore = Limits.getEmailInvocations();
        batch.execute((Database.BatchableContext) null, new List<SObject>());
        Integer emailsAfter = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(emailsBefore, emailsAfter, 'No email is sent for an empty scope');
    }

    // ------------------------------------------------------------------ Schedulable

    @IsTest
    static void schedulableExecute_LaunchesBatch() {
        Test.startTest();
        new ActivityNotificationBatch_CC('Task').execute((SchedulableContext) null);
        Test.stopTest();

        List<AsyncApexJob> jobs = [
            SELECT Status FROM AsyncApexJob
            WHERE JobType = 'BatchApex' AND ApexClass.Name = 'ActivityNotificationBatch_CC'
        ];
        Assert.areEqual(1, jobs.size(), 'The schedulable entry point launches the batch');
        Assert.areEqual('Completed', jobs[0].Status, 'The launched batch completes');
    }

    @IsTest
    static void systemSchedule_RegistersJob() {
        Test.startTest();
        Id cronId = System.schedule('Activity Notification Test ' + TestDataFactory_CC.uniqueSuffix(),
            CRON_EXPRESSION, new ActivityNotificationBatch_CC());
        Test.stopTest();

        CronTrigger ct = [SELECT CronExpression FROM CronTrigger WHERE Id = :cronId];
        Assert.areEqual(CRON_EXPRESSION, ct.CronExpression, 'The batch is scheduled with the cron expression');
    }
}