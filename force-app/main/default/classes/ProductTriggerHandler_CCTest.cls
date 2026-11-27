/**
 * =============================================================================
 * Class Name    : ProductTriggerHandler_CCTest
* Description   : Unit test class for ProductTriggerHandler. Covers Standard 
				  Pricebook Entry creation based on the Unit_Cost_CC__c of Product.
 *
 * Author        : Nipun Jain
 * Created Date  : Sept 2026
 * =============================================================================
 */

@isTest
private class ProductTriggerHandler_CCTest {

    @isTest
    static void testAfterInsertWithUnitCost() {
        Product2 product = new Product2(
            Name = 'Test Product With Cost',
            ProductCode = 'TEST001',
            IsActive = TRUE,
            Unit_Cost_CC__c = 100
        );

        Test.startTest();
        insert product;
        Test.stopTest();

        List<PricebookEntry> entries = [
            SELECT Id, Product2Id, Pricebook2Id, UnitPrice, IsActive
            FROM PricebookEntry
            WHERE Product2Id = :product.Id
            AND Pricebook2Id = :Test.getStandardPricebookId()

        ];

        System.assertEquals(1, entries.size(), 'A Standard Price Book entry should be created.');
        System.assertEquals(product.Id, entries[0].Product2Id);
        System.assertEquals(100, entries[0].UnitPrice);
        System.assertEquals(TRUE, entries[0].IsActive);
    }

    @isTest
    static void testAfterInsertWithoutUnitCost() {
        Product2 product = new Product2(
            Name = 'Test Product Without Cost',
            ProductCode = 'TEST002',
            IsActive = TRUE
        );

        Test.startTest();
        insert product;
        Test.stopTest();

        Integer entryCount = [
            SELECT COUNT()
            FROM PricebookEntry
            WHERE Product2Id = :product.Id
            AND Pricebook2Id = :Test.getStandardPricebookId()
        ];

        System.assertEquals(0, entryCount, 'A Standard Price Book entry should not be created when Unit Cost is null.');
    }
}