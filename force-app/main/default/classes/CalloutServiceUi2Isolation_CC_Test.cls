/**
 * CalloutService_CC with per-record UI2 isolation: UI2 records are removed before enqueue and again inside the job;
 * normal records keep the existing Business Central route (callouts mocked, no real traffic).
 */
@isTest
private class CalloutServiceUi2Isolation_CC_Test {

    private class OkMock implements HttpCalloutMock {
        public Integer calls = 0;
        public HttpResponse respond(HttpRequest request) {
            calls++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{"status":"ok"}');
            return response;
        }
    }

    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.isolationAdmin();
        System.runAs(admin) {
            OpportunityUi2TestData_CC.entity(admin.Id, true);
            insert new Account(Name = 'Normal Entity ' + OpportunityUi2TestData_CC.suffix(),
                RecordTypeId = OpportunityUi2TestData_CC.recordTypeId(Account.SObjectType, 'Entity'),
                Entity_CC__c = 'Carlton Packaging INC',
                BillingStreet = '1 Test Street', BillingCity = 'New York', BillingStateCode = 'NY',
                BillingPostalCode = '10001', BillingCountryCode = 'US');
        }
    }

    private static Account ui2() {
        return [SELECT Id FROM Account WHERE Integration_Test_Record_CC__c = true WITH SYSTEM_MODE LIMIT 1];
    }
    private static Account normal() {
        return [SELECT Id FROM Account WHERE Name LIKE 'Normal Entity%' LIMIT 1];
    }

    @isTest
    static void withoutIntegrationTestRecords_FiltersOnlyIntegrationTestRecords() {
        Set<Id> outbound = CalloutService_CC.withoutIntegrationTestRecords(new Set<Id>{ ui2().Id, normal().Id, null });
        Assert.areEqual(new Set<Id>{ normal().Id }, outbound);
        Assert.isTrue(CalloutService_CC.withoutIntegrationTestRecords(new Set<Id>()).isEmpty());
        Assert.isTrue(CalloutService_CC.withoutIntegrationTestRecords(null).isEmpty());
    }

    @isTest
    static void opportunityIsolation_UsesTheAccountMarker() {
        Opportunity synthetic = OpportunityUi2TestData_CC.newBusiness(ui2().Id, UserInfo.getUserId(), 100, 'GBP');
        Opportunity operational = OpportunityUi2TestData_CC.newBusiness(normal().Id, UserInfo.getUserId(), 100, 'GBP');

        Set<Id> outbound = CalloutService_CC.withoutIntegrationTestRecords(
            new Set<Id>{ synthetic.Id, operational.Id });

        Assert.areEqual(new Set<Id>{ operational.Id }, outbound,
            'Synthetic Opportunities stay out of Business Central without an Opportunity marker field.');
    }

    @isTest
    static void send_EnqueuesNothingForIntegrationTestRecords_ButStillEnqueuesNormalRecords() {
        Integer before = Limits.getQueueableJobs();
        CalloutService_CC.send(ui2().Id, 'Create');
        CalloutService_CC.send(new Map<Id, List<String>>{ ui2().Id => new List<String>{ 'Name' } }, 'Update');
        Assert.areEqual(before, Limits.getQueueableJobs(), 'No job is enqueued for UI2 records');
        // Normal records are still enqueued and called out: see normalCreate_ and normalUpdate_ below.
    }

    @isTest
    static void normalCreate_StillCallsOut_ThroughTheExistingRoute() {
        OkMock mock = new OkMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        CalloutService_CC.send(normal().Id, 'Create');
        Test.stopTest();
        Integer configs = [SELECT COUNT() FROM Integration_Config__mdt WHERE SObject_API_Name__c = 'Account' AND Operation__c = 'Create' AND Active__c = true WITH SYSTEM_MODE];
        Assert.areEqual(configs > 0 ? 1 : 0, mock.calls, 'A normal Account still reaches the (mocked) endpoint when configured');
    }

    @isTest
    static void normalUpdate_SendsChangedFields() {
        OkMock mock = new OkMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        CalloutService_CC.send(new Map<Id, List<String>>{ normal().Id => new List<String>{ 'Name' } }, 'Update');
        Test.stopTest();
        Integer configs = [SELECT COUNT() FROM Integration_Config__mdt WHERE SObject_API_Name__c = 'Account' AND Operation__c = 'Update' AND Active__c = true WITH SYSTEM_MODE];
        Assert.areEqual(configs > 0 ? 1 : 0, mock.calls);
    }

    @isTest
    static void jobEnqueuedBeforeMarking_StopsInsideExecute() {
        OkMock mock = new OkMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        // Bypasses send() on purpose: simulates a job queued before the record became UI2 (or a manual sync).
        System.enqueueJob(new CalloutService_CC(new Set<Id>{ ui2().Id }, 'Create'));
        Test.stopTest();
        Assert.areEqual(0, mock.calls, 'The job makes no callout for a UI2 record');
    }
}
