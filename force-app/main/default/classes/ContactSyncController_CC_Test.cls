/**
 * =============================================================================
 * Class Name    : ContactSyncController_CC_Test
 * Description   : Unit tests for ContactSyncController_CC.syncContact - parent not
 *                 synced, no contact method, successful dispatch and the error path.
 * =============================================================================
 */
@IsTest
private class ContactSyncController_CC_Test {

    private static final String ADMIN_ALIAS = 'cscadm';
    private static final String SYNCED_ACCOUNT = 'CSC Synced Entity';
    private static final String UNSYNCED_ACCOUNT = 'CSC Unsynced Entity';

    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.user('System Administrator', ADMIN_ALIAS);
        insert admin;

        // Data is created as an admin so Contact validation rules (email/first name) do not apply.
        System.runAs(admin) {
            Account synced = newEntity(SYNCED_ACCOUNT, 'BC-CSC-001');
            Account unsynced = newEntity(UNSYNCED_ACCOUNT, null);
            insert new List<Account>{ synced, unsynced };

            insert new List<Contact>{
                new Contact(FirstName = 'Ready', LastName = 'Contact', AccountId = synced.Id,
                    Email = 'ready.contact@carltontest.invalid', Phone = '0207 946 0001'),
                new Contact(FirstName = 'NoMethod', LastName = 'Contact', AccountId = synced.Id),
                new Contact(FirstName = 'Unsynced', LastName = 'Contact', AccountId = unsynced.Id,
                    Email = 'unsynced.contact@carltontest.invalid', Phone = '0207 946 0002')
            };
        }
    }

    @IsTest
    static void syncContact_success_queuesCallout() {
        Test.setMock(HttpCalloutMock.class, new OkCalloutMock());
        Id contactId = contactId('Ready');

        Integer jobsBefore = Limits.getQueueableJobs();
        String result = ContactSyncController_CC.syncContact(contactId);

        Assert.areEqual('Success', result, 'A contact under a synced account with a contact method is dispatched');
        Assert.areEqual(jobsBefore + 1, Limits.getQueueableJobs(), 'One callout job is queued');
    }

    @IsTest
    static void syncContact_parentNotSynced_returnsError() {
        String result = ContactSyncController_CC.syncContact(contactId('Unsynced'));

        Assert.isTrue(result.startsWith('Error: The parent Account/Site must be synced'), result);
        Assert.areEqual(0, Limits.getQueueableJobs(), 'Nothing is queued');
    }

    @IsTest
    static void syncContact_noContactMethod_returnsError() {
        String result = ContactSyncController_CC.syncContact(contactId('NoMethod'));

        Assert.isTrue(result.startsWith('Error: Contact must have an Email, Phone, or Mobile'), result);
        Assert.areEqual(0, Limits.getQueueableJobs(), 'Nothing is queued');
    }

    @IsTest
    static void syncContact_unknownId_returnsExceptionMessage() {
        Id missingId = Id.valueOf(Contact.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        String result = ContactSyncController_CC.syncContact(missingId);

        Assert.isTrue(result.startsWith('Error: '), 'The query exception is returned as an error message: ' + result);
    }

    // ===================================================================== helpers

    private static Id contactId(String firstName) {
        return [SELECT Id FROM Contact WHERE FirstName = :firstName AND LastName = 'Contact' LIMIT 1].Id;
    }

    private static Account newEntity(String name, String businessCentralId) {
        return new Account(
            Name = name + ' ' + OpportunityUi2TestData_CC.suffix(),
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Entity').getRecordTypeId(),
            BillingStreet = '1 Test Street',
            BillingCity = 'London',
            BillingPostalCode = 'EC1A 1BB',
            BillingCountryCode = 'GB',
            Business_Central_Customer_ID_CC__c = businessCentralId
        );
    }

    private class OkCalloutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{}');
            return response;
        }
    }
}