/**
 * =============================================================================
 * Class Name    : ContentDocumentLinkTriggerHandler_CC
 * Description   : Trigger handler for ContentDocumentLink object
 *
 * Author        : Nipun Jain
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Central trigger handler for ContentDocumentLink object.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public class ContentDocumentLinkTriggerHandler_CC extends BaseTriggerHandler_CC {
    
    public void run() {
        super.run(this, 'ContentDocumentLink');
    }

    public override void beforeInsert() {
        checkForClosedCaseError((List<ContentDocumentLink>) Trigger.new);
    }

    public static void checkForClosedCaseError(List<ContentDocumentLink> cdlList) {
        Set<Id> caseIds = new Set<Id>();
        
        for(ContentDocumentLink cdl: cdlList) {
            if(String.valueOf(cdl.LinkedEntityId).startsWith('500')) {
                caseIds.add(cdl.LinkedEntityId);
            }
        }
        
        Map<Id, Case> caseMap = new Map<Id, Case>([SELECT Id, IsClosed FROM Case WHERE Id IN: caseIds]);
        for(ContentDocumentLink cdl: cdlList) {
            if(caseMap.containsKey(cdl.LinkedEntityId) && caseMap.get(cdl.LinkedEntityId).IsClosed) {
                cdl.addError('You cannot upload a file to a closed Case.');
            }
        }
    }
}