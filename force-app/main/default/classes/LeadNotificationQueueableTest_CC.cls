@isTest(SeeAllData=true)
private class LeadNotificationQueueableTest_CC {

    private static final Set<String> TARGET_QUEUES = new Set<String>{'UK_Marketing_Pool', 'US_Marketing_Pool', 'UK_Sales_Pool', 'US_Sales_Pool'};

    private static String defaultLeadStatus() {
        List<Schema.PicklistEntry> entries = Lead.Status.getDescribe().getPicklistValues();
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isDefaultValue()) {
                return entry.getValue();
            }
        }
        return entries[0].getValue();
    }

    private static Lead buildLead(String lastName, Id ownerId) {
        return new Lead(
            FirstName = 'Test',
            LastName = lastName,
            Company = 'Carlton Test ' + lastName,
            Status = defaultLeadStatus(),
            Email = lastName.toLowerCase() + '@carlton.test.invalid',
            Phone = '+44 20 7000 0000',
            OwnerId = ownerId
        );
    }

    private static User createUser(String alias) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName = 'Queueable',
            LastName = alias,
            Alias = alias.left(8),
            Email = alias + '@carlton.test.invalid',
            Username = alias + System.currentTimeMillis() + '@carlton.test.invalid',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_GB',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            IsActive = true
        );
        insert u;
        return u;
    }

    private static Group ensureQueue(String devName, String label) {
        List<Group> existing = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :devName LIMIT 1];
        Group q;
        if (existing.isEmpty()) {
            q = new Group(Name = label, DeveloperName = devName, Type = 'Queue');
            insert q;
        } else {
            q = existing[0];
        }
        if ([SELECT COUNT() FROM QueueSObject WHERE QueueId = :q.Id AND SObjectType = 'Lead'] == 0) {
            insert new QueueSObject(QueueId = q.Id, SObjectType = 'Lead');
        }
        return q;
    }

    private static Group resolveTargetQueue() {
        List<Group> queues = [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND DeveloperName IN :TARGET_QUEUES LIMIT 1];
        return ensureQueue(queues.isEmpty() ? 'UK_Marketing_Pool' : queues[0].DeveloperName, 'UK Marketing Pool');
    }

    private static void insertLeads(List<Lead> leads) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        dmo.AssignmentRuleHeader.UseDefaultRule = false;
        dmo.EmailHeader.TriggerUserEmail = false;
        dmo.EmailHeader.TriggerAutoResponseEmail = false;
        Database.insert(leads, dmo);
    }

    @isTest
    static void testNoLeadsToProcess() {
        Test.startTest();
        new LeadAssignmentNotificationQueueable_CC(new Set<Id>()).execute(null);
        new LeadAssignmentNotificationQueueable_CC((Set<Id>) null).execute(null);
        new LeadAssignmentNotificationQueueable_CC(new Set<Id>{'00Q000000000001AAA'}).execute(null);
        Test.stopTest();
    }

    @isTest
    static void testUserOwnerNotification() {
        User owner;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            owner = createUser('lanqusr');
        }
        List<Lead> leads = new List<Lead>{buildLead('Alpha', owner.Id), buildLead('Bravo', owner.Id)};
        insertLeads(leads);
        Set<Id> leadIds = new Map<Id, Lead>(leads).keySet();
        Test.startTest();
        System.enqueueJob(new LeadAssignmentNotificationQueueable_CC(leadIds));
        Test.stopTest();
    }

    @isTest
    static void testQueueOwnerNotification() {
        Group queue;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            queue = resolveTargetQueue();
            User member = createUser('lanqmem');
            Group publicGroup = new Group(Name = 'LANQ Test Group', DeveloperName = 'LANQ_Test_Group_' + Math.abs(Crypto.getRandomInteger()), Type = 'Regular');
            insert publicGroup;
            insert new List<GroupMember>{
                new GroupMember(GroupId = queue.Id, UserOrGroupId = member.Id),
                new GroupMember(GroupId = queue.Id, UserOrGroupId = publicGroup.Id)
            };
        }
        List<Lead> leads = new List<Lead>{buildLead('Charlie', queue.Id), buildLead('Delta', queue.Id)};
        insertLeads(leads);
        Set<Id> leadIds = new Map<Id, Lead>(leads).keySet();
        Test.startTest();
        System.enqueueJob(new LeadAssignmentNotificationQueueable_CC(leadIds));
        Test.stopTest();
    }

    @isTest
    static void testNonTargetQueueOwnerSkipped() {
        Group queue;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            queue = ensureQueue('LANQ_Non_Target_Pool', 'LANQ Non Target Pool');
        }
        List<Lead> leads = new List<Lead>{buildLead('Echo', queue.Id)};
        insertLeads(leads);
        Test.startTest();
        new LeadAssignmentNotificationQueueable_CC(new Map<Id, Lead>(leads).keySet()).execute(null);
        Test.stopTest();
    }
}