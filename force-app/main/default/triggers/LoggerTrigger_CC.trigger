/**
 * =============================================================================
 * Trigger Name  : LoggerTrigger_CC
 * Description   : Trigger for Logger_CC__c Object
 *
 * Author        : Nipun Jain
 * Created Date  : Oct 2026 
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author        	Description
 * -------    ----------   ------------  	---------------------------------------
 * 
 * =============================================================================
 * Usage: Trigger for Logger_CC__c
 * =============================================================================
 */

trigger LoggerTrigger_CC on Logger_CC__c (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    LoggerTriggerHandler_CC handler = new LoggerTriggerHandler_CC();
    handler.run();
}