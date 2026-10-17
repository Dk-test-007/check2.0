/**
 * =============================================================================
 * Trigger Name  : CaseTrigger_CC
 * Description   : Trigger for Case Object
 *
 * Author        : Nipun Jain
 * Created Date  : 
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author        	Description
 * -------    ----------   ------------  	---------------------------------------
 * 
 * =============================================================================
 * Usage: Trigger for Case
 * =============================================================================
 */

trigger CaseTrigger_CC on Case (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    CaseTriggerHandler_CC handler = new CaseTriggerHandler_CC();
    handler.run();
}