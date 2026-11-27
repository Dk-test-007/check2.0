/**
 * =============================================================================
 * Class Name    : OrderContractLineControllerTest_CC
 * Description   : Unit tests for OrderContractLineController_CC (orderContractLines_CC LWC).
 *                 Covers loading Contract Lines for an Order, saving / updating / removing
 *                 Order Products from Contract Lines, MOQ validation, Remaining SKU
 *                 recalculation, Order cancellation and refresh record ids.
 * =============================================================================
 */
@IsTest
private class OrderContractLineControllerTest_CC {

    private static final String PRODUCT_A = 'OCL Product A';
    private static final String PRODUCT_B = 'OCL Product B';
    private static final String PRODUCT_C = 'OCL Product C';
    private static final String PRODUCT_D = 'OCL Product D';
    private static final String CONTRACT_NAME = 'OCL Main Contract';

    private static final String CLM_USER_SEED = 'oclclm';

    /*
     * SalesContractLine is gated by the "Contract LifeCycle Management User" permission set
     * license: even System Administrators get "Access to entity 'SalesContractLine' denied"
     * without it. All data is therefore created, and all tests run, as a System Administrator
     * that has the license plus the CLM permission sets (the admin profile keeps the
     * validation-rule bypass).
     */
    @TestSetup
    static void setup() {
        User clm = createClmUser('System Administrator', CLM_USER_SEED);
        System.runAs(clm) {
            createData();
        }
    }

    /**
     * Creates a user with the Contract LifeCycle Management license and CLM permission sets.
     */
    private static User createClmUser(String profileName, String aliasSeed) {
        User usr = TestDataFactory_CC.createUser(profileName, aliasSeed, true);
        PermissionSetLicense psl = [SELECT Id FROM PermissionSetLicense WHERE DeveloperName = 'ContractManagementUser' LIMIT 1];
        insert new PermissionSetLicenseAssign(AssigneeId = usr.Id, PermissionSetLicenseId = psl.Id);
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN ('CLMAdminUser', 'CLMRuntimeUser')]) {
            assignments.add(new PermissionSetAssignment(AssigneeId = usr.Id, PermissionSetId = ps.Id));
        }
        insert assignments;
        return usr;
    }

    private static User clmUser() {
        String pattern = CLM_USER_SEED + '%';
        return [SELECT Id FROM User WHERE Username LIKE :pattern LIMIT 1];
    }

    private static void createData() {
        Id standardPricebookId = Test.getStandardPricebookId();
        // Order.AccountId has a lookup filter: Account.Type must be Customer.
        Account entity = TestDataFactory_CC.createEntity('OCL Entity', null, false);
        entity.Type = 'Customer';
        insert entity;

        Product2 productA = TestDataFactory_CC.createProduct(PRODUCT_A, false);
        Product2 productB = TestDataFactory_CC.createProduct(PRODUCT_B, false);
        Product2 productC = TestDataFactory_CC.createProduct(PRODUCT_C, false);
        Product2 productD = TestDataFactory_CC.createProduct(PRODUCT_D, false);
        insert new List<Product2>{ productA, productB, productC, productD };

        // Product C intentionally has no Price Book Entry.
        insert new List<PricebookEntry>{
            TestDataFactory_CC.createStandardPricebookEntry(productA.Id, 40, false),
            TestDataFactory_CC.createStandardPricebookEntry(productB.Id, 40, false),
            TestDataFactory_CC.createStandardPricebookEntry(productD.Id, 40, false)
        };

        Contract mainContract = buildContract(entity.Id, standardPricebookId, CONTRACT_NAME);
        insertContracts(new List<Contract>{ mainContract });

        insertData(new List<SalesContractLine>{
            buildLine(mainContract.Id, productA, 10, 'No', null, 50, 'Line A'),
            buildLine(mainContract.Id, productB, 20, 'Yes', 5, 40, 'Line B'),
            buildLine(mainContract.Id, productC, 5, 'No', null, 10, 'Line C'),
            buildLine(mainContract.Id, productD, 10, 'Yes', null, 40, 'Line D')
        });

        mainContract.Status = 'Active';
        updateContracts(new List<Contract>{ mainContract });

        insertData(new List<Order>{ buildOrder(entity.Id, mainContract.Id, standardPricebookId) });
    }

    // ------------------------------------------------------------------ helpers

    /*
     * Test data is saved in system mode. Inside System.runAs the save is checked against the running
     * user's field-level security, and the System Administrator profile is not granted edit access to
     * every field in every org (QA lacks Contract.Name and the new Contract Line MOQ fields), which made
     * every test in this class fail during setup. The data is scaffolding; the user's access is not under
     * test here, while the controller calls below still run as the test user.
     */
    private static void insertContracts(List<Contract> contracts) {
        Database.insert(contracts, AccessLevel.SYSTEM_MODE);
    }

    private static void updateContracts(List<Contract> contracts) {
        Database.update(contracts, AccessLevel.SYSTEM_MODE);
    }

    private static void insertData(List<SObject> records) {
        Database.insert(records, AccessLevel.SYSTEM_MODE);
    }

    private static Contract buildContract(Id accountId, Id pricebookId, String name) {
        return new Contract(
            AccountId = accountId,
            Name = name,
            Status = 'Draft',
            StartDate = Date.today(),
            ContractTerm = 12,
            Pricebook2Id = pricebookId
        );
    }

    private static SalesContractLine buildLine(Id contractId, Product2 product, Decimal quantity,
                                               String moqRequired, Decimal minimum, Decimal unitPrice,
                                               String description) {
        return new SalesContractLine(
            ContractId = contractId,
            Name = product.Name,
            Product2Id = product.Id,
            Quantity = quantity,
            UnitPrice = unitPrice,
            Description = description,
            MOQ_Required_CC__c = moqRequired,
            Minimum_Order_Quantity_CC__c = minimum
        );
    }

    private static Order buildOrder(Id accountId, Id contractId, Id pricebookId) {
        return new Order(
            AccountId = accountId,
            ContractId = contractId,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = pricebookId
        );
    }

    private static Account entity() {
        return [SELECT Id FROM Account WHERE Name = 'OCL Entity' LIMIT 1];
    }

    private static Contract mainContract() {
        // Test lookups read in system mode for the same field-level security reason as the inserts above.
        return [SELECT Id, AccountId FROM Contract WHERE Name = :CONTRACT_NAME WITH SYSTEM_MODE LIMIT 1];
    }

    private static Order mainOrder() {
        return [SELECT Id, Status, Pricebook2Id FROM Order WHERE ContractId = :mainContract().Id WITH SYSTEM_MODE ORDER BY CreatedDate LIMIT 1];
    }

    private static SalesContractLine line(String productName) {
        return [
            SELECT Id, Quantity, Remaining_SKU_CC__c, MOQ_Required_CC__c, Minimum_Order_Quantity_CC__c
            FROM SalesContractLine
            WHERE ContractId = :mainContract().Id AND Product2.Name = :productName
            WITH SYSTEM_MODE
            LIMIT 1
        ];
    }

    private static Map<String, Object> entry(Object contractLineId, Object quantity) {
        return new Map<String, Object>{ 'contractLineId' => contractLineId, 'orderQuantity' => quantity };
    }

    private static String payload(List<Map<String, Object>> entries) {
        return JSON.serialize(entries);
    }

    /** Calls saveOrderLines and returns the AuraHandledException message (or null when it succeeds). */
    private static String saveError(Id orderId, String json) {
        try {
            OrderContractLineController_CC.saveOrderLines(orderId, json);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static Order standaloneOrder() {
        Order o = new Order(
            AccountId = entity().Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert o;
        return o;
    }

    // ------------------------------------------------------------------ getContractLines

    /**
     * Verifies getContractLines returns every Contract Line with MOQ settings, recalculates
     * Remaining SKU for all lines on first load and is idempotent on the second load.
     */
    @IsTest
    static void getContractLinesReturnsLinesAndRecalculates() {
        System.runAs(clmUser()) {
            Order orderRecord = mainOrder();

            Test.startTest();
            OrderContractLineController_CC.ContractLinesResult first =
                OrderContractLineController_CC.getContractLines(orderRecord.Id);
            OrderContractLineController_CC.ContractLinesResult second =
                OrderContractLineController_CC.getContractLines(orderRecord.Id);
            Test.stopTest();

            Assert.areEqual(4, first.lines.size(), 'All four Contract Lines should be returned');
            Assert.areEqual(4, first.recalculatedLineCount, 'Remaining SKU was blank on all lines so all should be recalculated');
            Assert.areEqual(0, second.recalculatedLineCount, 'A second load must not change anything');
            Assert.areEqual('Draft', first.orderStatus, 'Order status should be returned');
            Assert.isTrue(first.isEditable, 'Draft Order should be editable');
            Assert.isFalse(first.isCancelled, 'Draft Order is not cancelled');
            Assert.isTrue(first.canCancel, 'Draft Order can be cancelled');

            Map<String, OrderContractLineController_CC.ContractLineWrapper> byProduct =
                new Map<String, OrderContractLineController_CC.ContractLineWrapper>();
            for (OrderContractLineController_CC.ContractLineWrapper w : first.lines) {
                byProduct.put(w.productName, w);
            }
            OrderContractLineController_CC.ContractLineWrapper lineA = byProduct.get(PRODUCT_A);
            OrderContractLineController_CC.ContractLineWrapper lineB = byProduct.get(PRODUCT_B);
            Assert.isFalse(lineA.moqRequired, 'Line A has MOQ Required = No');
            Assert.isNull(lineA.minimumOrderQuantity, 'Minimum is hidden when MOQ is not required');
            Assert.areEqual(10, lineA.remainingSKU, 'Remaining SKU equals the line quantity when nothing is ordered');
            Assert.areEqual(0, lineA.orderQuantity, 'Nothing ordered yet');
            Assert.areEqual(50, lineA.unitPrice, 'Unit price is taken from the line');
            Assert.areEqual('Line A', lineA.description, 'Description is taken from the line');
            Assert.isTrue(lineB.moqRequired, 'Line B has MOQ Required = Yes');
            Assert.areEqual(5, lineB.minimumOrderQuantity, 'Line B minimum order quantity');
            Assert.areEqual(20, line(PRODUCT_B).Remaining_SKU_CC__c, 'Remaining SKU must be persisted on the line');
        }
    }

    /**
     * Verifies getContractLines rejects a null Id, an unknown Order and an Order without a Contract.
     */
    @IsTest
    static void getContractLinesInvalidInputs() {
        System.runAs(clmUser()) {
            Order standalone = standaloneOrder();
            Id contractId = mainContract().Id;
            List<String> messages = new List<String>();

            Test.startTest();
            for (Id candidate : new List<Id>{ null, contractId, standalone.Id }) {
                try {
                    OrderContractLineController_CC.getContractLines(candidate);
                    messages.add('NO ERROR');
                } catch (AuraHandledException e) {
                    messages.add(e.getMessage());
                }
            }
            Test.stopTest();

            Assert.areEqual('Order Id is required.', messages[0], 'Null Order Id must be rejected');
            Assert.areEqual('The Order could not be found.', messages[1], 'Unknown Order must be rejected');
            Assert.areEqual('This Order is not created from a Contract.', messages[2], 'Order without Contract must be rejected');
        }
    }

    // ------------------------------------------------------------------ saveOrderLines

    /**
     * Verifies saving new quantities creates Order Products with price, description and the
     * MOQ snapshot, and reduces Remaining SKU on the Contract Lines.
     */
    @IsTest
    static void saveOrderLinesCreatesOrderItems() {
        System.runAs(clmUser()) {
            Order orderRecord = mainOrder();
            SalesContractLine lineA = line(PRODUCT_A);
            SalesContractLine lineB = line(PRODUCT_B);
            String json = payload(new List<Map<String, Object>>{ entry(lineA.Id, 3), entry(lineB.Id, '5') });

            Test.startTest();
            Integer changed = OrderContractLineController_CC.saveOrderLines(orderRecord.Id, json);
            Test.stopTest();

            Assert.areEqual(2, changed, 'Two Order Products should be created');
            Map<Id, OrderItem> itemsByLine = new Map<Id, OrderItem>();
            for (OrderItem item : [
                SELECT Quantity, UnitPrice, Description, MOQ_Required_CC__c, Minimum_Order_Quantity_CC__c, Sales_Contract_Line_CC__c
                FROM OrderItem WHERE OrderId = :orderRecord.Id
                WITH SYSTEM_MODE
            ]) {
                itemsByLine.put(item.Sales_Contract_Line_CC__c, item);
            }
            OrderItem itemA = itemsByLine.get(lineA.Id);
            OrderItem itemB = itemsByLine.get(lineB.Id);
            Assert.areEqual(3, itemA.Quantity, 'Order Product A quantity');
            Assert.areEqual(50, itemA.UnitPrice, 'Unit price comes from the Contract Line');
            Assert.areEqual('Line A', itemA.Description, 'Description comes from the Contract Line');
            Assert.areEqual('No', itemA.MOQ_Required_CC__c, 'MOQ snapshot for a non-MOQ line');
            Assert.isNull(itemA.Minimum_Order_Quantity_CC__c, 'No minimum stamped for a non-MOQ line');
            Assert.areEqual(5, itemB.Quantity, 'Order Product B quantity');
            Assert.areEqual('Yes', itemB.MOQ_Required_CC__c, 'MOQ snapshot for an MOQ line');
            Assert.areEqual(5, itemB.Minimum_Order_Quantity_CC__c, 'Minimum stamped from the Contract Line');
            Assert.areEqual(7, line(PRODUCT_A).Remaining_SKU_CC__c, 'Remaining SKU A = 10 - 3');
            Assert.areEqual(15, line(PRODUCT_B).Remaining_SKU_CC__c, 'Remaining SKU B = 20 - 5');
        }
    }

    /**
     * Verifies a second save updates an existing Order Product, deletes one set to 0, skips
     * unchanged lines and releases Remaining SKU accordingly.
     */
    @IsTest
    static void saveOrderLinesUpdatesAndDeletes() {
        System.runAs(clmUser()) {
            Order orderRecord = mainOrder();
            SalesContractLine lineA = line(PRODUCT_A);
            SalesContractLine lineB = line(PRODUCT_B);
            SalesContractLine lineC = line(PRODUCT_C);
            OrderContractLineController_CC.saveOrderLines(orderRecord.Id,
                payload(new List<Map<String, Object>>{ entry(lineA.Id, 3), entry(lineB.Id, 5) }));

            Test.startTest();
            Integer changed = OrderContractLineController_CC.saveOrderLines(orderRecord.Id,
                payload(new List<Map<String, Object>>{ entry(lineA.Id, 4), entry(lineB.Id, 0), entry(lineC.Id, null) }));
            OrderContractLineController_CC.ContractLinesResult result =
                OrderContractLineController_CC.getContractLines(orderRecord.Id);
            Test.stopTest();

            Assert.areEqual(2, changed, 'One update and one delete expected; unchanged line C is skipped');
            List<OrderItem> items = [SELECT Quantity, Sales_Contract_Line_CC__c FROM OrderItem WHERE OrderId = :orderRecord.Id WITH SYSTEM_MODE];
            Assert.areEqual(1, items.size(), 'Order Product for line B must be deleted');
            Assert.areEqual(lineA.Id, items[0].Sales_Contract_Line_CC__c, 'Remaining Order Product belongs to line A');
            Assert.areEqual(4, items[0].Quantity, 'Order Product A quantity updated to 4');
            Assert.areEqual(6, line(PRODUCT_A).Remaining_SKU_CC__c, 'Remaining SKU A = 10 - 4');
            Assert.areEqual(20, line(PRODUCT_B).Remaining_SKU_CC__c, 'Remaining SKU B fully released');
            for (OrderContractLineController_CC.ContractLineWrapper w : result.lines) {
                if (w.contractLineId == lineA.Id) {
                    Assert.areEqual(4, w.orderQuantity, 'Loaded order quantity reflects the saved Order Product');
                }
            }
        }
    }

    /**
     * Verifies business-rule validation: quantity above Remaining SKU, below MOQ, invalid MOQ setup,
     * missing Price Book Entry, negative quantity and lines from another Contract.
     */
    @IsTest
    static void saveOrderLinesBusinessValidation() {
        System.runAs(clmUser()) {
            Order orderRecord = mainOrder();
            Contract otherContract = buildContract(entity().Id, Test.getStandardPricebookId(), 'OCL Other Contract');
            insertContracts(new List<Contract>{ otherContract });
            Product2 productA = [SELECT Id, Name FROM Product2 WHERE Name = :PRODUCT_A LIMIT 1];
            SalesContractLine foreignLine = buildLine(otherContract.Id, productA, 5, 'No', null, 10, 'Foreign');
            insertData(new List<SalesContractLine>{ foreignLine });

            Test.startTest();
            String exceed = saveError(orderRecord.Id, payload(new List<Map<String, Object>>{ entry(line(PRODUCT_A).Id, 11) }));
            String belowMoq = saveError(orderRecord.Id, payload(new List<Map<String, Object>>{ entry(line(PRODUCT_B).Id, 2) }));
            String invalidMoq = saveError(orderRecord.Id, payload(new List<Map<String, Object>>{ entry(line(PRODUCT_D).Id, 3) }));
            String noEntry = saveError(orderRecord.Id, payload(new List<Map<String, Object>>{ entry(line(PRODUCT_C).Id, 2) }));
            String negative = saveError(orderRecord.Id, payload(new List<Map<String, Object>>{ entry(line(PRODUCT_A).Id, -1) }));
            String foreign = saveError(orderRecord.Id, payload(new List<Map<String, Object>>{ entry(foreignLine.Id, 1) }));
            Test.stopTest();

            Assert.areEqual('Order Quantity for ' + PRODUCT_A + ' cannot exceed the available Remaining SKU. Available: 10.', exceed, 'Quantity above Remaining SKU');
            Assert.areEqual('Order Quantity for ' + PRODUCT_B + ' must be at least 5.', belowMoq, 'Quantity below MOQ');
            Assert.areEqual('Minimum Order Quantity must be defined for ' + PRODUCT_D + ' because MOQ is required.', invalidMoq, 'MOQ without minimum');
            Assert.areEqual('No active Price Book Entry exists for ' + PRODUCT_C + ' in the Order Price Book.', noEntry, 'Missing Price Book Entry');
            Assert.areEqual('Order Quantity cannot be negative.', negative, 'Negative quantity');
            Assert.areEqual('One or more submitted Contract Lines do not belong to this Contract.', foreign, 'Line from another Contract');
            Assert.areEqual(0, [SELECT COUNT() FROM OrderItem WHERE OrderId = :orderRecord.Id WITH SYSTEM_MODE], 'No Order Products may be created on failure');
        }
    }

    /**
     * Verifies the JSON payload parser rejects blank, malformed and wrongly-typed input and treats
     * a missing quantity as 0.
     */
    @IsTest
    static void saveOrderLinesPayloadValidation() {
        System.runAs(clmUser()) {
            Order orderRecord = mainOrder();
            Id lineAId = line(PRODUCT_A).Id;

            Test.startTest();
            String blank = saveError(orderRecord.Id, '  ');
            String unreadable = saveError(orderRecord.Id, '{not json');
            String notList = saveError(orderRecord.Id, '{"a":1}');
            String emptyList = saveError(orderRecord.Id, '[]');
            String notMap = saveError(orderRecord.Id, '[1]');
            String missingId = saveError(orderRecord.Id, '[{"orderQuantity":1}]');
            String badId = saveError(orderRecord.Id, '[{"contractLineId":"abc","orderQuantity":1}]');
            String wrongType = saveError(orderRecord.Id, payload(new List<Map<String, Object>>{ entry(orderRecord.Id, 1) }));
            String badQty = saveError(orderRecord.Id, payload(new List<Map<String, Object>>{ entry(lineAId, 'abc') }));
            String nullOrder = saveError(null, payload(new List<Map<String, Object>>{ entry(lineAId, 1) }));
            Integer zeroChanges = OrderContractLineController_CC.saveOrderLines(orderRecord.Id,
                payload(new List<Map<String, Object>>{ entry(lineAId, '') }));
            Test.stopTest();

            Assert.areEqual('No Order Lines were submitted for saving.', blank, 'Blank payload');
            Assert.areEqual('The submitted Order Lines could not be read.', unreadable, 'Malformed JSON');
            Assert.areEqual('The submitted Order Lines are not in the expected format.', notList, 'JSON object instead of list');
            Assert.areEqual('No Order Lines were submitted for saving.', emptyList, 'Empty list');
            Assert.areEqual('Submitted Order Line 1 is not in the expected format.', notMap, 'List element is not an object');
            Assert.isTrue(missingId.startsWith('Submitted Order Line 1 does not contain a valid Contract Line Id'), 'Missing Id: ' + missingId);
            Assert.isTrue(badId.contains('Received: abc'), 'Invalid Id: ' + badId);
            Assert.isTrue(wrongType.contains('does not reference a Contract Line'), 'Id of another object: ' + wrongType);
            Assert.areEqual('Submitted Order Line 1 has an invalid Order Quantity: abc.', badQty, 'Non numeric quantity');
            Assert.areEqual('Order Id is required.', nullOrder, 'Null Order Id');
            Assert.areEqual(0, zeroChanges, 'Blank quantity is treated as 0 and nothing changes');
        }
    }

    /**
     * Verifies saving is rejected for an unknown Order, an Order without Contract, a non-Draft Order
     * and an Order that already has duplicate Order Products for one Contract Line.
     */
    @IsTest
    static void saveOrderLinesOrderStateValidation() {
        System.runAs(clmUser()) {
            Order orderRecord = mainOrder();
            Contract contractRecord = mainContract();
            Order standalone = standaloneOrder();
            SalesContractLine lineA = line(PRODUCT_A);
            String json = payload(new List<Map<String, Object>>{ entry(lineA.Id, 2) });

            // Second Order on the same Contract with two Order Products linked to line A.
            Order duplicateOrder = buildOrder(contractRecord.AccountId, contractRecord.Id, Test.getStandardPricebookId());
            insertData(new List<Order>{ duplicateOrder });
            PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Product2.Name = :PRODUCT_A AND Pricebook2Id = :Test.getStandardPricebookId() LIMIT 1];
            insertData(new List<OrderItem>{
                new OrderItem(OrderId = duplicateOrder.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 40, Sales_Contract_Line_CC__c = lineA.Id),
                new OrderItem(OrderId = duplicateOrder.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 40, Sales_Contract_Line_CC__c = lineA.Id)
            });

            Test.startTest();
            String unknown = saveError(contractRecord.Id, json);
            String noContract = saveError(standalone.Id, json);
            String duplicates = saveError(duplicateOrder.Id, json);
            OrderContractLineController_CC.cancelOrder(orderRecord.Id);
            String notDraft = saveError(orderRecord.Id, json);
            Test.stopTest();

            Assert.areEqual('The Order could not be found.', unknown, 'Unknown Order');
            Assert.areEqual('This Order is not created from a Contract.', noContract, 'Order without Contract');
            Assert.areEqual('More than one Order Product is linked to the Contract Line for ' + PRODUCT_A +
                '. Remove the duplicate Order Product before saving.', duplicates, 'Duplicate Order Products');
            Assert.areEqual('Order Lines can only be managed while the Order is in Draft status.', notDraft, 'Cancelled Order');
        }
    }

    /**
     * Verifies that when the Order has no Price Book the Contract Price Book is used and stamped on
     * the Order, and that an error is raised when neither has a Price Book.
     */
    @IsTest
    static void saveOrderLinesPricebookFallback() {
        System.runAs(clmUser()) {
            Id accountId = entity().Id;
            Product2 productA = [SELECT Id, Name FROM Product2 WHERE Name = :PRODUCT_A LIMIT 1];
            Contract withPricebook = buildContract(accountId, Test.getStandardPricebookId(), 'OCL PB Contract');
            Contract withoutPricebook = buildContract(accountId, null, 'OCL No PB Contract');
            insertContracts(new List<Contract>{ withPricebook, withoutPricebook });
            SalesContractLine linePb = buildLine(withPricebook.Id, productA, 10, 'No', null, null, 'PB line');
            SalesContractLine lineNoPb = buildLine(withoutPricebook.Id, productA, 10, 'No', null, 10, 'No PB line');
            insertData(new List<SalesContractLine>{ linePb, lineNoPb });
            withPricebook.Status = 'Active';
            withoutPricebook.Status = 'Active';
            updateContracts(new List<Contract>{ withPricebook, withoutPricebook });
            Order orderPb = buildOrder(accountId, withPricebook.Id, null);
            Order orderNoPb = buildOrder(accountId, withoutPricebook.Id, null);
            insertData(new List<Order>{ orderPb, orderNoPb });

            Test.startTest();
            Integer created = OrderContractLineController_CC.saveOrderLines(orderPb.Id,
                payload(new List<Map<String, Object>>{ entry(linePb.Id, 2) }));
            String error = saveError(orderNoPb.Id, payload(new List<Map<String, Object>>{ entry(lineNoPb.Id, 2) }));
            Test.stopTest();

            Assert.areEqual(1, created, 'One Order Product created');
            Assert.areEqual(Test.getStandardPricebookId(), [SELECT Pricebook2Id FROM Order WHERE Id = :orderPb.Id WITH SYSTEM_MODE].Pricebook2Id,
                'Contract Price Book is stamped on the Order');
            OrderItem item = [SELECT UnitPrice FROM OrderItem WHERE OrderId = :orderPb.Id WITH SYSTEM_MODE LIMIT 1];
            Assert.areEqual(40, item.UnitPrice, 'Unit price falls back to the Price Book Entry when the line has none');
            Assert.areEqual('A Price Book is required on the Order or its Contract before Order Lines can be created.', error,
                'Missing Price Book on Order and Contract');
        }
    }

    /**
     * Verifies a sales user can save a valid contract line as an Order Product.
     */
    @IsTest
    static void saveOrderLinesAsSalesUser() {
        System.runAs(clmUser()) {
            Order orderRecord = mainOrder();
            SalesContractLine lineB = line(PRODUCT_B);
            User salesUser = createClmUser('Carlton Sales User', 'oclsales');
            Integer created;

            Test.startTest();
            System.runAs(salesUser) {
                created = OrderContractLineController_CC.saveOrderLines(orderRecord.Id,
                    payload(new List<Map<String, Object>>{ entry(lineB.Id, 5) }));
            }
            Test.stopTest();

            Assert.areEqual(1, created, 'One contract line should be saved');
            Assert.areEqual(1, [SELECT COUNT() FROM OrderItem WHERE OrderId = :orderRecord.Id WITH SYSTEM_MODE],
                'The sales user should be able to create an Order Product');
        }
    }

    /**
     * Bulk: 200 Contract Lines saved in one call create 200 Order Products and reduce Remaining SKU.
     */
    @IsTest
    static void saveOrderLinesBulk() {
        System.runAs(clmUser()) {
            Id accountId = entity().Id;
            Product2 productA = [SELECT Id, Name FROM Product2 WHERE Name = :PRODUCT_A LIMIT 1];
            Contract bulkContract = buildContract(accountId, Test.getStandardPricebookId(), 'OCL Bulk Contract');
            insertContracts(new List<Contract>{ bulkContract });
            List<SalesContractLine> lines = new List<SalesContractLine>();
            for (Integer i = 0; i < 200; i++) {
                lines.add(buildLine(bulkContract.Id, productA, 10, 'No', null, 40, 'Bulk ' + i));
            }
            insertData(lines);
            bulkContract.Status = 'Active';
            updateContracts(new List<Contract>{ bulkContract });
            Order bulkOrder = buildOrder(accountId, bulkContract.Id, Test.getStandardPricebookId());
            insertData(new List<Order>{ bulkOrder });
            List<Map<String, Object>> entries = new List<Map<String, Object>>();
            for (SalesContractLine l : lines) {
                entries.add(entry(l.Id, 2));
            }

            Test.startTest();
            Integer changed = OrderContractLineController_CC.saveOrderLines(bulkOrder.Id, payload(entries));
            Test.stopTest();

            Assert.areEqual(200, changed, '200 Order Products expected');
            Assert.areEqual(200, [SELECT COUNT() FROM OrderItem WHERE OrderId = :bulkOrder.Id WITH SYSTEM_MODE], '200 Order Products persisted');
            Assert.areEqual(200, [SELECT COUNT() FROM SalesContractLine WHERE ContractId = :bulkContract.Id AND Remaining_SKU_CC__c = 8 WITH SYSTEM_MODE],
                'Every line should have Remaining SKU 10 - 2');
        }
    }

    // ------------------------------------------------------------------ cancelOrder

    /**
     * Verifies cancelOrder sets the Order to Cancelled, releases the reserved quantity and that the
     * Order is then reported as cancelled / not editable; cancelling again changes nothing.
     */
    @IsTest
    static void cancelOrderReleasesQuantity() {
        System.runAs(clmUser()) {
            Order orderRecord = mainOrder();
            SalesContractLine lineA = line(PRODUCT_A);
            OrderContractLineController_CC.saveOrderLines(orderRecord.Id,
                payload(new List<Map<String, Object>>{ entry(lineA.Id, 3) }));
            Assert.areEqual(7, line(PRODUCT_A).Remaining_SKU_CC__c, 'Precondition: 3 reserved');

            Test.startTest();
            Integer released = OrderContractLineController_CC.cancelOrder(orderRecord.Id);
            Integer secondRun = OrderContractLineController_CC.cancelOrder(orderRecord.Id);
            OrderContractLineController_CC.ContractLinesResult result =
                OrderContractLineController_CC.getContractLines(orderRecord.Id);
            Test.stopTest();

            Assert.areEqual('Cancelled', [SELECT Status FROM Order WHERE Id = :orderRecord.Id WITH SYSTEM_MODE].Status, 'Order must be Cancelled');
            Assert.areEqual(1, released, 'Only line A had reserved quantity to release');
            Assert.areEqual(0, secondRun, 'Cancelling again must not release quantity twice');
            Assert.areEqual(10, line(PRODUCT_A).Remaining_SKU_CC__c, 'Remaining SKU fully released');
            Assert.isTrue(result.isCancelled, 'Order reported as cancelled');
            Assert.isFalse(result.canCancel, 'Cancelled Order cannot be cancelled again');
            Assert.isFalse(result.isEditable, 'Cancelled Order is not editable');
        }
    }

    /**
     * Verifies cancelOrder rejects a null Id, an unknown Order and an Order without Contract.
     */
    @IsTest
    static void cancelOrderInvalidInputs() {
        System.runAs(clmUser()) {
            Order standalone = standaloneOrder();
            Id contractId = mainContract().Id;
            List<String> messages = new List<String>();

            Test.startTest();
            for (Id candidate : new List<Id>{ null, contractId, standalone.Id }) {
                try {
                    OrderContractLineController_CC.cancelOrder(candidate);
                    messages.add('NO ERROR');
                } catch (AuraHandledException e) {
                    messages.add(e.getMessage());
                }
            }
            Test.stopTest();

            Assert.areEqual('Order Id is required.', messages[0], 'Null Order Id');
            Assert.areEqual('The Order could not be found.', messages[1], 'Unknown Order');
            Assert.areEqual('This Order is not created from a Contract.', messages[2], 'Order without Contract');
            Assert.areEqual('Draft', [SELECT Status FROM Order WHERE Id = :standalone.Id WITH SYSTEM_MODE].Status, 'Standalone Order untouched');
        }
    }

    // ------------------------------------------------------------------ getRefreshRecordIds

    /**
     * Verifies getRefreshRecordIds returns the Order, its Order Products, the Contract and its lines,
     * an empty list for an unknown Order, only the Order when it has no Contract, and an error for null.
     */
    @IsTest
    static void getRefreshRecordIdsScenarios() {
        System.runAs(clmUser()) {
            Order orderRecord = mainOrder();
            Contract contractRecord = mainContract();
            Order standalone = standaloneOrder();
            OrderContractLineController_CC.saveOrderLines(orderRecord.Id,
                payload(new List<Map<String, Object>>{ entry(line(PRODUCT_A).Id, 3) }));
            Id itemId = [SELECT Id FROM OrderItem WHERE OrderId = :orderRecord.Id WITH SYSTEM_MODE LIMIT 1].Id;
            String nullError;

            Test.startTest();
            List<Id> ids = OrderContractLineController_CC.getRefreshRecordIds(orderRecord.Id);
            List<Id> unknown = OrderContractLineController_CC.getRefreshRecordIds(contractRecord.Id);
            List<Id> standaloneIds = OrderContractLineController_CC.getRefreshRecordIds(standalone.Id);
            try {
                OrderContractLineController_CC.getRefreshRecordIds(null);
            } catch (AuraHandledException e) {
                nullError = e.getMessage();
            }
            Test.stopTest();

            Set<Id> idSet = new Set<Id>(ids);
            Assert.areEqual(7, idSet.size(), 'Order + 1 Order Product + Contract + 4 Contract Lines');
            Assert.isTrue(idSet.contains(orderRecord.Id), 'Order Id included');
            Assert.isTrue(idSet.contains(itemId), 'Order Product Id included');
            Assert.isTrue(idSet.contains(contractRecord.Id), 'Contract Id included');
            Assert.isTrue(idSet.contains(line(PRODUCT_D).Id), 'Contract Line Ids included');
            Assert.isTrue(unknown.isEmpty(), 'Unknown Order returns an empty list');
            Assert.areEqual(new List<Id>{ standalone.Id }, standaloneIds, 'Order without Contract returns only itself');
            Assert.areEqual('Order Id is required.', nullError, 'Null Order Id');
        }
    }
}
