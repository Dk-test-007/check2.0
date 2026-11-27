/**
 * =============================================================================
 * Trigger Name  : PriceBookTrigger_CC
 * Description   : Trigger for Pricebook2 Object
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
 * Usage: Trigger for Pricebook2
 * =============================================================================
 */

trigger PriceBookTrigger_CC on Pricebook2 (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    PricebookTriggerHandler_CC handler = new PricebookTriggerHandler_CC();
    handler.run();
}