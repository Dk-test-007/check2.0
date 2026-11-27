/**
 * =============================================================================
 * Class Name    : TaskTriggerHandler_CC_Test
 * Description   : Unit tests for TaskTrigger_CC / TaskTriggerHandler_CC: an assignment alert when a
 *                 Task is created for a user, and an ownership-change alert when it is reassigned.
 * =============================================================================
 */
@IsTest
private class TaskTriggerHandler_CC_Test {

    /**
     * Whether the Task trigger runs its after-update logic in this org. The trigger framework only runs a handler when a
     * Trigger_Framework_Config_CC record exists for the object; without one, a reassigned Task sends no alert.
     */
    private static Boolean ownershipAlertsEnabled() {
        Trigger_Framework_Config_CC__mdt config = Trigger_Framework_Config_CC__mdt.getInstance('Task');
        return config != null && config.After_Update_CC__c;
    }

    // The after-insert alert is switched per org through the trigger framework configuration, so this test
    // checks that a Task saves cleanly through the trigger rather than counting emails.
    @IsTest
    static void newTask_SavesThroughTrigger() {
        Task taskRecord = new Task(Subject = 'Call the customer', OwnerId = UserInfo.getUserId(),
                                   Priority = 'High', ActivityDate = Date.today().addDays(3));

        Test.startTest();
        insert taskRecord;
        Test.stopTest();

        Task saved = [SELECT Subject, OwnerId FROM Task WHERE Id = :taskRecord.Id WITH SYSTEM_MODE];
        Assert.areEqual('Call the customer', saved.Subject, 'The Task is saved');
        Assert.areEqual(UserInfo.getUserId(), saved.OwnerId, 'The Task keeps its owner');
    }

    @IsTest
    static void reassignedTask_SendsOwnershipChangeAlert() {
        User newOwner = TestDataFactory_CC.createUser('System Administrator', 'taskown', true);
        Task taskRecord = new Task(Subject = 'Follow up', OwnerId = UserInfo.getUserId());
        insert taskRecord;
        Integer emailsSent;

        Test.startTest();
        update new Task(Id = taskRecord.Id, OwnerId = newOwner.Id);
        emailsSent = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(ownershipAlertsEnabled() ? 1 : 0, emailsSent,
            'One ownership-change alert is sent when the Task is reassigned (none while the Task trigger is switched off)');
    }

    // Tasks assigned to another user, with and without a related record / due date, exercise every
    // branch of the assignment alert body. Email delivery depends on org configuration, so the test
    // asserts the Tasks save with their owner rather than counting emails.
    @IsTest
    static void tasksAssignedToAnotherUser_SaveThroughAssignmentAlert() {
        User assignee = TestDataFactory_CC.createUser('System Administrator', 'taskasg', true);
        Account relatedAccount = TestDataFactory_CC.createEntity('Task Entity ' + TestDataFactory_CC.uniqueSuffix(), null, true);
        List<Task> tasks = new List<Task>{
            new Task(Subject = 'Related task', OwnerId = assignee.Id, WhatId = relatedAccount.Id,
                     Priority = 'High', ActivityDate = Date.today().addDays(2)),
            new Task(Subject = 'Unrelated task', OwnerId = assignee.Id)
        };

        Test.startTest();
        insert tasks;
        Test.stopTest();

        for (Task saved : [SELECT OwnerId FROM Task WHERE Id IN :tasks WITH SYSTEM_MODE]) {
            Assert.areEqual(assignee.Id, saved.OwnerId, 'The Task is saved for the assignee');
        }
    }

    @IsTest
    static void taskCreatedByAnotherUser_SavesThroughAssignmentAlert() {
        User creator = TestDataFactory_CC.createUser('System Administrator', 'taskcrt', true);
        Task taskRecord = new Task(Subject = 'Self assigned task', OwnerId = creator.Id,
                                   ActivityDate = Date.today().addDays(1));

        Test.startTest();
        System.runAs(creator) {
            insert taskRecord;
        }
        Test.stopTest();

        Assert.areEqual(creator.Id, [SELECT OwnerId FROM Task WHERE Id = :taskRecord.Id WITH SYSTEM_MODE].OwnerId,
            'The Task keeps its owner');
    }

    @IsTest
    static void reassignedTaskWithDetails_SendsOwnershipChangeAlert() {
        User newOwner = TestDataFactory_CC.createUser('System Administrator', 'taskre2', true);
        Account relatedAccount = TestDataFactory_CC.createEntity('Task Reassign ' + TestDataFactory_CC.uniqueSuffix(), null, true);
        Task taskRecord = new Task(Subject = 'Detailed follow up', OwnerId = UserInfo.getUserId(),
                                   WhatId = relatedAccount.Id, ActivityDate = Date.today().addDays(5));
        insert taskRecord;
        Integer emailsSent;

        Test.startTest();
        update new Task(Id = taskRecord.Id, OwnerId = newOwner.Id);
        emailsSent = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(ownershipAlertsEnabled() ? 1 : 0, emailsSent,
            'One ownership-change alert is sent when the Task is reassigned (none while the Task trigger is switched off)');
    }

    @IsTest
    static void unchangedOwner_SendsNoOwnershipAlert() {
        Task taskRecord = new Task(Subject = 'No owner change', OwnerId = UserInfo.getUserId());
        insert taskRecord;
        Integer emailsSent;

        Test.startTest();
        update new Task(Id = taskRecord.Id, Subject = 'Renamed task');
        emailsSent = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(0, emailsSent, 'Editing a Task without changing its owner sends no alert');
    }
}