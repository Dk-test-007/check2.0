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
        defaultValues((List<Opportunity>) Trigger.new, null);
    }

    public override void beforeUpdate() {
        checkForParentAccountType((List<Opportunity>) Trigger.new, (Map<Id, Opportunity>) Trigger.oldMap);
        defaultValues((List<Opportunity>) Trigger.new, (Map<Id, Opportunity>) Trigger.oldMap);
    }

    public override void afterUpdate() {
        List<Guidance_Refresh_CC__e> guidanceEvents = new List<Guidance_Refresh_CC__e>();
        for(Opportunity acc: (List<Opportunity>)Trigger.new) {
            guidanceEvents.add(new Guidance_Refresh_CC__e(
                Record_Id_CC__c = String.valueOf(acc.Id),
                Object_API_Name_CC__c = 'Opportunity'
            ));
        }
        
        if (!guidanceEvents.isEmpty()) {
            EventBus.publish(guidanceEvents);
        }
    }
    
    public static void defaultValues(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap) {
        Set<Id> accIds = new Set<Id>();
        Id newBusinessRecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('New_Business').getRecordTypeId();
        Id existingBusinessRecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('BAU').getRecordTypeId();
        
        for(Opportunity opp: newOpps) {
            if(opp.AccountId != NULL && (oldOppMap == NULL || opp.AccountId != oldOppMap.get(opp.Id).AccountId)) {
                accIds.add(opp.AccountId);
            }
            
            if(opp.Id == NULL) {
                if(opp.RecordTypeId == newBusinessRecordTypeId) {
                    opp.Type = 'New Business';
                    opp.StageName = 'Discover';
                } else {
                    opp.Type = 'Existing Business';
                    opp.StageName = 'Request';
                }
            }
        }
        
        if(!accIds.isEmpty()) {
            Map<Id, Account> parentAcctMap = new Map<Id, Account>([SELECT Id, Entity_CC__c FROM Account WHERE Id IN: accIds]);
            Map<Id, Id> acctToPricebookMap = new Map<Id, Id>();
            for(Pricebook2 pricebook : [SELECT Id, Entity__c FROM Pricebook2 WHERE Entity__c IN: accIds]) {
                acctToPricebookMap.put(pricebook.Entity__c, pricebook.Id);
            }
            
            for(Opportunity opp: newOpps) {
                if(parentAcctMap.containsKey(opp.AccountId)) {
                    opp.Carlton_Entity_CC__c = parentAcctMap.get(opp.AccountId).Entity_CC__c == 'Carlton Packaging INC' ? 'Carlton Packaging Inc.' : 'Carlton Packaging LLP';
                }
                
                if(acctToPricebookMap.containsKey(opp.AccountId)) {
                    opp.Pricebook2Id = acctToPricebookMap.get(opp.AccountId);
                }
            }
        }
        
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