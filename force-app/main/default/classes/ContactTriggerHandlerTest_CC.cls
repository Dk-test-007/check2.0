/**
 * Unit tests for ContactTriggerHandler_CC (+ ContactTrigger_CC).
 *
 * Validates the Contact phone requirement and the trigger's bulk insert and update paths.
 */
@IsTest
private class ContactTriggerHandlerTest_CC {

    @TestSetup
    static void setupData() {
        TestDataFactory_CC.createEntity('Contact Trigger Test Entity', null, true);
    }

    private static Id entityId() {
        return [SELECT Id FROM Account WHERE Name = 'Contact Trigger Test Entity' LIMIT 1].Id;
    }

    private static List<Contact> buildContacts(Integer count) {
        Id accountId = entityId();
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < count; i++) {
            contacts.add(TestDataFactory_CC.createContact(accountId, false));
        }
        return contacts;
    }

    // Verifies a bulk insert of 200 valid Contacts succeeds.
    @IsTest
    static void bulkInsert_runsHandlerWithoutSideEffects() {
        List<Contact> contacts = buildContacts(200);

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(contacts, false);
        Test.stopTest();

        for (Database.SaveResult sr : results) {
            Assert.isTrue(sr.isSuccess(), 'Contact insert should succeed: ' + sr.getErrors());
        }
        Assert.areEqual(200, [SELECT COUNT() FROM Contact WHERE AccountId = :entityId()], 'All 200 Contacts should be saved');
    }

    // Verifies a bulk update of 200 Contacts fires the trigger (after update) and keeps the user's changes intact.
    @IsTest
    static void bulkUpdate_runsHandlerAndKeepsValues() {
        List<Contact> contacts = buildContacts(200);
        insert contacts;
        for (Contact c : contacts) {
            c.Title = 'Updated Title';
        }

        Test.startTest();
        update contacts;
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Contact WHERE Title = 'Updated Title'], 'All updates should be persisted unchanged');
    }

    @IsTest
    static void phoneValidationMethodRejectsMissingNumbers() {
        Contact contactRecord = buildContacts(1)[0];
        contactRecord.Phone = null;
        contactRecord.MobilePhone = null;

        ContactTriggerHandler_CC.validateContactMethod(new List<Contact>{ contactRecord });
        Assert.isTrue(contactRecord.hasErrors(), 'The validation method should reject a Contact without phone numbers');
        Assert.isTrue(contactRecord.getErrors()[0].getMessage().contains('Phone or Mobile'),
            'The phone validation should explain the missing field');
    }

    /*
     * Before insert/update are switched off in Trigger_Framework_Config_CC (Contact), so the trigger never reaches
     * them. Call the context methods directly: outside a trigger Trigger.new is null, so the validation loop throws.
     */
    @IsTest
    static void contextMethods_runOutsideTrigger() {
        ContactTriggerHandler_CC handler = new ContactTriggerHandler_CC();
        Integer failures = 0;

        Test.startTest();
        try {
            handler.beforeInsert();
        } catch (Exception ex) {
            failures++;
        }
        try {
            handler.beforeUpdate();
        } catch (Exception ex) {
            failures++;
        }
        handler.afterInsert();   // null Trigger.new -> ZoomInfo mapping returns immediately
        Test.stopTest();

        Assert.areEqual(2, failures, 'Validation has no records to iterate outside a trigger');
        Assert.areEqual(0, Limits.getQueueableJobs(), 'afterInsert queues nothing without records');
    }

    // Verifies run() is a safe no-op outside a trigger context.
    @IsTest
    static void run_outsideTrigger_noOp() {
        ContactTriggerHandler_CC handler = new ContactTriggerHandler_CC();

        Test.startTest();
        handler.run(handler);
        Integer dml = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, dml, 'No DML should run outside a trigger context');
    }
}