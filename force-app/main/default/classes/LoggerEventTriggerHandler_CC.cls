/**
 * =============================================================================
 * Class Name    : LoggerEventTriggerHandler_CC
 * Description   : Trigger handler for Logger_Event_CC__e platform event
 *
 * Author        : Vansh Mansotra
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author            Description
 * -------    ----------   ------------      ---------------------------------------
 *    1                    Vansh Mansotra    Initial handler implementation
 *
 * =============================================================================
 * Usage: Turns published Logger_Event_CC__e messages into Logger__c records.
 * =============================================================================
 */
public without sharing class LoggerEventTriggerHandler_CC extends BaseTriggerHandler_CC {
    private static final String CONFIG_KEY = 'Logger_Event_CC';
    // The event bus delivers up to 2,000 messages per trigger execution.
    private static final Integer CHUNK_SIZE = 200;

    public void run() {
        super.run(this, CONFIG_KEY);
    }

    protected override void afterInsert() {
        createLogs((List<Logger_Event_CC__e>) Trigger.new);
    }

    public static void createLogs(List<Logger_Event_CC__e> events) {
        if (events == null || events.isEmpty()) {
            return;
        }
        List<Logger_CC__c> chunk = new List<Logger_CC__c>();
        for (Integer i = 0; i < events.size(); i++) {
            chunk.add(toLog(events[i]));
            Boolean isLast = (i == events.size() - 1);
            if (chunk.size() == CHUNK_SIZE || isLast) {
                save(chunk);
                chunk.clear();
            }
        }
    }

    private static Logger_CC__c toLog(Logger_Event_CC__e event) {
        return new Logger_CC__c(
            Log_Level_CC__c          = event.Log_Level_CC__c,
            Message_CC__c            = event.Message_CC__c,
            Source_Type_CC__c        = event.Source_Type_CC__c,
            Source_Class_CC__c       = event.Source_Class_CC__c,
            Origin_Location_CC__c    = event.Origin_Location_CC__c,
            Transaction_Id_CC__c     = event.Transaction_Id_CC__c,
            Related_Record_Ids_CC__c = event.Related_Record_Ids_CC__c,
            Integration_Name_CC__c   = event.Integration_Name_CC__c,
            Comments_CC__c           = event.Comments_CC__c
        );
    }

    /*
     * Partial success: one bad row must not discard the rest of the batch.
     */
    private static void save(List<Logger_CC__c> logs) {
        if (logs.isEmpty()) {
            return;
        }
        for (Database.SaveResult result : Database.insert(logs, false)) {
            if (result.isSuccess()) {
                continue;
            }
            for (Database.Error err : result.getErrors()) {
                System.debug(LoggingLevel.ERROR,'LoggerEventTriggerHandler_CC: insert failed - ' +err.getStatusCode() + ' ' +err.getMessage() + ' ' +err.getFields());
            }
        }
    }
}