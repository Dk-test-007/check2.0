/**
 * =============================================================================
 * Class Name    : OpportunityTriggerHandler_CC
 * Description   : Trigger handler for Opportunity object
 *
 * Author        : Nipun Jain
 * Created Date  : Sept 2026
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Central trigger handler for Opportunity object.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public class OpportunityTriggerHandler_CC extends BaseTriggerHandler_CC {
    
    public void run() {
        super.run(this, 'Opportunity');
    }

    public override void beforeInsert() {
        checkForParentAccountType((List<Opportunity>) Trigger.new, null);
    }

    public override void beforeUpdate() {
        checkForParentAccountType((List<Opportunity>) Trigger.new, (Map<Id, Opportunity>) Trigger.oldMap);
    }
    
    public static void checkForParentAccountType(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap) {
        Set<Id> accIds = new Set<Id>();
        
        for(Opportunity opp: newOpps) {
            if(opp.AccountId != NULL && (oldOppMap == null || opp.AccountId != oldOppMap.get(opp.Id).AccountId)) {
            	accIds.add(opp.AccountId);
            }
        }
        
        if(!accIds.isEmpty()) {
            Map<Id, Account> parentAccMaps = new Map<Id, Account>([SELECT Id, RecordType.DeveloperName, ParentId, Parent.RecordType.DeveloperName FROM Account WHERE Id IN: accIds]);
            
            for(Opportunity opp: newOpps) {
                if(parentAccMaps.containsKey(opp.AccountId)) {
                    Account parentAcc = parentAccMaps.get(opp.AccountId);
                    
                    if(parentAcc.RecordType.DeveloperName == 'Corporate_Group') {
                        opp.addError('Opportunity cannot be created for a Corporate Group');                   
                    } else if(parentAcc.RecordType.DeveloperName == 'Site' && (parentAcc.ParentId == NULL || parentAcc.ParentId != NULL && parentAcc.Parent.RecordType.DeveloperName != 'Entity')) {
                        opp.addError('Opportunity cannot be created for a Site without an Entity') ;
                    } else if(parentAcc.RecordType.DeveloperName == 'Site' && parentAcc.ParentId != NULL && parentAcc.Parent.RecordType.DeveloperName == 'Entity') {
                        opp.AccountId = parentAcc.ParentId;
                    }
                }
            }
        }
    }

}