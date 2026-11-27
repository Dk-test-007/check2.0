/**
 * =============================================================================
 * Trigger Name  : ProductTrigger_CC
 * Description   : Trigger for Product2 Object
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
 * Usage: Trigger for Product2
 * =============================================================================
 */

trigger ProductTrigger_CC on Product2 (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    ProductTriggerHandler_CC handler = new ProductTriggerHandler_CC();
    handler.run();
}