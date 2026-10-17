/**
 * =============================================================================
 * Class Name    : ProductAvailabilityController_CCTest
 * Description   : Test class for ProductAvailabilityController_CC.
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
 * Validates product searches by name and product code, blank and unmatched
 * searches, inventory retrieval, empty or null product ID inputs, and products
 * without inventory records.
 * =============================================================================
 * Prerequisites:
 * Product2, Warehouse_CC__c, and Product_Warehouse_Inventory_CC__c objects
 * with the required fields and permissions for USER_MODE queries.
 * =============================================================================
 */

@IsTest
private class ProductAvailabilityController_CCTest {

    @TestSetup
    static void setupData() {
        Product2 productByName = new Product2(
            Name = 'Availability Test Carton',
            ProductCode = 'AVAIL-001',
            IsActive = true
        );

        Product2 productByCode = new Product2(
            Name = 'Test Envelope',
            ProductCode = 'CARTON-AVAIL-002',
            IsActive = true
        );

        insert new List<Product2>{
            productByName,
            productByCode
        };

        Warehouse_CC__c warehouse = new Warehouse_CC__c(
            Name = 'Availability Test Warehouse'
        );
        insert warehouse;

        insert new List<Product_Warehouse_Inventory_CC__c>{
            new Product_Warehouse_Inventory_CC__c(
                Product_CC__c = productByName.Id,
                Warehouse_CC__c = warehouse.Id,
                Stock_on_Hand_CC__c = 100,
                Reserved_CC__c = 10,
                Committed_CC__c = 5,
                Restricted_CC__c = 2,
                Available_CC__c = 83,
                Available_To_Order_CC__c = 80,
                Receiving_CC__c = 4,
                Held_CC__c = 1,
                Entered_Stock_CC__c = 100,
                Damaged_CC__c = 2,
                On_Hold_CC__c = 3
            )
        };
    }

    @IsTest
    static void searchProductsByName() {
        Test.startTest();
        List<Product2> results =
            ProductAvailabilityController_CC.searchProducts('Availability Test');
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Availability Test Carton', results[0].Name);
        System.assertEquals('AVAIL-001', results[0].ProductCode);
    }

    @IsTest
    static void searchProductsByProductCode() {
        Test.startTest();
        List<Product2> results =
            ProductAvailabilityController_CC.searchProducts('CARTON-AVAIL-002');
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Test Envelope', results[0].Name);
        System.assertEquals('CARTON-AVAIL-002', results[0].ProductCode);
    }

    @IsTest
    static void searchProductsWithBlankInput() {
        Test.startTest();
        List<Product2> results =
            ProductAvailabilityController_CC.searchProducts('  ');
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void searchProductsWithNoMatches() {
        Test.startTest();
        List<Product2> results =
            ProductAvailabilityController_CC.searchProducts('NO-MATCH-XYZ');
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void getInventoryForSelectedProducts() {
        Product2 product = [
            SELECT Id
            FROM Product2
            WHERE ProductCode = 'AVAIL-001'
            LIMIT 1
        ];

        Test.startTest();
        List<Product_Warehouse_Inventory_CC__c> results =
            ProductAvailabilityController_CC.getInventory(
                new List<Id>{ product.Id }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());

        Product_Warehouse_Inventory_CC__c inventory = results[0];

        System.assertEquals(product.Id, inventory.Product_CC__c);
        System.assertEquals('Availability Test Warehouse',
            inventory.Warehouse_CC__r.Name);
        System.assertEquals(100, inventory.Stock_on_Hand_CC__c);
        System.assertEquals(10, inventory.Reserved_CC__c);
        System.assertEquals(5, inventory.Committed_CC__c);
        System.assertEquals(83, inventory.Available_CC__c);
    }

    @IsTest
    static void getInventoryWithEmptyProductIds() {
        Test.startTest();
        List<Product_Warehouse_Inventory_CC__c> results =
            ProductAvailabilityController_CC.getInventory(
                new List<Id>()
            );
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void getInventoryWithNullProductIds() {
        Test.startTest();
        List<Product_Warehouse_Inventory_CC__c> results =
            ProductAvailabilityController_CC.getInventory(null);
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void getInventoryForProductWithoutInventory() {
        Product2 product = [
            SELECT Id
            FROM Product2
            WHERE ProductCode = 'CARTON-AVAIL-002'
            LIMIT 1
        ];

        Test.startTest();
        List<Product_Warehouse_Inventory_CC__c> results =
            ProductAvailabilityController_CC.getInventory(
                new List<Id>{ product.Id }
            );
        Test.stopTest();

        System.assertEquals(0, results.size());
    }
}