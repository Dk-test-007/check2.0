/**
 * =============================================================================
 * Trigger Name  : OpportunityTrigger_CC
 * Description   : Trigger for Opportunity Object
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
 * Usage: Trigger for Opportunity
 * =============================================================================
 */

trigger OpportunityTrigger_CC on Opportunity (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    OpportunityTriggerHandler_CC handler = new OpportunityTriggerHandler_CC();
    handler.run();
}