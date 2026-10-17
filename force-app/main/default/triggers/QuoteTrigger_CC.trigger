/**
 * =============================================================================
 * Trigger Name  : QuoteTrigger_CC
 * Description   : Trigger for Quote Object
 *
 * Author        : Nipun Jain
 * Created Date  : Sept 2026 
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author        	Description
 * -------    ----------   ------------  	---------------------------------------
 * 
 * =============================================================================
 * Usage: Trigger for Quote
 * =============================================================================
 */

trigger QuoteTrigger_CC on Quote (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    QuoteTriggerHandler_CC handler = new QuoteTriggerHandler_CC();
    handler.run();
}