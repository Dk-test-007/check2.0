/**
 * Tests for PricebookTriggerHandler_CC (fired by PriceBookTrigger_CC): a new Entity price book
 * gets the "Delivery" product, and the standard price is created first when it is missing.
 */
@IsTest
private class PricebookTriggerHandler_CC_Test {

    private static final String DELIVERY = 'Delivery';

    /**
     * In tests the standard price book is only returned by SOQL after it has been updated.
     * The handler looks it up by name, so make it visible.
     */
    private static void exposeStandardPricebook() {
        TestDmlRetry_CC.activateStandardPricebook();
    }

    private static Product2 deliveryProduct(Decimal unitCost) {
        // With a Unit Cost, ProductTriggerHandler_CC also creates the standard price.
        Product2 product = new Product2(Name = DELIVERY, ProductCode = 'ZZDEL-' + OpportunityUi2TestData_CC.suffix(),
            IsActive = true, Unit_Cost_CC__c = unitCost);
        insert product;
        return product;
    }

    private static List<PricebookEntry> entries(Id productId, Id pricebookId) {
        return [SELECT Id, UnitPrice FROM PricebookEntry WHERE Product2Id = :productId AND Pricebook2Id = :pricebookId];
    }

    @IsTest
    static void newPricebookGetsDeliveryAtUnitCost() {
        exposeStandardPricebook();
        Product2 delivery = deliveryProduct(12.5);
        Assert.areEqual(1, entries(delivery.Id, Test.getStandardPricebookId()).size(),
            'The standard price is created when the product is created');

        Test.startTest();
        Pricebook2 pricebook = new Pricebook2(Name = 'ZZ Entity Price Book', IsActive = true);
        insert pricebook;
        Test.stopTest();

        List<PricebookEntry> added = entries(delivery.Id, pricebook.Id);
        Assert.areEqual(1, added.size(), 'Delivery is added to the new price book');
        Assert.isTrue(added[0].UnitPrice == 12.5, 'Delivery uses the product Unit Cost');
        Assert.areEqual(1, entries(delivery.Id, Test.getStandardPricebookId()).size(),
            'The existing standard price is not duplicated');
    }

    @IsTest
    static void createsMissingStandardPriceAndSkipsStandardPricebook() {
        exposeStandardPricebook();
        Product2 delivery = deliveryProduct(null);
        Assert.areEqual(0, entries(delivery.Id, Test.getStandardPricebookId()).size(),
            'No standard price without a Unit Cost');

        Pricebook2 standard = [SELECT Id, IsStandard FROM Pricebook2 WHERE Id = :Test.getStandardPricebookId()];

        Test.startTest();
        PricebookTriggerHandler_CC.addDeliveryToEntityPricebook(new List<Pricebook2>{ standard });
        Test.stopTest();

        List<PricebookEntry> standardEntries = entries(delivery.Id, Test.getStandardPricebookId());
        Assert.areEqual(1, standardEntries.size(), 'The missing standard price is created');
        Assert.isTrue(standardEntries[0].UnitPrice == 0, 'Without a Unit Cost the price defaults to zero');
    }

    @IsTest
    static void nothingAddedWithoutDeliveryProduct() {
        Test.startTest();
        Pricebook2 pricebook = new Pricebook2(Name = 'ZZ Entity Price Book', IsActive = true);
        insert pricebook;
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM PricebookEntry WHERE Pricebook2Id = :pricebook.Id],
            'No entries are added when there is no Delivery product');
    }
}