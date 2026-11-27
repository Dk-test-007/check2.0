/**
 * Tests for LeadEntityDefault_CC: known US, no queue, both regions and inactive (UK LLP) contexts. Expectations follow
 * the org's active Belongs_To_CC__c values, so they hold before and after LLP is activated.
 * Uses the org's real regional queues, which Lead routing also depends on. Runs as the System Administrator running the
 * tests, whose regional queue memberships are set per test (rolled back with the test).
 */
@isTest
private class LeadEntityDefault_CC_Test {

    @isTest
    static void usQueueMember_GetsActiveUsEntity() {
        User usUser = adminInQueues(new List<String>{ 'US_Sales_Pool' });

        LeadEntityDefault_CC.Result result;
        Test.startTest();
        System.runAs(usUser) {
            result = LeadEntityDefault_CC.suggestForRunningUser()[0];
        }
        Test.stopTest();

        Boolean usActive = isActive(LeadEntityDefault_CC.US_ENTITY);
        Assert.areEqual(usActive ? LeadEntityDefault_CC.US_ENTITY : null, result.entityValue, 'US pool member should default to INC');
        Assert.areEqual(usActive ? LeadEntityDefault_CC.RESULT_DEFAULTED : LeadEntityDefault_CC.RESULT_UNAVAILABLE, result.outcome,
            'Outcome should reflect the active value');
    }

    @isTest
    static void noRegionalQueue_GetsTheOnlyActiveEntityOrNothing() {
        User otherUser = adminInQueues(new List<String>());

        LeadEntityDefault_CC.Result result;
        System.runAs(otherUser) {
            result = LeadEntityDefault_CC.suggestForRunningUser()[0];
        }

        String onlyActive = onlyActiveValue();
        Assert.areEqual(onlyActive, result.entityValue, 'Without a queue, only a single active Entity may be suggested');
        Assert.areEqual(onlyActive != null ? LeadEntityDefault_CC.RESULT_DEFAULTED : LeadEntityDefault_CC.RESULT_UNKNOWN,
            result.outcome, 'Outcome should be Defaulted only for a single active Entity');
    }

    @isTest
    static void bothRegions_SuggestsOnlyWhenOneOfThemIsActive() {
        User bothUser = adminInQueues(new List<String>{ 'US_Marketing_Pool', 'UK_Sales_Pool' });

        LeadEntityDefault_CC.Result result;
        System.runAs(bothUser) {
            result = LeadEntityDefault_CC.suggest(bothUser.Id);
        }

        Boolean usActive = isActive(LeadEntityDefault_CC.US_ENTITY);
        Boolean ukActive = isActive(LeadEntityDefault_CC.UK_ENTITY);
        if (usActive && ukActive) {
            Assert.isNull(result.entityValue, 'Two active regional Entities must not get a default');
            Assert.areEqual(LeadEntityDefault_CC.RESULT_AMBIGUOUS, result.outcome, 'Outcome should be Ambiguous');
        } else if (usActive || ukActive) {
            String expected = usActive ? LeadEntityDefault_CC.US_ENTITY : LeadEntityDefault_CC.UK_ENTITY;
            Assert.areEqual(expected, result.entityValue, 'The one active regional Entity should be suggested');
            Assert.areEqual(LeadEntityDefault_CC.RESULT_DEFAULTED, result.outcome, 'Outcome should be Defaulted');
        }
    }

    @isTest
    static void ukOnly_InactiveEntityIsNeverSuggested() {
        User ukUser = adminInQueues(new List<String>{ 'UK_Marketing_Pool' });

        LeadEntityDefault_CC.Result result;
        System.runAs(ukUser) {
            result = LeadEntityDefault_CC.suggest(ukUser.Id);
        }

        if (isActive(LeadEntityDefault_CC.UK_ENTITY)) {
            Assert.areEqual(LeadEntityDefault_CC.UK_ENTITY, result.entityValue, 'An active UK value would be suggested');
        } else {
            Assert.areNotEqual(LeadEntityDefault_CC.UK_ENTITY, result.entityValue, 'The inactive UK LLP value must not be suggested');
            String onlyActive = onlyActiveValue();
            Assert.areEqual(onlyActive, result.entityValue, 'Only the single active Entity may be suggested instead');
            Assert.areEqual(onlyActive != null ? LeadEntityDefault_CC.RESULT_DEFAULTED : LeadEntityDefault_CC.RESULT_UNAVAILABLE,
                result.outcome, 'Outcome should follow the active values');
        }
    }

    private static String onlyActiveValue() {
        Set<String> values = LeadEntityDefault_CC.activeValues();
        return values.size() == 1 ? values.iterator().next() : null;
    }

    /**
     * The running System Administrator, with Lead field access and exactly the given regional queue memberships
     * (any other regional membership is removed for the test).
     */
    private static User adminInQueues(List<String> queueNames) {
        TestAdminAccess_CC.grant(new List<SObjectType>{ Lead.SObjectType });
        Id userId = UserInfo.getUserId();
        Set<String> regionalQueues = LeadEntityDefault_CC.ENTITY_BY_QUEUE.keySet();
        System.runAs(TestAdminAccess_CC.admin()) {
            delete [SELECT Id FROM GroupMember WHERE UserOrGroupId = :userId AND Group.Type = 'Queue'
                    AND Group.DeveloperName IN :regionalQueues];
            List<GroupMember> memberships = new List<GroupMember>();
            for (Group queue : [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName IN :queueNames]) {
                memberships.add(new GroupMember(GroupId = queue.Id, UserOrGroupId = userId));
            }
            Assert.areEqual(queueNames.size(), memberships.size(), 'Regional queues should exist: ' + queueNames);
            TestDmlRetry_CC.insertWithRetry(memberships);
        }
        return TestAdminAccess_CC.admin();
    }

    private static Boolean isActive(String value) {
        for (Schema.PicklistEntry entry : Lead.Belongs_To_CC__c.getDescribe().getPicklistValues()) {
            if (entry.isActive() && entry.getValue() == value) {
                return true;
            }
        }
        return false;
    }
}
