/**
 * =============================================================================
 * Class Name    : OpportunitySiteTriggerHandler_CC
 * Description   : Trigger handler for Opportunity_Site__c object
 *
 * Author        : Nipun Jain
 * Created Date  : Nov 2026
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Central trigger handler for Opportunity_Site__c object.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public class OpportunitySiteTriggerHandler_CC extends BaseTriggerHandler_CC {

    public void run() {
        super.run(this, 'Opportunity_Site_c');
    }

    public override void afterInsert() {
        updateSiteFlagOnOpportunity((List<Opportunity_Site__c>)Trigger.new);
    }
    
    
    public override void afterDelete() {
        updateSiteFlagOnOpportunity((List<Opportunity_Site__c>)Trigger.old);
    }
    
    public static void updateSiteFlagOnOpportunity(List<Opportunity_Site__c> newSites) {
        List<Opportunity> oppToUpdate = new List<Opportunity>();
        Set<Id> oppIds = new Set<Id>();
        
        for(Opportunity_Site__c site: newsites) {
            if(site.Opportunity__c != NULL) {
                oppIds.add(site.Opportunity__c);
            }
        }
        
        Set<Id> opportunitiesHavingSites = new Set<Id>();
        for(AggregateResult res: [SELECT Opportunity__c, COUNT(Id) siteCount FROM Opportunity_Site__c WHERE Opportunity__c IN: oppIds GROUP BY Opportunity__c]) {
            opportunitiesHavingSites.add((String)res.get('Opportunity__c'));
        }
        
        for(Id oppId: oppIds) {
            Opportunity opp = new Opportunity();
            opp.Id = oppId;
            opp.Has_Related_Sites_CC__c = opportunitiesHavingSites.contains(oppId);
            oppToUpdate.add(opp);
        }
        if(!oppToUpdate.isEmpty()) {
            Database.update(oppToUpdate, AccessLevel.SYSTEM_MODE);
        }
    }

}