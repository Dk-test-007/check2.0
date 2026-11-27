/**
 * =============================================================================
 * Class Name    : ProductTriggerHandler_CC
 * Description   : Trigger handler for Product2 object
 *
 * Author        : Nipun Jain
 * Created Date  : Oct 2026
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Central trigger handler for Product2 object.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public class ProductTriggerHandler_CC extends BaseTriggerHandler_CC {
    
    private static final String STANDARD_PRICEBOOK_NAME = 'Standard Price Book';
    public void run() {
        super.run(this, 'Product2');
    }
    
    public override void beforeInsert() {
        updateProductLandingCost((List<Product2>)Trigger.new);
    }
    
    public override void afterInsert() {
        createStandardPricebookEntries((List<Product2>)Trigger.new);
    }
    
    public void updateProductLandingCost(List<Product2> newProducts) {
        for(Product2 prod: newProducts) {
            if(prod.Unit_Cost_CC__c != NULL && prod.Estimated_Landing_Price_CC__c == NULL) {
                prod.Estimated_Landing_Price_CC__c = prod.Unit_Cost_CC__c;
            }
        }
    }

    public void createStandardPricebookEntries(List<Product2> newProducts) {
        List<PricebookEntry> entries = new List<PricebookEntry>();
        Id standardPricebookId = Test.isRunningTest() ? Test.getStandardPricebookId() : [SELECT Id FROM Pricebook2 WHERE Name =: STANDARD_PRICEBOOK_NAME]?.Id;
        
        for(Product2 prod: newProducts) {
            if(prod.Unit_Cost_CC__c != NULL) {
                PricebookEntry entry = new PricebookEntry();
                entry.Product2Id = prod.Id;
                entry.Pricebook2Id = standardPricebookId;
                entry.UnitPrice = prod.Unit_Cost_CC__c;
                entry.IsActive = TRUE;
                entries.add(entry);
            }
        }
        
        if(!entries.isEmpty()) {
            Database.insert(entries);
        }
    }
}