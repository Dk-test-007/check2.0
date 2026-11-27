@IsTest
private class ProductRelatedListController_CC_Test {
    /**
     * The controller reads and saves in user mode. The tests run as the System Administrator running them, with the
     * Carlton permission sets and field access (TestAdminAccess_CC), plus Opportunity_UI2_Admin_CC, which lets the
     * administrator mark the Entity as UI2 test data (keeps Business Central callouts out) and exempts the Order and
     * Order Product validation rules. Every test runs inside System.runAs so that access applies.
     */
    @TestSetup
    static void setup() {
        TestAdminAccess_CC.grant(new List<SObjectType>{ Account.SObjectType, Opportunity.SObjectType,
            OpportunityLineItem.SObjectType, Quote.SObjectType, QuoteLineItem.SObjectType, Order.SObjectType,
            OrderItem.SObjectType, Product2.SObjectType, Pricebook2.SObjectType, PricebookEntry.SObjectType,
            Warehouse_CC__c.SObjectType }, new List<String>{ OpportunityUi2TestData_CC.ISOLATION_PS });
        Id runningUserId = UserInfo.getUserId();
        System.runAs(adminUser()) {
            Account account = OpportunityUi2TestData_CC.entity(runningUserId, true);
            TestDmlRetry_CC.activateStandardPricebook();
            OpportunityUi2TestData_CC.standardEntry('ZZTEST Related List Product', 50, 'GBP');
            OpportunityUi2TestData_CC.newBusiness(account.Id, runningUserId, 100, 'GBP');
        }
    }

    private static Opportunity opportunity() {
        return [SELECT Id, AccountId, Pricebook2Id FROM Opportunity WHERE Name LIKE 'ZZUI2 Win%' LIMIT 1];
    }

    private static PricebookEntry entry() {
        return [SELECT Id, Product2Id, UnitPrice FROM PricebookEntry
            WHERE Product2.Name LIKE 'ZZTEST Related List Product%' LIMIT 1];
    }

    /** The System Administrator running the tests, with the access granted in setup. */
    private static User adminUser() {
        return TestAdminAccess_CC.admin();
    }

    private static Order insertOrder(Opportunity opp, Id pricebookId, Id quoteId) {
        Order orderRecord = new Order(AccountId = opp.AccountId, OpportunityId = opp.Id,
            Pricebook2Id = pricebookId, CurrencyIsoCode = 'GBP', EffectiveDate = Date.today(), Status = 'Draft');
        if (quoteId != null) {
            orderRecord.QuoteId = quoteId;
        }
        // Test data setup, not the behaviour under test: insert in system mode so field-level access of the
        // running user does not block it.
        Database.insert(orderRecord, AccessLevel.SYSTEM_MODE);
        return orderRecord;
    }

    private static Warehouse_CC__c insertWarehouse() {
        Warehouse_CC__c warehouse = new Warehouse_CC__c(Name = 'ZZTEST Warehouse',
            Warehouse_Code_CC__c = 'ZZWH' + OpportunityUi2TestData_CC.suffix(), Location_CC__c = 'NY');
        insert warehouse;
        return warehouse;
    }

    private static String payload(String idKey, Id recordId, Map<String, Object> values) {
        return JSON.serialize(new List<Object>{
            new Map<String, Object>{ idKey => recordId, 'values' => values }
        });
    }

    private static void assertSaveRejected(Id recordId, String payload, String deletes, String reason) {
        Boolean rejected = false;
        try {
            ProductRelatedListController_CC.saveProducts(recordId, payload, deletes);
        } catch (AuraHandledException expected) {
            rejected = true;
        }
        Assert.isTrue(rejected, reason + ' must be rejected');
    }

    private static void assertPricebookChangeRejected(Id recordId, Id pricebookId, String reason) {
        Boolean rejected = false;
        try {
            ProductRelatedListController_CC.changePricebook(recordId, pricebookId);
        } catch (AuraHandledException expected) {
            rejected = true;
        }
        Assert.isTrue(rejected, reason + ' must be rejected');
    }

    @IsTest
    static void loadsProductGridAndSearchResults() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            Map<String, Object> initial = ProductRelatedListController_CC.getInitialData(opp.Id);
            Assert.areEqual('Opportunity', initial.get('parentObjectApiName'));
            Assert.areEqual(0, initial.get('totalCount'));
            Assert.areEqual(opp.Pricebook2Id, initial.get('pricebookId'));

            List<Map<String, Object>> books = ProductRelatedListController_CC.getPricebooks(opp.Id);
            Assert.isFalse(books.isEmpty(), 'The active standard price book should be available');
            Map<String, Object> products = ProductRelatedListController_CC.getProducts(
                opp.Id, 'ZZTEST Related List Product', null, null, 1);
            Assert.areEqual(1, ((List<Map<String, Object>>) products.get('rows')).size());
            Assert.areEqual(false, products.get('hasMore'));
        }
    }

    @IsTest
    static void createsEditsAndDeletesAnOpportunityProduct() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            PricebookEntry selected = entry();
            String createPayload = JSON.serialize(new List<Object>{
                new Map<String, Object>{
                    'pricebookEntryId' => selected.Id,
                    'values' => new Map<String, Object>{ 'Quantity' => 2, 'UnitPrice' => 50 }
                }
            });
            ProductRelatedListController_CC.saveProducts(opp.Id, createPayload, '[]');
            OpportunityLineItem line = [SELECT Id, Quantity, UnitPrice FROM OpportunityLineItem
                WHERE OpportunityId = :opp.Id LIMIT 1];
            Assert.areEqual(2, line.Quantity);
            Assert.areEqual(1, ProductRelatedListController_CC.getInitialData(opp.Id).get('totalCount'));

            String updatePayload = JSON.serialize(new List<Object>{
                new Map<String, Object>{
                    'lineItemId' => line.Id,
                    'values' => new Map<String, Object>{ 'Quantity' => 3, 'UnitPrice' => 60 }
                }
            });
            ProductRelatedListController_CC.saveProducts(opp.Id, updatePayload, '[]');
            line = [SELECT Id, Quantity, UnitPrice FROM OpportunityLineItem WHERE Id = :line.Id];
            Assert.areEqual(3, line.Quantity);
            Assert.areEqual(60, line.UnitPrice);

            ProductRelatedListController_CC.saveProducts(opp.Id, '[]', JSON.serialize(new List<Id>{ line.Id }));
            Assert.areEqual(0, [SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId = :opp.Id]);
        }
    }

    @IsTest
    static void invalidCursorDoesNotReturnProducts() {
        System.runAs(adminUser()) {
            Boolean rejected = false;
            try {
                ProductRelatedListController_CC.getProducts(opportunity().Id, null, 'orphan cursor', null, 30);
            } catch (AuraHandledException expected) {
                rejected = true;
            }
            Assert.isTrue(rejected, 'An incomplete cursor must be rejected');
        }
    }

    @IsTest
    static void paginatesProductsAndRejectsInvalidChanges() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            OpportunityUi2TestData_CC.standardEntry('ZZTEST Related List Product B', 60, 'GBP');
            OpportunityUi2TestData_CC.standardEntry('ZZTEST Related List Product C', 70, 'GBP');

            Map<String, Object> first = ProductRelatedListController_CC.getProducts(
                opp.Id, 'ZZTEST Related List Product', null, null, 1);
            Assert.areEqual(true, first.get('hasMore'));
            Map<String, Object> second = ProductRelatedListController_CC.getProducts(
                opp.Id, 'ZZTEST Related List Product',
                (String) first.get('nextCursorName'), (Id) first.get('nextCursorEntryId'), 1);
            Assert.areEqual(1, ((List<Map<String, Object>>) second.get('rows')).size());
            Assert.areEqual(0, ((List<Map<String, Object>>) second.get('columns')).size(),
                'Column metadata is only needed on the first page');

            ProductRelatedListController_CC.changePricebook(opp.Id, opp.Pricebook2Id);
            Boolean rejected = false;
            try {
                ProductRelatedListController_CC.changePricebook(opp.Id, null);
            } catch (AuraHandledException expected) {
                rejected = true;
            }
            Assert.isTrue(rejected, 'An unavailable price book must be rejected');

            rejected = false;
            try {
                ProductRelatedListController_CC.saveProducts(opp.Id,
                    JSON.serialize(new List<Object>{
                        new Map<String, Object>{
                            'pricebookEntryId' => entry().Id,
                            'values' => new Map<String, Object>{ 'UnitPrice' => 50 }
                        }
                    }), '[]');
            } catch (AuraHandledException expected) {
                rejected = true;
            }
            Assert.isTrue(rejected, 'A required quantity cannot be omitted');
        }
    }

    @IsTest
    static void listsProductsForAnOrder() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            Order orderRecord = new Order(AccountId = opp.AccountId,
                OpportunityId = opp.Id, Pricebook2Id = opp.Pricebook2Id,
                CurrencyIsoCode = 'GBP', EffectiveDate = Date.today(), Status = 'Draft');
            insert orderRecord;

            Map<String, Object> products = ProductRelatedListController_CC.getProducts(
                orderRecord.Id, 'ZZTEST Related List Product', null, null, 10);
            Assert.areEqual(1, ((List<Map<String, Object>>) products.get('rows')).size());
        }
    }

    @IsTest
    static void loadsQuoteGridAndAvailableProducts() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            Quote quoteRecord = TestDataFactory_CC.createQuote(opp.Id, true);
            TestDataFactory_CC.createQuoteLineItem(quoteRecord.Id, entry(), 2, true);

            Map<String, Object> data = ProductRelatedListController_CC.getInitialData(quoteRecord.Id);
            Assert.areEqual('Quote', data.get('parentObjectApiName'));
            Assert.areEqual(1, data.get('totalCount'));
            Assert.areEqual(1, ((List<Map<String, Object>>) data.get('rows')).size());
            Map<String, Object> products = ProductRelatedListController_CC.getProducts(
                quoteRecord.Id, 'ZZTEST Related List Product', null, null, 10);
            Assert.areEqual(1, ((List<Map<String, Object>>) products.get('rows')).size());
        }
    }

    @IsTest
    static void changingPricebookRemovesOldLines() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            PricebookEntry selected = entry();
            ProductRelatedListController_CC.saveProducts(opp.Id,
                JSON.serialize(new List<Object>{ new Map<String, Object>{
                    'pricebookEntryId' => selected.Id,
                    'values' => new Map<String, Object>{ 'Quantity' => 2, 'UnitPrice' => 50 }
                }}), '[]');

            Pricebook2 alternative = new Pricebook2(Name = 'ZZTEST Alternative Price Book', IsActive = true);
            alternative.put('Entity__c', opp.AccountId);
            insert alternative;
            ProductRelatedListController_CC.changePricebook(opp.Id, alternative.Id);

            Opportunity afterChange = [SELECT Pricebook2Id FROM Opportunity WHERE Id = :opp.Id];
            Assert.areEqual(alternative.Id, afterChange.Pricebook2Id);
            Assert.areEqual(0, [SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId = :opp.Id]);
        }
    }

    @IsTest
    static void rejectsInvalidProductFieldsAndForeignLines() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            PricebookEntry selected = entry();
            String values = JSON.serialize(new List<Object>{ new Map<String, Object>{
                'pricebookEntryId' => selected.Id,
                'values' => new Map<String, Object>{ 'Quantity' => 2, 'UnitPrice' => 50,
                    'NotARealField__c' => 'bad' }
            }});
            assertSaveRejected(opp.Id, values, '[]', 'An unknown field');

            values = JSON.serialize(new List<Object>{ new Map<String, Object>{
                'lineItemId' => opp.Id,
                'values' => new Map<String, Object>{ 'Quantity' => 2, 'UnitPrice' => 50 }
            }});
            assertSaveRejected(opp.Id, values, '[]', 'A foreign line id');
            assertSaveRejected(opp.Id, '[]', JSON.serialize(new List<Id>{ opp.Id }), 'A foreign delete id');

            Pricebook2 foreignBook = new Pricebook2(Name = 'ZZTEST Foreign Price Book', IsActive = true);
            insert foreignBook;
            PricebookEntry foreignEntry = new PricebookEntry(Pricebook2Id = foreignBook.Id,
                Product2Id = selected.Product2Id, CurrencyIsoCode = 'GBP', UnitPrice = 50, IsActive = true);
            insert foreignEntry;
            values = JSON.serialize(new List<Object>{ new Map<String, Object>{
                'pricebookEntryId' => foreignEntry.Id,
                'values' => new Map<String, Object>{ 'Quantity' => 2, 'UnitPrice' => 50 }
            }});
            assertSaveRejected(opp.Id, values, '[]', 'An entry from another price book');
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Additional coverage: configuration, pagination limits, currency, DML errors, landing cost.
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void rejectsRecordsWithoutProductConfig() {
        System.runAs(adminUser()) {
            Boolean rejected = false;
            try {
                ProductRelatedListController_CC.getInitialData(opportunity().AccountId);
            } catch (AuraHandledException expected) {
                rejected = true;
            }
            Assert.isTrue(rejected, 'An object without a Product Config must be rejected');
        }
    }

    @IsTest
    static void clampsPageSizeAndIgnoresEmptySaves() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            OpportunityUi2TestData_CC.standardEntry('ZZTEST Related List Product D', 80, 'GBP');

            Map<String, Object> defaultPage = ProductRelatedListController_CC.getProducts(opp.Id, null, null, null, null);
            Assert.isTrue(((List<Map<String, Object>>) defaultPage.get('rows')).size() >= 2,
                'A missing page size falls back to the default page');
            Assert.isFalse(((List<Map<String, Object>>) defaultPage.get('columns')).isEmpty(),
                'The first page returns column metadata');

            Map<String, Object> minimumPage = ProductRelatedListController_CC.getProducts(opp.Id, '  ', null, null, 0);
            Assert.areEqual(1, ((List<Map<String, Object>>) minimumPage.get('rows')).size());
            Assert.areEqual(true, minimumPage.get('hasMore'));

            Map<String, Object> maximumPage = ProductRelatedListController_CC.getProducts(opp.Id, null, null, null, 5000);
            Assert.isTrue(((List<Map<String, Object>>) maximumPage.get('rows')).size() >= 2,
                'An oversized page is capped rather than rejected');

            ProductRelatedListController_CC.saveProducts(opp.Id, null, null);
            ProductRelatedListController_CC.saveProducts(opp.Id, '[]', '[]');
            Assert.areEqual(0, [SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId = :opp.Id]);
        }
    }

    @IsTest
    static void rejectsCurrencyMismatchAndUnavailableEntries() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            PricebookEntry usdEntry = OpportunityUi2TestData_CC.standardEntry('ZZTEST Dollar Product', 50, 'USD');
            assertSaveRejected(opp.Id,
                payload('pricebookEntryId', usdEntry.Id, new Map<String, Object>{ 'Quantity' => 1, 'UnitPrice' => 50 }),
                '[]', 'An entry in another currency');

            Id missingEntryId = (Id) (PricebookEntry.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
            assertSaveRejected(opp.Id,
                payload('pricebookEntryId', missingEntryId, new Map<String, Object>{
                    'Quantity' => 1, 'UnitPrice' => 50, 'Discount' => 5, 'SortOrder' => 1,
                    'ServiceDate' => String.valueOf(Date.today()), 'Description' => null }),
                '[]', 'An unavailable price book entry');
            Assert.areEqual(0, [SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId = :opp.Id]);
        }
    }

    @IsTest
    static void reportsDatabaseErrorsAsHandledExceptions() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            // Salesforce does not allow both Unit Price and Total Price on the same line item.
            assertSaveRejected(opp.Id,
                payload('pricebookEntryId', entry().Id, new Map<String, Object>{
                    'Quantity' => 1, 'UnitPrice' => 50, 'TotalPrice' => 50 }),
                '[]', 'A line rejected by the database');
            Assert.areEqual(0, [SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId = :opp.Id]);
        }
    }

    @IsTest
    static void calculatesLandingCostAndMargin() {
        System.runAs(adminUser()) {
            Opportunity opp = opportunity();
            Product2 costed = new Product2(Name = 'ZZTEST Landing Product A', IsActive = true,
                ProductCode = 'ZZLAND-' + OpportunityUi2TestData_CC.suffix(), CurrencyIsoCode = 'GBP',
                Estimated_Landing_Price_CC__c = 20);
            Product2 zeroPriced = new Product2(Name = 'ZZTEST Landing Product B', IsActive = true,
                ProductCode = 'ZZLAND-' + OpportunityUi2TestData_CC.suffix(), CurrencyIsoCode = 'GBP',
                Estimated_Landing_Price_CC__c = 5);
            insert new List<Product2>{ costed, zeroPriced };
            PricebookEntry costedEntry = new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(),
                Product2Id = costed.Id, UnitPrice = 50, IsActive = true, CurrencyIsoCode = 'GBP');
            PricebookEntry zeroPricedEntry = new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(),
                Product2Id = zeroPriced.Id, UnitPrice = 0, IsActive = true, CurrencyIsoCode = 'GBP');
            insert new List<PricebookEntry>{ costedEntry, zeroPricedEntry };

            Map<String, Object> products = ProductRelatedListController_CC.getProducts(
                opp.Id, 'ZZTEST Landing Product', null, null, 10);
            List<Map<String, Object>> rows = (List<Map<String, Object>>) products.get('rows');
            Assert.areEqual(2, rows.size());
            Assert.areEqual(costedEntry.Id, rows[0].get('pricebookEntryId'));

            ProductRelatedListController_CC.saveProducts(opp.Id,
                payload('pricebookEntryId', costedEntry.Id, new Map<String, Object>{ 'Quantity' => 4, 'UnitPrice' => 50 }),
                '[]');

            Map<String, Object> grid = ProductRelatedListController_CC.getInitialData(opp.Id);
            Assert.areEqual(1, grid.get('totalCount'));
            List<Map<String, Object>> editRows = (List<Map<String, Object>>) grid.get('editRows');
            Assert.areEqual(1, editRows.size());
            Assert.areEqual(costed.Id, editRows[0].get('productId'));
            Assert.areEqual(1, ((List<Map<String, Object>>) grid.get('rows')).size());
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Order grids. These run as the System Administrator with Opportunity_UI2_Admin_CC, which the Order and
    // Order Product validation rules exempt, so only the controller behaviour is under test.
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void createsEditsAndDeletesAnOrderProduct() {
        Opportunity opp = opportunity();
        PricebookEntry selected = entry();
        String shipmentDate = String.valueOf(Date.today().addDays(14));

        System.runAs(adminUser()) {
            Warehouse_CC__c warehouse = insertWarehouse();
            Order orderRecord = insertOrder(opp, Test.getStandardPricebookId(), null);

            Test.startTest();
            assertSaveRejected(orderRecord.Id,
                payload('pricebookEntryId', selected.Id, new Map<String, Object>{ 'Quantity' => 2, 'UnitPrice' => 50 }),
                '[]', 'A line without the required Location Code');

            ProductRelatedListController_CC.saveProducts(orderRecord.Id,
                payload('pricebookEntryId', selected.Id, new Map<String, Object>{
                    'Quantity' => 2, 'UnitPrice' => 50, 'Warehouse_CC__c' => warehouse.Id,
                    'Shipment_Date_CC__c' => shipmentDate, 'Location_Code_CC__c' => 'NY' }),
                '[]');
            OrderItem line = [SELECT Id, Quantity, Warehouse_CC__c, Shipment_Date_CC__c FROM OrderItem
                WHERE OrderId = :orderRecord.Id LIMIT 1];
            Assert.areEqual(2, line.Quantity);
            Assert.areEqual(warehouse.Id, line.Warehouse_CC__c);
            Assert.areEqual(Date.valueOf(shipmentDate), line.Shipment_Date_CC__c);

            Map<String, Object> grid = ProductRelatedListController_CC.getInitialData(orderRecord.Id);
            Assert.areEqual('Order', grid.get('parentObjectApiName'));
            Assert.areEqual(false, grid.get('isRestrictedEditMode'));
            Assert.areEqual(1, grid.get('totalCount'));
            Assert.areEqual(1, ((List<Map<String, Object>>) grid.get('editRows')).size());

            ProductRelatedListController_CC.saveProducts(orderRecord.Id,
                payload('lineItemId', line.Id, new Map<String, Object>{
                    'Quantity' => 3, 'UnitPrice' => 50, 'Warehouse_CC__c' => warehouse.Id,
                    'Location_Code_CC__c' => 'NY' }),
                '[]');
            Assert.areEqual(3, [SELECT Quantity FROM OrderItem WHERE Id = :line.Id].Quantity);

            ProductRelatedListController_CC.saveProducts(orderRecord.Id, '[]',
                JSON.serialize(new List<Id>{ line.Id }));
            Test.stopTest();
            Assert.areEqual(0, [SELECT COUNT() FROM OrderItem WHERE OrderId = :orderRecord.Id]);
        }
    }

    @IsTest
    static void convertsEveryOrderProductFieldType() {
        Opportunity opp = opportunity();
        Id missingEntryId = (Id) (PricebookEntry.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        System.runAs(adminUser()) {
            Warehouse_CC__c warehouse = insertWarehouse();
            Order orderRecord = insertOrder(opp, Test.getStandardPricebookId(), null);

            // Every value is converted (date, double, currency, percent, integer, boolean, reference, null)
            // before the missing price book entry stops the save, so nothing is written.
            assertSaveRejected(orderRecord.Id,
                payload('pricebookEntryId', missingEntryId, new Map<String, Object>{
                    'Quantity' => 2,
                    'UnitPrice' => 50,
                    'Discount' => 10,
                    'LineNumber' => 1,
                    'DoesAutomaticallyRenew' => false,
                    'Warehouse_CC__c' => warehouse.Id,
                    'Shipment_Date_CC__c' => String.valueOf(Date.today()),
                    'Description' => null
                }),
                '[]', 'A missing price book entry');
            Assert.areEqual(0, [SELECT COUNT() FROM OrderItem WHERE OrderId = :orderRecord.Id]);
        }
    }

    @IsTest
    static void requiresPricebookBeforeListingOrderProducts() {
        Opportunity opp = opportunity();

        System.runAs(adminUser()) {
            Order orderRecord = insertOrder(opp, null, null);
            if ([SELECT Pricebook2Id FROM Order WHERE Id = :orderRecord.Id].Pricebook2Id != null) {
                // Guard against automation defaulting a price book: the Order has no products yet.
                Database.update(new Order(Id = orderRecord.Id, Pricebook2Id = null), AccessLevel.SYSTEM_MODE);
            }

            Map<String, Object> grid = ProductRelatedListController_CC.getInitialData(orderRecord.Id);
            Assert.isNull(grid.get('pricebookId'));
            Assert.areEqual(0, grid.get('totalCount'));

            Boolean rejected = false;
            try {
                ProductRelatedListController_CC.getProducts(orderRecord.Id, null, null, null, 10);
            } catch (AuraHandledException expected) {
                rejected = true;
            }
            Assert.isTrue(rejected, 'Products cannot be listed before a price book is chosen');

            List<Map<String, Object>> books = ProductRelatedListController_CC.getPricebooks(orderRecord.Id);
            Assert.isFalse(books.isEmpty(), 'The standard price book is eligible');

            ProductRelatedListController_CC.changePricebook(orderRecord.Id, Test.getStandardPricebookId());
            Assert.areEqual(Test.getStandardPricebookId(),
                [SELECT Pricebook2Id FROM Order WHERE Id = :orderRecord.Id].Pricebook2Id);
        }
    }

    @IsTest
    static void restrictsNewBusinessOrdersToShipmentFields() {
        Opportunity opp = opportunity();
        PricebookEntry selected = entry();
        String shipmentDate = String.valueOf(Date.today().addDays(21));

        System.runAs(adminUser()) {
            Quote quoteRecord = TestDataFactory_CC.createQuote(opp.Id, true);
            TestDataFactory_CC.createQuoteLineItem(quoteRecord.Id, selected, 2, true);
            Order orderRecord = insertOrder(opp, Test.getStandardPricebookId(), quoteRecord.Id);

            List<OrderItem> lines = [SELECT Id FROM OrderItem WHERE OrderId = :orderRecord.Id];
            if (lines.isEmpty()) {
                // Normally copied from the Quote by the Order trigger; create one if that automation is off.
                Database.insert(new OrderItem(OrderId = orderRecord.Id, PricebookEntryId = selected.Id,
                    Quantity = 2, UnitPrice = 50), AccessLevel.SYSTEM_MODE);
                lines = [SELECT Id FROM OrderItem WHERE OrderId = :orderRecord.Id];
            }
            Id lineId = lines[0].Id;

            Test.startTest();
            Map<String, Object> grid = ProductRelatedListController_CC.getInitialData(orderRecord.Id);
            Assert.areEqual(true, grid.get('isRestrictedEditMode'), 'A Quote-sourced Order is New Business');

            assertPricebookChangeRejected(orderRecord.Id, Test.getStandardPricebookId(),
                'A price book change on a New Business Order');
            assertSaveRejected(orderRecord.Id,
                payload('pricebookEntryId', selected.Id, new Map<String, Object>{ 'Quantity' => 1, 'UnitPrice' => 50 }),
                '[]', 'Adding a product to a New Business Order');
            assertSaveRejected(orderRecord.Id,
                payload('lineItemId', lineId, new Map<String, Object>{ 'Quantity' => 5 }),
                '[]', 'A commercial change on a New Business Order');
            assertSaveRejected(orderRecord.Id, '[]', JSON.serialize(new List<Id>{ lineId }),
                'Deleting a product from a New Business Order');

            // Only the editable shipment columns (Shipment Date, Location Code) may change on a New Business Order.
            ProductRelatedListController_CC.saveProducts(orderRecord.Id,
                payload('lineItemId', lineId, new Map<String, Object>{
                    'Shipment_Date_CC__c' => shipmentDate, 'Location_Code_CC__c' => 'NY' }),
                '[]');
            Test.stopTest();

            OrderItem updated = [SELECT Location_Code_CC__c, Shipment_Date_CC__c FROM OrderItem WHERE Id = :lineId];
            Assert.areEqual('NY', updated.Location_Code_CC__c);
            Assert.areEqual(Date.valueOf(shipmentDate), updated.Shipment_Date_CC__c);
        }
    }
}