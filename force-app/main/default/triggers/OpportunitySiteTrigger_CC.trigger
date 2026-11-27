/**
 * =============================================================================
 * Trigger Name  : OpportunitySiteTrigger_CC
 * Description   : Trigger for Opportunity_Site__c Object
 *
 * Author        : Nipun Jain
 * Created Date  : Nov 2026 
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author        	Description
 * -------    ----------   ------------  	---------------------------------------
 * 
 * =============================================================================
 * Usage: Trigger for Opportunity_Site__c
 * =============================================================================
 */

trigger OpportunitySiteTrigger_CC on Opportunity_Site__c (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    OpportunitySiteTriggerHandler_CC handler = new OpportunitySiteTriggerHandler_CC();
    handler.run();
}