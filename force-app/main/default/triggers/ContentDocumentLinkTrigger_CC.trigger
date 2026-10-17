/**
 * =============================================================================
 * Trigger Name  : ContentDocumentLinkTrigger_CC
 * Description   : Trigger for ContentDocumentLink Object
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
 * Usage: Trigger for ContentDocumentLink
 * =============================================================================
 */

trigger ContentDocumentLinkTrigger_CC on ContentDocumentLink (before insert) {
    ContentDocumentLinkTriggerHandler_CC handler = new ContentDocumentLinkTriggerHandler_CC();
    handler.run();

}