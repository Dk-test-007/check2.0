@IsTest
private class OrderPdfControllerTest {

    @IsTest
    static void savesPdfToOrderFiles() {
        Account acc = TestDataFactory_CC.createEntity('Order PDF Test Entity', null, true);
        acc.Type = 'Customer';
        update acc;

        Order ord = new Order(
            AccountId = acc.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert ord;

        Test.startTest();
        Id docId = OrderPdfController.savePdfToOrder(ord.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'A file should be created');
        System.assertEquals(1,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :ord.Id],
            'The file should be linked to the Order');
    }
}