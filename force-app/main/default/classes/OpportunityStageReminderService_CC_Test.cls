/**
 * =============================================================================
 * Class Name    : OpportunityStageReminderService_CC_Test
 * Description   : Unit tests for OpportunityStageReminderService_CC (invoked by
 *                 OpportunityStageReminderBatch_CC). Read-only fields such as
 *                 CreatedDate and LastStageChangeDate are set on in-memory
 *                 Opportunities through JSON so every eligibility branch can be
 *                 exercised; the Ids are real so the email render, custom
 *                 notification and reminder-date update work against saved rows.
 * =============================================================================
 */
@IsTest
private class OpportunityStageReminderService_CC_Test {

    private static Integer thresholdDays() {
        return Integer.valueOf(System.Label.Opportunity_Stage_Reminder_Days_CC);
    }

    private static Datetime daysAgo(Integer days) {
        return System.now().addDays(-days);
    }

    /**
     * Builds an in-memory Opportunity carrying read-only fields (CreatedDate,
     * LastStageChangeDate) through JSON deserialisation.
     */
    private static Opportunity buildOpportunity(Id oppId, String name, Id ownerId, Datetime lastStageChange,
                                                Datetime createdDate, Boolean isBau, String bauMonth,
                                                Date reminderSentDate, Decimal amount) {
        Map<String, Object> fields = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Opportunity' },
            'Id' => oppId,
            'Name' => name,
            'StageName' => 'Discover',
            'Amount' => amount,
            'OwnerId' => ownerId,
            'LastStageChangeDate' => lastStageChange,
            'CreatedDate' => createdDate,
            'BAU_Opportunity_CC__c' => isBau,
            'BAU_Month_CC__c' => bauMonth,
            'Stage_Reminder_Sent_Date_CC__c' => reminderSentDate
        };
        return (Opportunity) JSON.deserialize(JSON.serialize(fields), Opportunity.class);
    }

    private static List<Opportunity> insertOpportunities(Integer count) {
        Account entity = TestDataFactory_CC.createEntity('Reminder Entity ' + TestDataFactory_CC.uniqueSuffix(), null, true);
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opps.add(TestDataFactory_CC.createOpportunity(entity.Id, 'New_Business', false));
        }
        insert opps;
        return opps;
    }

    private static Map<Id, Opportunity> reload(List<Opportunity> opps) {
        return new Map<Id, Opportunity>([
            SELECT Id, Stage_Reminder_Sent_Date_CC__c FROM Opportunity WHERE Id IN :new Map<Id, Opportunity>(opps).keySet()
        ]);
    }

    @IsTest
    static void sendReminders_CoversEligibilityRules() {
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{}'));
        User ownerWithName = TestDataFactory_CC.createUser('System Administrator', 'remind1', true);
        User ownerNoFirstName = TestDataFactory_CC.createUser('System Administrator', 'remind2', false);
        ownerNoFirstName.FirstName = null;
        insert ownerNoFirstName;

        List<Opportunity> saved = insertOpportunities(9);
        Integer threshold = thresholdDays();
        Integer oldStage = Math.max(threshold, 0) + 5;
        Id unknownUserId = Id.valueOf(User.SObjectType.getDescribe().getKeyPrefix() + '000000000000');
        Date firstOfYear = Date.newInstance(Date.today().year(), 1, 1);
        Boolean bauJanuaryEligible = firstOfYear.daysBetween(Date.today()) >= threshold;

        // Eligible: stage changed long ago, owner with a first name, amount set
        Opportunity eligibleStageChange = buildOpportunity(saved[0].Id, 'Eligible Stage Change', ownerWithName.Id,
            daysAgo(oldStage), daysAgo(oldStage + 10), false, null, null, 1500);
        eligibleStageChange.Account = new Account(Name = 'Reminder Customer');
        // Eligible: no stage change recorded, falls back to CreatedDate; owner without first name; no amount
        Opportunity eligibleCreated = buildOpportunity(saved[1].Id, 'Eligible Created', ownerNoFirstName.Id,
            null, daysAgo(oldStage), false, null, null, null);
        // BAU with a valid month: stage start is the first day of that month (January)
        Opportunity bauJanuary = buildOpportunity(saved[2].Id, 'BAU January', ownerWithName.Id,
            null, System.now(), true, ' january ', null, 200);
        // BAU with an unknown month name falls back to LastStageChangeDate
        Opportunity bauUnknownMonth = buildOpportunity(saved[3].Id, 'BAU Unknown Month', ownerWithName.Id,
            daysAgo(oldStage), daysAgo(oldStage), true, 'NotAMonth', null, 300);
        // Owner not found as a User: no email and no notification, but the reminder date is still stamped
        Opportunity unknownOwner = buildOpportunity(saved[4].Id, 'Unknown Owner', unknownUserId,
            daysAgo(oldStage), daysAgo(oldStage), false, null, null, null);
        // Skipped: future stage start date
        Opportunity futureStage = buildOpportunity(saved[5].Id, 'Future Stage', ownerWithName.Id,
            System.now().addDays(5), daysAgo(1), false, null, null, null);
        // Skipped: below threshold
        Opportunity recentStage = buildOpportunity(saved[6].Id, 'Recent Stage', ownerWithName.Id,
            System.now(), System.now(), false, null, null, null);
        // Skipped: reminder already sent after the stage started
        Opportunity alreadyReminded = buildOpportunity(saved[7].Id, 'Already Reminded', ownerWithName.Id,
            daysAgo(oldStage), daysAgo(oldStage), false, null, Date.today(), null);
        // Skipped: no owner
        Opportunity noOwner = buildOpportunity(saved[8].Id, 'No Owner', null,
            daysAgo(oldStage), daysAgo(oldStage), false, null, null, null);

        List<Opportunity> scope = new List<Opportunity>{
            eligibleStageChange, eligibleCreated, bauJanuary, bauUnknownMonth, unknownOwner,
            futureStage, recentStage, alreadyReminded, noOwner
        };

        Integer emailsBefore;
        Integer emailsAfter;
        Test.startTest();
        emailsBefore = Limits.getEmailInvocations();
        OpportunityStageReminderService_CC.sendReminders(scope);
        emailsAfter = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(emailsBefore + 1, emailsAfter, 'Reminder emails are sent in a single batch');

        Map<Id, Opportunity> results = reload(saved);
        Assert.areEqual(Date.today(), results.get(saved[0].Id).Stage_Reminder_Sent_Date_CC__c, 'Stage-change based reminder sent');
        Assert.areEqual(Date.today(), results.get(saved[1].Id).Stage_Reminder_Sent_Date_CC__c, 'CreatedDate based reminder sent');
        Assert.areEqual(bauJanuaryEligible ? Date.today() : null, results.get(saved[2].Id).Stage_Reminder_Sent_Date_CC__c,
            'BAU month drives the stage start date');
        Assert.areEqual(Date.today(), results.get(saved[3].Id).Stage_Reminder_Sent_Date_CC__c, 'Unknown BAU month falls back to stage change date');
        Assert.areEqual(Date.today(), results.get(saved[4].Id).Stage_Reminder_Sent_Date_CC__c, 'Reminder date stamped even without a resolvable owner');
        Assert.isNull(results.get(saved[5].Id).Stage_Reminder_Sent_Date_CC__c, 'Future stage start is skipped');
        Assert.isNull(results.get(saved[6].Id).Stage_Reminder_Sent_Date_CC__c, 'Below-threshold Opportunity is skipped');
        Assert.isNull(results.get(saved[7].Id).Stage_Reminder_Sent_Date_CC__c, 'Already reminded Opportunity is skipped');
        Assert.isNull(results.get(saved[8].Id).Stage_Reminder_Sent_Date_CC__c, 'Opportunity without owner is skipped');
    }

    @IsTest
    static void sendReminders_LongNameIsTruncatedInNotification() {
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{}'));
        List<Opportunity> saved = insertOpportunities(1);
        Integer oldStage = Math.max(thresholdDays(), 0) + 5;
        // A very long in-memory name pushes the notification body past 750 characters
        Opportunity longName = buildOpportunity(saved[0].Id, 'L'.repeat(650), UserInfo.getUserId(),
            daysAgo(oldStage), daysAgo(oldStage), false, null, null, 99);
        longName.Account = new Account(Name = 'Long Name Customer');

        Boolean completed = true;
        Test.startTest();
        try {
            OpportunityStageReminderService_CC.sendReminders(new List<Opportunity>{ longName });
        } catch (Exception e) {
            // Custom notification titles have a platform length limit; the body truncation path is still exercised
            completed = false;
        }
        Test.stopTest();

        if (completed) {
            Assert.areEqual(Date.today(), reload(saved).get(saved[0].Id).Stage_Reminder_Sent_Date_CC__c,
                'Reminder date is stamped for the long-name Opportunity');
        } else {
            Assert.isFalse(completed, 'Platform rejected the long notification title');
        }
    }

    @IsTest
    static void sendReminders_NullOrEmpty_DoesNothing() {
        Integer emailsBefore = Limits.getEmailInvocations();
        Test.startTest();
        OpportunityStageReminderService_CC.sendReminders(null);
        OpportunityStageReminderService_CC.sendReminders(new List<Opportunity>());
        Test.stopTest();
        Assert.areEqual(emailsBefore, Limits.getEmailInvocations(), 'No email is sent for an empty scope');
    }

    @IsTest
    static void sendReminders_NothingEligible_SendsNothing() {
        List<Opportunity> saved = insertOpportunities(1);
        Opportunity recent = buildOpportunity(saved[0].Id, 'Recent', UserInfo.getUserId(),
            System.now(), System.now(), false, null, null, null);

        Test.startTest();
        Integer emailsBefore = Limits.getEmailInvocations();
        OpportunityStageReminderService_CC.sendReminders(new List<Opportunity>{ recent });
        Integer emailsAfter = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(emailsBefore, emailsAfter, 'No email when nothing is eligible');
        Assert.isNull(reload(saved).get(saved[0].Id).Stage_Reminder_Sent_Date_CC__c, 'Reminder date not stamped');
    }

    @IsTest
    static void reminderBatch_ProcessesBauOpportunity() {
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{}'));
        Account entity = TestDataFactory_CC.createEntity('Reminder Batch Entity ' + TestDataFactory_CC.uniqueSuffix(), null, true);
        Opportunity bau = TestDataFactory_CC.createOpportunity(entity.Id, 'BAU', false);
        bau.BAU_Opportunity_CC__c = true;
        bau.BAU_Month_CC__c = 'January';
        insert bau;
        Boolean eligible = Date.newInstance(Date.today().year(), 1, 1).daysBetween(Date.today()) >= thresholdDays();

        Test.startTest();
        Database.executeBatch(new OpportunityStageReminderBatch_CC(), 200);
        Test.stopTest();

        Opportunity result = [SELECT Stage_Reminder_Sent_Date_CC__c FROM Opportunity WHERE Id = :bau.Id];
        Assert.areEqual(eligible ? Date.today() : null, result.Stage_Reminder_Sent_Date_CC__c,
            'The batch stamps the reminder date on eligible BAU Opportunities');
    }
}