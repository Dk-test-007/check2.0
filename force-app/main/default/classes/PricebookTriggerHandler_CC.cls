/**
 * =============================================================================
 * Class Name    : PricebookTriggerHandler_CC
 * Description   : Trigger handler for Pricebook2 object
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
 * Central trigger handler for Pricebook2 object.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public class PricebookTriggerHandler_CC extends BaseTriggerHandler_CC {
    
    private static final String DELIVERY_PRODUCT_NAME = 'Delivery'; 
    private static final String STANDARD_PRICEBOOK_NAME = 'Standard Price Book';
    
    public void run() {
        super.run(this, 'Pricebook2');
    }
    
    public override void afterInsert() {
        addDeliveryToEntityPricebook((List<Pricebook2>) Trigger.new);
    }
    
    public static void addDeliveryToEntityPricebook(List<Pricebook2> newPricebooks) {
        List<Product2> deliveryProducts = [SELECT Id, Unit_Cost_CC__c FROM Product2 WHERE Name =: DELIVERY_PRODUCT_NAME LIMIT 1];
        Id standardPricebookId = [SELECT Id FROM Pricebook2 WHERE Name =: STANDARD_PRICEBOOK_NAME]?.Id;
        
        if(!deliveryProducts.isEmpty()) {
            Product2 deliveryProd = deliveryProducts[0];
            List<PricebookEntry> deliveyrEntries = new List<PricebookEntry>();        
            Id standardPricebookEntry = [SELECT Id FROM PricebookEntry WHERE Product2Id =: deliveryProd.Id AND Pricebook2Id =: standardPricebookId]?.Id;
			
            if(standardPricebookEntry == NULL) {
                PricebookEntry entry = new PricebookEntry();
                entry.Product2Id = deliveryProd.Id;
                entry.Pricebook2Id = standardPricebookId;
                entry.UnitPrice = deliveryProd.Unit_Cost_CC__c != NULL ? deliveryProd.Unit_Cost_CC__c : 0;
                deliveyrEntries.add(entry);
            }

            for(Pricebook2 pricebook: newPricebooks) {
                if(!pricebook.IsStandard) {
                    PricebookEntry entry = new PricebookEntry();
                    entry.Product2Id = deliveryProd.Id;
                    entry.Pricebook2Id = pricebook.Id;
                    entry.UnitPrice = deliveryProd.Unit_Cost_CC__c != NULL ? deliveryProd.Unit_Cost_CC__c : 0;
                    deliveyrEntries.add(entry);
                }
            }

            if(!deliveyrEntries.isEmpty()) {
                Database.insert(deliveyrEntries);
            }
        }
    }

}