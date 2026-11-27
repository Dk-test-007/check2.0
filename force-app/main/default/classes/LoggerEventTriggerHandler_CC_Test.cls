/**
 * =============================================================================
 * Class Name    : LoggerEventTriggerHandler_CC_Test
 * Description   : Test class for LoggerEventTriggerHandler_CC
 *
 * Author        : Vansh Mansotra
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author            Description
 * -------    ----------   ------------      ---------------------------------------
 *    1                    Vansh Mansotra    Initial test implementation
 *
 * =============================================================================
 * Usage: Covers event-to-record mapping, chunking at the 200 row boundary,
 *        no-op guards, partial success handling and the platform event path.
 * =============================================================================
 */
@isTest
private class LoggerEventTriggerHandler_CC_Test {
    private static final String TXN_PREFIX = 'TXN-';
    private static final Integer CHUNK_SIZE = 200;

    /*
     * Picklist safe value resolver. Returns the first active picklist value so the
     * test does not hard code labels; falls back to the supplied default for
     * text fields, where getPicklistValues() comes back empty.
     */
    private static String safeValue(Schema.SObjectField field, String fallback) {
        List<Schema.PicklistEntry> entries = field.getDescribe().getPicklistValues();
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return fallback;
    }

    private static Logger_Event_CC__e buildEvent(Integer index) {
        return new Logger_Event_CC__e(
            Log_Level_CC__c          = safeValue(Logger_Event_CC__e.Log_Level_CC__c, 'ERROR'),
            Message_CC__c            = 'Test message ' + index,
            Source_Type_CC__c        = safeValue(Logger_Event_CC__e.Source_Type_CC__c, 'Apex'),
            Source_Class_CC__c      = 'LoggerEventTriggerHandler_CC_Test',
            Origin_Location_CC__c    = 'buildEvent',
            Transaction_Id_CC__c     = TXN_PREFIX + index,
            Related_Record_Ids_CC__c = '001000000000000AAA',
            Integration_Name_CC__c   = 'Unit Test Integration',
            Comments_CC__c           = 'Comment ' + index
        );
    }

    private static List<Logger_Event_CC__e> buildEvents(Integer count) {
        List<Logger_Event_CC__e> events = new List<Logger_Event_CC__e>();
        for (Integer i = 0; i < count; i++) {
            events.add(buildEvent(i));
        }
        return events;
    }

    private static Integer logCount() {
        return [SELECT COUNT() FROM Logger_CC__c];
    }

    /*
     * Every field on the event must land on the matching field of the log record.
     */
    @isTest
    static void testCreateLogsMapsAllFields() {
        Logger_Event_CC__e event = buildEvent(1);

        Test.startTest();
        LoggerEventTriggerHandler_CC.createLogs(new List<Logger_Event_CC__e>{ event });
        Test.stopTest();

        List<Logger_CC__c> logs = [
            SELECT Log_Level_CC__c, Message_CC__c, Source_Type_CC__c, Source_Class_CC__c,
                   Origin_Location_CC__c, Transaction_Id_CC__c, Related_Record_Ids_CC__c,
                   Integration_Name_CC__c, Comments_CC__c
            FROM Logger_CC__c
        ];

        System.assertEquals(1, logs.size(), 'One event should produce exactly one log record.');
        Logger_CC__c log = logs[0];
        System.assertEquals(event.Log_Level_CC__c, log.Log_Level_CC__c, 'Log level was not mapped.');
        System.assertEquals(event.Message_CC__c, log.Message_CC__c, 'Message was not mapped.');
        System.assertEquals(event.Source_Type_CC__c, log.Source_Type_CC__c, 'Source type was not mapped.');
        System.assertEquals(event.Source_Class_CC__c, log.Source_Class_CC__c, 'Source class was not mapped.');
        System.assertEquals(event.Origin_Location_CC__c, log.Origin_Location_CC__c, 'Origin location was not mapped.');
        System.assertEquals(event.Transaction_Id_CC__c, log.Transaction_Id_CC__c, 'Transaction id was not mapped.');
        System.assertEquals(event.Related_Record_Ids_CC__c, log.Related_Record_Ids_CC__c, 'Related record ids were not mapped.');
        System.assertEquals(event.Integration_Name_CC__c, log.Integration_Name_CC__c, 'Integration name was not mapped.');
        System.assertEquals(event.Comments_CC__c, log.Comments_CC__c, 'Comments were not mapped.');
    }

    @isTest
    static void testCreateLogsWithNullListDoesNothing() {
        Test.startTest();
        LoggerEventTriggerHandler_CC.createLogs(null);
        Test.stopTest();

        System.assertEquals(0, logCount(), 'A null list must not insert any log records.');
        System.assertEquals(0, Limits.getDmlStatements(), 'A null list must not consume a DML statement.');
    }

    @isTest
    static void testCreateLogsWithEmptyListDoesNothing() {
        Test.startTest();
        LoggerEventTriggerHandler_CC.createLogs(new List<Logger_Event_CC__e>());
        Test.stopTest();

        System.assertEquals(0, logCount(), 'An empty list must not insert any log records.');
        System.assertEquals(0, Limits.getDmlStatements(), 'An empty list must not consume a DML statement.');
    }

    /*
     * Exactly one full chunk: the size based flush and the isLast flush both fire on
     * the same iteration, so the chunk must not be saved twice.
     */
    @isTest
    static void testCreateLogsAtExactChunkBoundary() {
        List<Logger_Event_CC__e> events = buildEvents(CHUNK_SIZE);

        Test.startTest();
        LoggerEventTriggerHandler_CC.createLogs(events);
        Test.stopTest();

        System.assertEquals(CHUNK_SIZE, logCount(), 'A single full chunk should insert 200 records once.');
    }

    @isTest
    static void testCreateLogsBelowChunkSize() {
        List<Logger_Event_CC__e> events = buildEvents(5);

        Test.startTest();
        LoggerEventTriggerHandler_CC.createLogs(events);
        Test.stopTest();

        System.assertEquals(5, logCount(), 'A partial chunk should still be flushed by the isLast branch.');
    }

    /*
     * Two full chunks plus a trailing partial chunk. Verifies nothing is dropped at
     * the boundary and that each chunk is a separate DML statement.
     */
    @isTest
    static void testCreateLogsAcrossMultipleChunks() {
        Integer total = (CHUNK_SIZE * 2) + 50;
        List<Logger_Event_CC__e> events = buildEvents(total);

        Test.startTest();
        LoggerEventTriggerHandler_CC.createLogs(events);
        Integer dmlStatements = Limits.getDmlStatements();
        Test.stopTest();

        System.assertEquals(total, logCount(), 'All events across chunk boundaries should be inserted.');
        System.assertEquals(3, dmlStatements, 'Three chunks should result in three insert statements.');

        Integer distinctTxn = [SELECT COUNT() FROM Logger_CC__c WHERE Transaction_Id_CC__c LIKE :(TXN_PREFIX + '%')];
        System.assertEquals(total, distinctTxn, 'Every event should keep its own transaction id.');
    }

    /*
     * Partial success: a row that violates field length must not discard the good
     * rows in the same chunk, and must not surface as an exception.
     */
    @isTest
    static void testPartialSuccessKeepsValidRows() {
        Integer maxLength = Logger_CC__c.Message_CC__c.getDescribe().getLength();
        Logger_Event_CC__e badEvent = buildEvent(999);
        badEvent.Message_CC__c = 'x'.repeat(maxLength + 1);

        List<Logger_Event_CC__e> events = new List<Logger_Event_CC__e>{
            buildEvent(1),
            badEvent,
            buildEvent(2)
        };

        Test.startTest();
        try {
            LoggerEventTriggerHandler_CC.createLogs(events);
        } catch (Exception e) {
            System.assert(false, 'Partial success should swallow row level failures, but got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assertEquals(2, logCount(), 'The two valid rows should survive the failed row.');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM Logger_CC__c WHERE Transaction_Id_CC__c = :(TXN_PREFIX + '999')],
            'The invalid row should not have been inserted.'
        );
    }

    /*
     * Publishes through the event bus so the trigger, run() and afterInsert() are
     * exercised end to end. Requires the Logger_Event_CC__e trigger to be active and
     * enabled in the BaseTriggerHandler_CC configuration for CONFIG_KEY
     * 'Logger_Event_CC'; if the handler is switched off in config, no log is created.
     */
    @isTest
    static void testPublishedEventCreatesLog() {
        Logger_Event_CC__e event = buildEvent(1);

        Test.startTest();
        Database.SaveResult publishResult = EventBus.publish(event);
        Test.stopTest();

        System.assertEquals(true, publishResult.isSuccess(), 'The platform event should publish successfully.');

        List<Logger_CC__c> logs = [SELECT Message_CC__c, Transaction_Id_CC__c FROM Logger_CC__c];
        System.assertEquals(1, logs.size(), 'The delivered event should be converted into one log record.');
        System.assertEquals(event.Message_CC__c, logs[0].Message_CC__c, 'The published message should be persisted.');
        System.assertEquals(TXN_PREFIX + '1', logs[0].Transaction_Id_CC__c, 'The published transaction id should be persisted.');
    }

    @isTest
    static void testPublishedEventBatchCreatesLogs() {
        List<Logger_Event_CC__e> events = buildEvents(10);

        Test.startTest();
        List<Database.SaveResult> results = EventBus.publish(events);
        Test.stopTest();

        for (Database.SaveResult result : results) {
            System.assertEquals(true, result.isSuccess(), 'Each platform event should publish successfully.');
        }
        System.assertEquals(10, logCount(), 'Each delivered event should produce one log record.');
    }
}