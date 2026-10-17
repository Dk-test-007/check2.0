/**
 * =============================================================================
 * Trigger Name  : LoggerEventTrigger_CC
 * Description   : Trigger for Logger Event platform event
 *
 * Author        : Vansh Mansotra
 * Created Date  :
 *
 * Modification History
 * =============================================================================
 * Version    Date         Author            Description
 * -------    ----------   ------------      ----------------------------------
 *    1                    Vansh Mansotra    Initial trigger implementation
 *
 * =============================================================================
 * Usage: Subscribes to Logger_Event_CC__e and creates Logger__c records.
 *        Platform events support "after insert" only - no other context can fire.
 * =============================================================================
 */
trigger LoggerEventTrigger_CC on Logger_Event_CC__e (after insert) {
    LoggerEventTriggerHandler_CC handler = new LoggerEventTriggerHandler_CC();
    handler.run();
}