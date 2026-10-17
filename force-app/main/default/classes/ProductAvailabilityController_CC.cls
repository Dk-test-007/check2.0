/**
 * =============================================================================
 * Class Name    : ProductAvailabilityController_CC
 * Description   : Controller for product search and warehouse inventory
 *                 availability checks.
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
 * Provides methods to search products by name or product code and retrieve
 * warehouse inventory details for selected products.
 * =============================================================================
 * Prerequisites:
 * Product2, Warehouse_CC__c, and Product_Warehouse_Inventory_CC__c objects
 * with the required fields and user permissions.
 * =============================================================================
 */

public with sharing class ProductAvailabilityController_CC {

    @AuraEnabled(cacheable=true)
    public static List<Product2> searchProducts(String searchKey) {
        if (String.isBlank(searchKey)) {
            return new List<Product2>();
        }

        String searchPattern = '%' + searchKey.trim() + '%';

        return [
            SELECT Id,
                   Name,
                   ProductCode,
                   BC_Last_Modified_Date_Time_CC__c
            FROM Product2
            WHERE Name LIKE :searchPattern
               OR ProductCode LIKE :searchPattern
            WITH USER_MODE
            ORDER BY Name
            LIMIT 10
        ];
    }

    @AuraEnabled
    public static List<Product_Warehouse_Inventory_CC__c> getInventory(
        List<Id> productIds
    ) {
        if (productIds == null || productIds.isEmpty()) {
            return new List<Product_Warehouse_Inventory_CC__c>();
        }

        return [
            SELECT Id,
                   Product_CC__c,
                   Product_CC__r.Name,
                   Warehouse_CC__c,
                   Warehouse_CC__r.Name,
                   Last_Synced_CC__c,
                   Stock_on_Hand_CC__c,
                   Reserved_CC__c,
                   Committed_CC__c,
                   Restricted_CC__c,
                   Available_CC__c,
                   Available_To_Order_CC__c,
                   Receiving_CC__c,
                   Held_CC__c,
                   Entered_Stock_CC__c,
                   Damaged_CC__c,
                   On_Hold_CC__c
            FROM Product_Warehouse_Inventory_CC__c
            WHERE Product_CC__c IN :productIds
            WITH USER_MODE
            ORDER BY Product_CC__r.Name, Warehouse_CC__r.Name
        ];
    }
}