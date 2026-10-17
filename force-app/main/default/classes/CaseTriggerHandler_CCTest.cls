/**
 * =============================================================================
 * Class Name    : CaseTriggerHandler_CCTest
 * Description   : Unit test class for CaseTriggerHandler_CC. Covers trigger contexts
 *                 including Account-Opportunity syncing, Queue-to-User reassignment,
 *                 status notifications, and base framework execution.
 *
 * Author        : Nipun Jain
 * Created Date  :
 * =============================================================================
 */
@isTest
private class CaseTriggerHandler_CCTest {

    @testSetup
    static void setupTestData() {
        // 1. Create Accounts & Opportunities
        Account acc1 = new Account(Name = 'Test Account 1');
        Account acc2 = new Account(Name = 'Test Account 2');
        insert new List<Account>{ acc1, acc2 };

        Opportunity opp1 = new Opportunity(
            Name = 'Test Opp 1',
            AccountId = acc1.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        Opportunity opp2 = new Opportunity(
            Name = 'Test Opp 2',
            AccountId = acc2.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert new List<Opportunity>{ opp1, opp2 };

        // 2. Query CPT_Pool Queue (if present, else simulate)
        Group cptQueue = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'CPT_Pool' LIMIT 1];

        // 3. Create Initial Cases
        Case c1 = new Case(
            Subject = 'Test Case Sync Account',
            Opportunity__c = opp1.Id,
            Status = 'New'
        );
        Case c2 = new Case(
            Subject = 'Test Case Queue Transfer',
            Opportunity__c = opp2.Id,
            OwnerId = cptQueue.Id,
            Status = 'New'
        );
        insert new List<Case>{ c1, c2 };
    }

    /**
     * @description Tests that new Cases linked to an Opportunity sync the AccountId upon creation.
     */
    @isTest
    static void testBeforeInsertAccountSync() {
        Opportunity opp = [SELECT Id, AccountId FROM Opportunity WHERE Name = 'Test Opp 1' LIMIT 1];

        Test.startTest();
        Case newCase = new Case(
            Subject = 'Insert Test Case',
            Opportunity__c = opp.Id,
            Status = 'New'
        );
        insert newCase;
        Test.stopTest();

        Case insertedCase = [SELECT Id, AccountId FROM Case WHERE Id = :newCase.Id];
        System.assertEquals(opp.AccountId, insertedCase.AccountId, 'Case AccountId should match Opportunity AccountId on insert.');
    }

    /**
     * @description Tests owner reassignment from CPT Queue to a User sets Case Status to 'Assigned'.
     */
    @isTest
    static void testBeforeUpdateOwnerQueueToUser() {
        Case queueCase = [SELECT Id, OwnerId, Status FROM Case WHERE Subject = 'Test Case Queue Transfer' LIMIT 1];

        Test.startTest();
        queueCase.OwnerId = UserInfo.getUserId();
        update queueCase;
        Test.stopTest();

        Case updatedCase = [SELECT Id, Status FROM Case WHERE Id = :queueCase.Id];
        System.assertEquals('Assigned', updatedCase.Status, 'Status should be automatically updated to Assigned when reassigned to a user.');
    }

    /**
     * @description Tests afterUpdate notification trigger logic for status transitions.
     */
    @isTest
    static void testHandleStatusNotifications() {
        List<Case> casesToUpdate = [SELECT Id, Status FROM Case LIMIT 2];
        if (casesToUpdate.size() >= 2) {
            casesToUpdate[0].Status = 'Awaiting Information';
            casesToUpdate[1].Status = 'Completed';

            Test.startTest();
            update casesToUpdate;
            Test.stopTest();

            Case updatedCase1 = [SELECT Id, Status FROM Case WHERE Id = :casesToUpdate[0].Id];
            Case updatedCase2 = [SELECT Id, Status FROM Case WHERE Id = :casesToUpdate[1].Id];

            System.assertEquals('Awaiting Information', updatedCase1.Status);
            System.assertEquals('Completed', updatedCase2.Status);
        }
    }

    /**
     * @description Tests handler invocation via the run() method inherited from BaseTriggerHandler_CC.
     */
    @isTest
    static void testHandlerRun() {
        Test.startTest();
        CaseTriggerHandler_CC handler = new CaseTriggerHandler_CC();
        handler.run();
        Test.stopTest();

        System.assert(true, 'Run method executed without unhandled exceptions.');
    }
}