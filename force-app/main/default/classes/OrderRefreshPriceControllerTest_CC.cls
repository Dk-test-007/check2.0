/**
 * =============================================================================
 * Class Name    : OrderRefreshPriceControllerTest_CC
 * Description   : Unit tests for OrderRefreshPriceController_CC (Order "Refresh Price" action).
 *                 Covers input validation, Orders without a price book / products, the
 *                 "already current" outcome, a successful delete-and-recreate refresh, missing
 *                 price book entries, Activated Orders, a forced insert failure with rollback,
 *                 and a refresh run by a non-admin user (system context).
 * =============================================================================
 */
@IsTest
private class OrderRefreshPriceControllerTest_CC {

    private static final String PRODUCT_A = 'Refresh Product A';
    private static final String PRODUCT_B = 'Refresh Product B';
    private static final Decimal UNIT_COST_A = 30;

    @TestSetup
    static void setupData() {
        Account entity = TestDataFactory_CC.createEntity('Refresh Entity', null, false);
        entity.Type = 'Customer';
        insert entity;

        Product2 productA = TestDataFactory_CC.createProduct(PRODUCT_A, false);
        productA.Unit_Cost_CC__c = UNIT_COST_A;
        Product2 productB = TestDataFactory_CC.createProduct(PRODUCT_B, false);
        insert new List<Product2>{ productA, productB };

        PricebookEntry pbeA = TestDataFactory_CC.ensureStandardPricebookEntry(productA.Id, 100);
        PricebookEntry pbeB = TestDataFactory_CC.ensureStandardPricebookEntry(productB.Id, 50);

        Order withItems = buildOrder(entity.Id, 'With Items', Test.getStandardPricebookId());
        Order noItems = buildOrder(entity.Id, 'No Items', Test.getStandardPricebookId());
        Order noPricebook = buildOrder(entity.Id, 'No Pricebook', null);
        insert new List<Order>{ withItems, noItems, noPricebook };

        insert new List<OrderItem>{
            new OrderItem(OrderId = withItems.Id, PricebookEntryId = pbeA.Id, Quantity = 2, UnitPrice = pbeA.UnitPrice, Description = 'Line A'),
            new OrderItem(OrderId = withItems.Id, PricebookEntryId = pbeB.Id, Quantity = 1, UnitPrice = pbeB.UnitPrice, Description = 'Line B')
        };
    }

    // ------------------------------------------------------------------ helpers

    private static Order buildOrder(Id accountId, String description, Id pricebookId) {
        return new Order(
            AccountId = accountId, EffectiveDate = Date.today(), Status = 'Draft', Description = description,
            Pricebook2Id = pricebookId, Shipping_and_Handling__c = 10, Location_Code_CC__c = 'CA',
            Shipment_Date_CC__c = Date.today().addDays(7),
            BillingStreet = '1 Bill Street', BillingCity = 'Bill City', BillingStateCode = 'NY',
            BillingPostalCode = '11111', BillingCountryCode = 'US',
            ShippingStreet = '2 Ship Street', ShippingCity = 'Ship City', ShippingStateCode = 'NY',
            ShippingPostalCode = '22222', ShippingCountryCode = 'US'
        );
    }

    private static Id orderId(String description) {
        // Description (long text) cannot be filtered in SOQL and Order.Name is not accessible in this org,
        // so the setup Orders are matched in Apex.
        for (Order ord : [SELECT Id, Description FROM Order]) {
            if (ord.Description == description) {
                return ord.Id;
            }
        }
        return null;
    }

    private static PricebookEntry entry(String productName) {
        return [SELECT Id, UnitPrice, IsActive FROM PricebookEntry
                WHERE Product2.Name = :productName AND Pricebook2Id = :Test.getStandardPricebookId() LIMIT 1];
    }

    private static String refreshExpectingError(Id ordId) {
        try {
            OrderRefreshPriceController_CC.refreshPrices(ordId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        Assert.fail('An AuraHandledException was expected');
        return null;
    }

    // ------------------------------------------------------------------ validation

    // Verifies a null Order Id is rejected with a clear message.
    @IsTest
    static void testNullOrderId() {
        Test.startTest();
        String message = refreshExpectingError(null);
        Test.stopTest();

        Assert.areEqual('No Order Id was received from the action.', message, 'Unexpected error for a null Id');
    }

    // Verifies an Id that does not match any Order is rejected.
    @IsTest
    static void testOrderNotFound() {
        Id withItemsId = orderId('With Items');
        delete [SELECT Id FROM Order WHERE Id = :withItemsId];

        Test.startTest();
        String message = refreshExpectingError(withItemsId);
        Test.stopTest();

        Assert.areEqual('The Order could not be found.', message, 'Unexpected error for a missing Order');
    }

    // Verifies an Order without a price book cannot be refreshed.
    @IsTest
    static void testOrderWithoutPricebook() {
        Test.startTest();
        String message = refreshExpectingError(orderId('No Pricebook'));
        Test.stopTest();

        Assert.areEqual('This Order has no Price Book assigned, so current prices cannot be resolved.', message,
            'Unexpected error for an Order without a price book');
    }

    // Verifies an Activated Order cannot be refreshed.
    @IsTest
    static void testActivatedOrderRejected() {
        Id ordId = orderId('With Items');
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{"status":"ok"}'));

        Test.startTest();
        update new Order(Id = ordId, Status = 'Activated');
        Test.stopTest();
        String message = refreshExpectingError(ordId);

        Assert.isTrue(message.startsWith('Order Products cannot be changed on an activated Order.'),
            'Unexpected error for an Activated Order: ' + message);
        Assert.areEqual(2, [SELECT COUNT() FROM OrderItem WHERE OrderId = :ordId], 'Order Products should be untouched');
    }

    // ------------------------------------------------------------------ outcomes

    // Verifies an Order without Order Products returns a "nothing to refresh" result.
    @IsTest
    static void testOrderWithoutItems() {
        Test.startTest();
        Map<String, Object> result = OrderRefreshPriceController_CC.refreshPrices(orderId('No Items'));
        Test.stopTest();

        Assert.areEqual(false, result.get('refreshed'), 'Nothing should be refreshed');
        Assert.areEqual('This Order has no Order Products to refresh. No changes were made.', result.get('message'),
            'Unexpected message for an Order without products');
    }

    // Verifies an Order whose prices already match the price book is left unchanged.
    @IsTest
    static void testPricesAlreadyCurrent() {
        Id ordId = orderId('With Items');
        Set<Id> itemIdsBefore = new Map<Id, OrderItem>([SELECT Id FROM OrderItem WHERE OrderId = :ordId]).keySet();

        Test.startTest();
        Map<String, Object> result = OrderRefreshPriceController_CC.refreshPrices(ordId);
        Test.stopTest();

        Assert.areEqual(false, result.get('refreshed'), 'Nothing should be refreshed');
        Assert.areEqual(OrderRefreshPriceController_CC.ALREADY_CURRENT_MESSAGE, result.get('message'), 'Unexpected message');
        Set<Id> itemIdsAfter = new Map<Id, OrderItem>([SELECT Id FROM OrderItem WHERE OrderId = :ordId]).keySet();
        Assert.areEqual(itemIdsBefore, itemIdsAfter, 'Order Products should not be recreated');
    }

    // Verifies a price book change causes all Order Products to be recreated with the new prices,
    // keeping quantity and description.
    @IsTest
    static void testPricesRefreshed() {
        Id ordId = orderId('With Items');
        Set<Id> itemIdsBefore = new Map<Id, OrderItem>([SELECT Id FROM OrderItem WHERE OrderId = :ordId]).keySet();
        PricebookEntry pbeA = entry(PRODUCT_A);
        Database.update(new PricebookEntry(Id = pbeA.Id, UnitPrice = 120), AccessLevel.SYSTEM_MODE);

        Test.startTest();
        Map<String, Object> result = OrderRefreshPriceController_CC.refreshPrices(ordId);
        Test.stopTest();

        Assert.areEqual(true, result.get('refreshed'), 'Prices should be refreshed');
        Assert.areEqual('Prices refreshed for 2 Order Product(s).', result.get('message'), 'Unexpected success message');

        List<OrderItem> items = [SELECT Id, Product2.Name, ListPrice, UnitPrice, Quantity, Description, UnitCost
                                 FROM OrderItem WHERE OrderId = :ordId];
        Assert.areEqual(2, items.size(), 'Both Order Products should be recreated');
        for (OrderItem item : items) {
            Assert.isFalse(itemIdsBefore.contains(item.Id), 'Order Products should be new records');
            if (item.Product2.Name == PRODUCT_A) {
                Assert.areEqual(120, item.ListPrice, 'List price should reflect the new price book price');
                Assert.areEqual(120, item.UnitPrice, 'Unit price should reflect the new price book price');
                Assert.areEqual(2, item.Quantity, 'Quantity should be preserved');
                Assert.areEqual('Line A', item.Description, 'Description should be preserved');
                Assert.areEqual(UNIT_COST_A, item.UnitCost, 'Unit cost should be preserved');
            } else {
                Assert.areEqual(50, item.ListPrice, 'Unchanged product should keep its price');
                Assert.areEqual(1, item.Quantity, 'Quantity should be preserved');
            }
        }
    }

    // Verifies the refresh is rejected when a product no longer has an active price book entry.
    @IsTest
    static void testMissingActivePricebookEntry() {
        Id ordId = orderId('With Items');
        PricebookEntry pbeB = entry(PRODUCT_B);
        Database.update(new PricebookEntry(Id = pbeB.Id, IsActive = false), AccessLevel.SYSTEM_MODE);

        Test.startTest();
        String message = refreshExpectingError(ordId);
        Test.stopTest();

        Assert.isTrue(message.startsWith('No active Price Book Entry was found in this Order\'s Price Book'),
            'Unexpected error: ' + message);
        Assert.isTrue(message.contains(PRODUCT_B), 'Error should name the product without an entry: ' + message);
        Assert.isFalse(message.contains(PRODUCT_A), 'Error should not name products that have an entry: ' + message);
    }

    // Verifies a failure while recreating Order Products rolls back the deletion and reports the error.
    @IsTest
    static void testInsertFailureRollsBack() {
        Id ordId = orderId('With Items');
        Set<Id> itemIdsBefore = new Map<Id, OrderItem>([SELECT Id FROM OrderItem WHERE OrderId = :ordId]).keySet();
        PricebookEntry pbeA = entry(PRODUCT_A);
        Database.update(new PricebookEntry(Id = pbeA.Id, UnitPrice = 150), AccessLevel.SYSTEM_MODE);
        OrderRefreshPriceController_CC.forceInsertFailure = true;

        Test.startTest();
        String message = refreshExpectingError(ordId);
        Test.stopTest();

        Assert.isTrue(message.startsWith('Refresh Price failed and no changes were saved.'), 'Unexpected error: ' + message);
        Set<Id> itemIdsAfter = new Map<Id, OrderItem>([SELECT Id FROM OrderItem WHERE OrderId = :ordId]).keySet();
        Assert.areEqual(itemIdsBefore, itemIdsAfter, 'Original Order Products should be restored by the rollback');
    }

    // Verifies a non-admin user can refresh prices because the controller runs in system context (Order
    // Product validation rules still apply, so the Order carries Location Code and Shipment Date).
    // NOTE: 'Standard User' is used because Carlton profiles currently fail here: recreating Order Products
    // re-fires OrderTrigger_CC, whose validateActivatedOrderUpdate queries Profile, which Carlton profiles
    // cannot read (no View Setup) - reported as a production defect.
    @IsTest
    static void testRefreshAsNonAdminUser() {
        Id ordId = orderId('With Items');
        PricebookEntry pbeB = entry(PRODUCT_B);
        Database.update(new PricebookEntry(Id = pbeB.Id, UnitPrice = 55), AccessLevel.SYSTEM_MODE);
        User nonAdminUser = TestDataFactory_CC.createUser('Standard User', 'refuser', true);
        Map<String, Object> result;

        Test.startTest();
        System.runAs(nonAdminUser) {
            result = OrderRefreshPriceController_CC.refreshPrices(ordId);
        }
        Test.stopTest();

        Assert.areEqual(true, result.get('refreshed'), 'Non-admin user should be able to refresh prices');
        OrderItem itemB = [SELECT ListPrice, UnitPrice FROM OrderItem WHERE OrderId = :ordId AND Product2.Name = :PRODUCT_B];
        Assert.areEqual(55, itemB.ListPrice, 'List price should be refreshed for the non-admin user');
    }

    // Verifies buildResult returns the expected map shape.
    @IsTest
    static void testBuildResult() {
        Test.startTest();
        Map<String, Object> result = OrderRefreshPriceController_CC.buildResult(true, 'Done');
        Test.stopTest();

        Assert.areEqual(true, result.get('refreshed'), 'refreshed flag should be returned');
        Assert.areEqual('Done', result.get('message'), 'message should be returned');
    }
}