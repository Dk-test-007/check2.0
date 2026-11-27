/**
 * =============================================================================
 * Trigger Name  : LeadTrigger_CC
 * Description   : Trigger for Lead Object
 *
 * Author        : Vansh Mansotra
 * Created Date  : 
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author        	Description
 * -------    ----------   ------------  	---------------------------------------
 * 
 * =============================================================================
 * Usage: Trigger for Lead
 * =============================================================================
 */

trigger LeadTrigger_CC on Lead (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    LeadTriggerHandler_CC_New handler = new LeadTriggerHandler_CC_New();
    handler.run();
}