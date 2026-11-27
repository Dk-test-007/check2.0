/**
 * =============================================================================
 * Class Name    : OrderItemTriggerHandlerTest_CC
 * Description   : Unit tests for OrderItemTriggerHandler_CC and the OrderItemTrigger_CC trigger.
 *                 Covers Unit Cost population from the Product on insert (single, bulk and
 *                 edge cases) and the restriction on editing Order Products of an Activated
 *                 Order for non-admin users.
 * =============================================================================
 */
@IsTest
private class OrderItemTriggerHandlerTest_CC {

    private static final Decimal UNIT_COST = 40;
    private static final Decimal UNIT_PRICE = 100;
    // Non-admin profile used for the activated-record edit checks. The production code queries Profile,
    // which needs "View Setup and Configuration"; none of the Carlton profiles have it (see report),
    // so a standard non-admin profile that does is used to reach the validation logic.
    private static final String NON_ADMIN_PROFILE = 'Standard User';

    @TestSetup
    static void setupData() {
        Account entity = TestDataFactory_CC.createEntity('Order Item Entity', null, false);
        entity.Type = 'Customer';
        insert entity;

        Product2 costedProduct = TestDataFactory_CC.createProduct('Costed Product', false);
        costedProduct.Unit_Cost_CC__c = UNIT_COST;
        Product2 uncostedProduct = TestDataFactory_CC.createProduct('Uncosted Product', false);
        insert new List<Product2>{ costedProduct, uncostedProduct };

        TestDataFactory_CC.ensureStandardPricebookEntry(costedProduct.Id, UNIT_PRICE);
        TestDataFactory_CC.ensureStandardPricebookEntry(uncostedProduct.Id, UNIT_PRICE);

        insert new Order(
            AccountId = entity.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(),
            BillingStreet = '1 Bill Street', BillingCity = 'Bill City', BillingStateCode = 'NY',
            BillingPostalCode = '11111', BillingCountryCode = 'US',
            ShippingStreet = '2 Ship Street', ShippingCity = 'Ship City', ShippingStateCode = 'NY',
            ShippingPostalCode = '22222', ShippingCountryCode = 'US',
            Shipping_and_Handling__c = 10
        );
    }

    // ------------------------------------------------------------------ helpers

    private static Order getOrder() {
        return [SELECT Id FROM Order LIMIT 1];
    }

    private static PricebookEntry getEntry(String productName) {
        return [SELECT Id, Product2Id, UnitPrice FROM PricebookEntry
                WHERE Product2.Name = :productName AND Pricebook2Id = :Test.getStandardPricebookId() LIMIT 1];
    }

    private static OrderItem buildItem(Id orderId, PricebookEntry pbe, Decimal quantity) {
        return new OrderItem(OrderId = orderId, PricebookEntryId = pbe.Id, Quantity = quantity, UnitPrice = pbe.UnitPrice);
    }

    // ------------------------------------------------------------------ before insert

    // Verifies a new Order Product takes its Unit Cost from the Product's Unit Cost.
    @IsTest
    static void testInsertPopulatesUnitCost() {
        OrderItem item = buildItem(getOrder().Id, getEntry('Costed Product'), 2);

        Test.startTest();
        insert item;
        Test.stopTest();

        Assert.areEqual(UNIT_COST, [SELECT UnitCost FROM OrderItem WHERE Id = :item.Id].UnitCost,
            'Unit Cost should be copied from the Product');
    }

    // Verifies a Product without a Unit Cost overrides any manually entered Unit Cost with blank.
    @IsTest
    static void testInsertWithUncostedProduct() {
        OrderItem item = buildItem(getOrder().Id, getEntry('Uncosted Product'), 1);
        item.UnitCost = 99;

        Test.startTest();
        insert item;
        Test.stopTest();

        Assert.isNull([SELECT UnitCost FROM OrderItem WHERE Id = :item.Id].UnitCost,
            'Unit Cost should mirror the blank Product Unit Cost');
    }

    // Verifies 200 Order Products inserted in one DML all receive the Product Unit Cost.
    @IsTest
    static void testBulkInsertPopulatesUnitCost() {
        Id orderId = getOrder().Id;
        PricebookEntry pbe = getEntry('Costed Product');
        List<OrderItem> items = new List<OrderItem>();
        for (Integer i = 0; i < 200; i++) {
            items.add(buildItem(orderId, pbe, i + 1));
        }

        Test.startTest();
        insert items;
        Test.stopTest();

        List<OrderItem> results = [SELECT UnitCost FROM OrderItem WHERE OrderId = :orderId];
        Assert.areEqual(200, results.size(), 'All 200 Order Products should be inserted');
        for (OrderItem item : results) {
            Assert.areEqual(UNIT_COST, item.UnitCost, 'Every Order Product should get the Product Unit Cost');
        }
    }

    // Verifies populateUnitCostFromProduct leaves records untouched when no price book entry is set,
    // and handles an empty list.
    @IsTest
    static void testPopulateUnitCostWithoutPricebookEntry() {
        OrderItem item = new OrderItem(Quantity = 1, UnitCost = 7);

        Test.startTest();
        OrderItemTriggerHandler_CC.populateUnitCostFromProduct(new List<OrderItem>{ item });
        OrderItemTriggerHandler_CC.populateUnitCostFromProduct(new List<OrderItem>());
        Test.stopTest();

        Assert.areEqual(7, item.UnitCost, 'Unit Cost should not change without a price book entry');
    }

    // ------------------------------------------------------------------ before update

    // Verifies a System Administrator can update an Order Product on a Draft Order (validation skipped).
    @IsTest
    static void testAdminUpdateOnDraftOrder() {
        OrderItem item = buildItem(getOrder().Id, getEntry('Costed Product'), 1);
        insert item;

        Test.startTest();
        Database.SaveResult sr = Database.update(new OrderItem(Id = item.Id, Quantity = 5, Description = 'Updated'), false);
        Test.stopTest();

        Assert.isTrue(sr.isSuccess(), 'Admin update should succeed: ' + sr.getErrors());
        OrderItem result = [SELECT Quantity, Description FROM OrderItem WHERE Id = :item.Id];
        Assert.areEqual(5, result.Quantity, 'Quantity should be updated');
        Assert.areEqual('Updated', result.Description, 'Description should be updated');
    }

    // Grants edit access on the given fields ('Object.Field') through a test-only permission set. Runs as the
    // current user so the setup-object DML does not mix with the Order DML of the test.
    private static void grantFieldEdit(Id userId, List<String> qualifiedFields) {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet permissionSet = new PermissionSet(Name = 'Order_Item_Test_Field_Edit', Label = 'Order Item Test Field Edit');
            insert permissionSet;
            List<FieldPermissions> fieldPermissions = new List<FieldPermissions>();
            for (String qualifiedField : qualifiedFields) {
                fieldPermissions.add(new FieldPermissions(ParentId = permissionSet.Id,
                    SobjectType = qualifiedField.substringBefore('.'), Field = qualifiedField,
                    PermissionsRead = true, PermissionsEdit = true));
            }
            insert fieldPermissions;
            insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permissionSet.Id);
        }
    }

    // Verifies non-admin users cannot change Order Products of an Activated Order (other than the
    // allowed Description field), and that Draft Orders are not restricted.
    @IsTest
    static void testValidateActivatedOrderItemUpdateAsNonAdmin() {
        Order ord = getOrder();
        PricebookEntry pbe = getEntry('Costed Product');
        OrderItem item = buildItem(ord.Id, pbe, 2);
        insert item;
        Order secondOrder = new Order(AccountId = [SELECT AccountId FROM Order WHERE Id = :ord.Id].AccountId,
                                      EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId());
        insert secondOrder;
        OrderItem draftItem = buildItem(secondOrder.Id, pbe, 1);
        insert draftItem;
        User nonAdminUser = TestDataFactory_CC.createUser(NON_ADMIN_PROFILE, 'oisales', true);
        // The validation only checks fields the running user can edit; grant the custom field used below so
        // the test does not depend on the profile's field-level security in each org.
        grantFieldEdit(nonAdminUser.Id, new List<String>{ 'OrderItem.Document_No_CC__c' });
        // The Order query in the handler respects record access, so the non-admin user owns the Orders.
        update new List<Order>{ new Order(Id = ord.Id, OwnerId = nonAdminUser.Id), new Order(Id = secondOrder.Id, OwnerId = nonAdminUser.Id) };
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{"status":"ok"}'));

        Test.startTest();
        update new Order(Id = ord.Id, Status = 'Activated');

        OrderItem oldItem = new OrderItem(Id = item.Id, OrderId = ord.Id, Quantity = 2, Description = 'Old');
        OrderItem quantityChange = new OrderItem(Id = item.Id, OrderId = ord.Id, Quantity = 3, Description = 'Old');
        OrderItem textChange = new OrderItem(Id = item.Id, OrderId = ord.Id, Quantity = 2, Description = 'Old', Document_No_CC__c = 'DOC-1');
        OrderItem descriptionChange = new OrderItem(Id = item.Id, OrderId = ord.Id, Quantity = 2, Description = 'New');
        OrderItem oldTextItem = new OrderItem(Id = item.Id, OrderId = ord.Id, Quantity = 2, Description = 'Old', Document_No_CC__c = 'DOC-0');
        OrderItem oldDraftItem = new OrderItem(Id = draftItem.Id, OrderId = secondOrder.Id, Quantity = 1);
        OrderItem draftChange = new OrderItem(Id = draftItem.Id, OrderId = secondOrder.Id, Quantity = 9);
        OrderItem orphanItem = new OrderItem(Id = item.Id, Quantity = 4);
        OrderItem missingOld = new OrderItem(Id = draftItem.Id, OrderId = ord.Id, Quantity = 4);

        System.runAs(nonAdminUser) {
            OrderItemTriggerHandler_CC.validateActivatedOrderItemUpdate(
                new List<OrderItem>{ quantityChange }, new Map<Id, OrderItem>{ item.Id => oldItem });
            OrderItemTriggerHandler_CC.validateActivatedOrderItemUpdate(
                new List<OrderItem>{ textChange }, new Map<Id, OrderItem>{ item.Id => oldTextItem });
            OrderItemTriggerHandler_CC.validateActivatedOrderItemUpdate(
                new List<OrderItem>{ descriptionChange }, new Map<Id, OrderItem>{ item.Id => oldItem });
            OrderItemTriggerHandler_CC.validateActivatedOrderItemUpdate(
                new List<OrderItem>{ draftChange }, new Map<Id, OrderItem>{ draftItem.Id => oldDraftItem });
            OrderItemTriggerHandler_CC.validateActivatedOrderItemUpdate(
                new List<OrderItem>{ orphanItem }, new Map<Id, OrderItem>{ item.Id => oldItem });
            OrderItemTriggerHandler_CC.validateActivatedOrderItemUpdate(
                new List<OrderItem>{ missingOld }, new Map<Id, OrderItem>());
        }
        Test.stopTest();

        Assert.isTrue(quantityChange.hasErrors(), 'Quantity change on an Activated Order should be blocked');
        Assert.areEqual('Changes are not allowed on Order Products of an Activated Order.',
            quantityChange.getErrors()[0].getMessage(), 'Unexpected error message');
        Assert.isTrue(textChange.hasErrors(), 'Text field change on an Activated Order should be blocked');
        Assert.isFalse(descriptionChange.hasErrors(), 'Description is an allowed field on an Activated Order');
        Assert.isFalse(draftChange.hasErrors(), 'Order Products of Draft Orders are not restricted');
        Assert.isFalse(orphanItem.hasErrors(), 'Items without an Order are skipped');
        Assert.isFalse(missingOld.hasErrors(), 'Items without an old version are skipped');
    }

    // Verifies a non-admin with an Order Product that is null-valued then populated is blocked.
    @IsTest
    static void testValidateActivatedOrderItemNullToValue() {
        Order ord = getOrder();
        OrderItem item = buildItem(ord.Id, getEntry('Costed Product'), 2);
        insert item;
        User nonAdminUser = TestDataFactory_CC.createUser(NON_ADMIN_PROFILE, 'oisale2', true);
        update new Order(Id = ord.Id, OwnerId = nonAdminUser.Id);
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{"status":"ok"}'));

        Test.startTest();
        update new Order(Id = ord.Id, Status = 'Activated');
        OrderItem oldItem = new OrderItem(Id = item.Id, OrderId = ord.Id);
        OrderItem newItem = new OrderItem(Id = item.Id, OrderId = ord.Id, Quantity = 1);
        System.runAs(nonAdminUser) {
            OrderItemTriggerHandler_CC.validateActivatedOrderItemUpdate(
                new List<OrderItem>{ newItem }, new Map<Id, OrderItem>{ item.Id => oldItem });
        }
        Test.stopTest();

        Assert.isTrue(newItem.hasErrors(), 'Populating a blank field on an Activated Order Product should be blocked');
    }
}