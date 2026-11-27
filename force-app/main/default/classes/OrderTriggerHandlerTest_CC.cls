/**
 * =============================================================================
 * Class Name    : OrderTriggerHandlerTest_CC
 * Description   : Unit tests for OrderTriggerHandler_CC and the OrderTrigger_CC trigger.
 *                 Covers Quote/Contract/Opportunity sourced Orders (address and detail
 *                 sync, Order Product creation, shipping and handling), activation rules,
 *                 Business Central publishing (queueable callouts), BAU Opportunity amount
 *                 roll-ups (insert/update/delete/undelete) and bulk inserts.
 * =============================================================================
 */
@IsTest
private class OrderTriggerHandlerTest_CC {

    private static final Decimal QUOTE_SHIPPING = 25;
    private static final String PRICE_GROUP = 'RETAIL';
    // Non-admin profile used for the activated-record edit checks. The production code queries Profile,
    // which needs "View Setup and Configuration"; none of the Carlton profiles have it (see report),
    // so a standard non-admin profile that does is used to reach the validation logic.
    private static final String NON_ADMIN_PROFILE = 'Standard User';

    @TestSetup
    static void setupData() {
        // New Business chain: Entity -> Site -> Opportunity -> primary site -> Quote with one line
        TestDataFactory_CC.SalesChain chain = TestDataFactory_CC.createSalesChain();

        Account entity = new Account(Id = chain.entity.Id, Type = 'Customer', Customer_Price_Group_CC__c = PRICE_GROUP);
        update entity;

        Quote qt = new Quote(Id = chain.quote.Id, ShippingHandling = QUOTE_SHIPPING);
        update qt;

        // BAU Opportunity on the same Entity with its own primary site
        Opportunity bauOpp = TestDataFactory_CC.createOpportunity(chain.entity.Id, 'BAU', false);
        bauOpp.Name = 'BAU Order Opp';
        bauOpp.Ship_To_Site_CC__c = chain.site.Id;
        insert bauOpp;
        TestDataFactory_CC.createOpportunitySite(bauOpp.Id, chain.site.Id, true, true);

        // All Site accounts are created here (Site codes are auto-numbered and unique).
        // BAU Opportunity whose Entity has no billing address
        Account noBillingEntity = TestDataFactory_CC.createEntity('No Billing Entity', null, false);
        noBillingEntity.Type = 'Customer';
        noBillingEntity.BillingStreet = null;
        noBillingEntity.BillingCity = null;
        noBillingEntity.BillingState = null;
        noBillingEntity.BillingPostalCode = null;
        noBillingEntity.BillingCountry = null;
        insert noBillingEntity;
        Account noBillingSite = TestDataFactory_CC.createSite('No Billing Site', noBillingEntity.Id, true);
        Opportunity noBillingOpp = TestDataFactory_CC.createOpportunity(noBillingEntity.Id, 'BAU', false);
        noBillingOpp.Name = 'No Billing Opp';
        insert noBillingOpp;
        TestDataFactory_CC.createOpportunitySite(noBillingOpp.Id, noBillingSite.Id, true, true);

        // BAU Opportunity whose primary Site has no shipping address
        Account noShippingSite = TestDataFactory_CC.createSite('No Shipping Site', chain.entity.Id, false);
        noShippingSite.ShippingStreet = null;
        noShippingSite.ShippingCity = null;
        noShippingSite.ShippingState = null;
        noShippingSite.ShippingPostalCode = null;
        noShippingSite.ShippingCountry = null;
        insert noShippingSite;
        Opportunity noShippingOpp = TestDataFactory_CC.createOpportunity(chain.entity.Id, 'BAU', false);
        noShippingOpp.Name = 'No Shipping Opp';
        insert noShippingOpp;
        TestDataFactory_CC.createOpportunitySite(noShippingOpp.Id, noShippingSite.Id, true, true);
    }

    // ------------------------------------------------------------------ helpers

    private static Quote getQuote() {
        return [SELECT Id, OpportunityId, Pricebook2Id, BillingStreet, ShippingStreet FROM Quote LIMIT 1];
    }

    private static Account getEntity() {
        return [SELECT Id FROM Account WHERE RecordType.DeveloperName = 'Entity' AND Name LIKE 'Chain Entity%' LIMIT 1];
    }

    private static Opportunity getBauOpp() {
        return [SELECT Id, Ship_To_Site_CC__c, BAU_Amount_With_Freight_CC__c, BAU_Amount_Without_Freight_CC__c
                FROM Opportunity WHERE Name = 'BAU Order Opp' LIMIT 1];
    }

    private static PricebookEntry getPricebookEntry() {
        return [SELECT Id, Product2Id, UnitPrice FROM PricebookEntry WHERE Pricebook2Id = :Test.getStandardPricebookId() LIMIT 1];
    }

    private static Order buildQuoteOrder(Id accountId, Id quoteId) {
        return new Order(AccountId = accountId, QuoteId = quoteId, EffectiveDate = Date.today(), Status = 'Draft');
    }

    private static Order buildOpportunityOrder(Id accountId, Id oppId) {
        return new Order(AccountId = accountId, OpportunityId = oppId, EffectiveDate = Date.today(), Status = 'Draft',
                         Pricebook2Id = Test.getStandardPricebookId());
    }

    private static Contract buildContract(Id accountId, Id quoteId) {
        return new Contract(Name = 'Test Contract', AccountId = accountId, SourceQuoteId = quoteId, Status = 'Draft',
                            StartDate = Date.today(), ContractTerm = 12);
    }

    private static Integer calloutJobCount() {
        return [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'CalloutService_CC'];
    }

    // ------------------------------------------------------------------ insert from Quote

    // Verifies an Order created from a New Business Quote copies the Quote addresses, Opportunity,
    // price book, shipping and handling, customer price group / customer numbers and creates Order Products.
    @IsTest
    static void testInsertFromQuoteSyncsDetailsAndCreatesItems() {
        Quote qt = getQuote();
        Account entity = getEntity();

        Test.startTest();
        Order ord = buildQuoteOrder(entity.Id, qt.Id);
        insert ord;
        Test.stopTest();

        Order result = [SELECT Id, OpportunityId, Pricebook2Id, BillingStreet, ShippingStreet, Shipping_and_Handling__c,
                               Customer_Price_Group_CC__c, Bill_to_Customer_No_CC__c, Sell_to_Customer_No_CC__c, Status
                        FROM Order WHERE Id = :ord.Id WITH SYSTEM_MODE];
        Assert.areEqual(qt.OpportunityId, result.OpportunityId, 'Opportunity should be copied from the Quote');
        Assert.areEqual(qt.Pricebook2Id, result.Pricebook2Id, 'Price book should be copied from the Quote');
        Assert.areEqual(qt.BillingStreet, result.BillingStreet, 'Billing street should be copied from the Quote');
        Assert.areEqual(qt.ShippingStreet, result.ShippingStreet, 'Shipping street should be copied from the Quote');
        Assert.isNotNull(result.BillingStreet, 'Quote billing address should be populated');
        Assert.isNull(result.Shipping_and_Handling__c, 'The disabled shipping sync leaves this field empty');
        Assert.isNull(result.Customer_Price_Group_CC__c, 'The disabled price group sync leaves this field empty');
        Assert.areEqual(entity.Id, result.Bill_to_Customer_No_CC__c, 'Bill-to customer should be the Account');
        Assert.areEqual(entity.Id, result.Sell_to_Customer_No_CC__c, 'Sell-to customer should be the Account');

        List<OrderItem> items = [SELECT Id, Quantity, UnitPrice, QuoteLineItemId FROM OrderItem WHERE OrderId = :ord.Id];
        QuoteLineItem qli = [SELECT Id, Quantity, UnitPrice FROM QuoteLineItem WHERE QuoteId = :qt.Id LIMIT 1];
        Assert.areEqual(1, items.size(), 'One Order Product should be created from the Quote line');
        Assert.areEqual(qli.Id, items[0].QuoteLineItemId, 'Order Product should reference the Quote line');
        Assert.areEqual(qli.Quantity, items[0].Quantity, 'Quantity should be copied from the Quote line');
        Assert.areEqual(qli.UnitPrice, items[0].UnitPrice, 'Unit price should be copied from the Quote line');
    }

    // Verifies no Order Products are created when the Quote's Opportunity is not New Business (BAU).
    @IsTest
    static void testInsertFromBauQuoteCreatesNoItems() {
        Opportunity bauOpp = getBauOpp();
        Account entity = getEntity();
        Quote bauQuote = TestDataFactory_CC.createQuote(bauOpp.Id, true);
        TestDataFactory_CC.createQuoteLineItem(bauQuote.Id, getPricebookEntry(), 3, true);

        Test.startTest();
        Order ord = buildQuoteOrder(entity.Id, bauQuote.Id);
        insert ord;
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM OrderItem WHERE OrderId = :ord.Id],
            'Order Products are only auto-created for New Business Quotes');
        Assert.areEqual(bauOpp.Id, [SELECT OpportunityId FROM Order WHERE Id = :ord.Id].OpportunityId,
            'Opportunity should still be copied from the Quote');
    }

    // Verifies an Order cannot be created from a Quote that already has a Contract.
    @IsTest
    static void testInsertFromQuoteBlockedWhenContractExists() {
        Quote qt = getQuote();
        Account entity = getEntity();
        insert buildContract(entity.Id, qt.Id);

        Test.startTest();
        Database.SaveResult sr = Database.insert(buildQuoteOrder(entity.Id, qt.Id), false);
        Test.stopTest();

        Assert.isFalse(sr.isSuccess(), 'Order insert should fail when a Contract exists for the Quote');
        Assert.isTrue(sr.getErrors()[0].getMessage().contains('A Contract already exists for this Quote.'),
            'Unexpected error: ' + sr.getErrors()[0].getMessage());
    }

    // ------------------------------------------------------------------ insert from Contract

    // Verifies an Order created from a Contract copies the Contract addresses, source Quote and
    // Opportunity, is forced to Draft, takes shipping from the source Quote and creates no Order Products.
    @IsTest
    static void testInsertFromContractSyncsDetails() {
        Quote qt = getQuote();
        Account entity = getEntity();
        Contract con = buildContract(entity.Id, qt.Id);
        insert con;
        con = [SELECT Id, BillingStreet, ShippingStreet, SourceQuoteId, SourceOpportunityId FROM Contract WHERE Id = :con.Id];

        Test.startTest();
        Order ord = new Order(AccountId = entity.Id, ContractId = con.Id, EffectiveDate = Date.today(), Status = 'Draft');
        insert ord;
        Test.stopTest();

        Order result = [SELECT Status, QuoteId, OpportunityId, BillingStreet, ShippingStreet, Shipping_and_Handling__c
                        FROM Order WHERE Id = :ord.Id];
        Assert.areEqual('Draft', result.Status, 'Contract Orders should be Draft');
        Assert.areEqual(qt.Id, result.QuoteId, 'Quote should be copied from the Contract source Quote');
        Assert.areEqual(qt.OpportunityId, result.OpportunityId, 'Opportunity should be copied from the Contract');
        Assert.areEqual(con.BillingStreet, result.BillingStreet, 'Billing street should be copied from the Contract');
        Assert.areEqual(con.ShippingStreet, result.ShippingStreet, 'Shipping street should be copied from the Contract');
        Assert.isNull(result.Shipping_and_Handling__c, 'The disabled shipping sync leaves this field empty');
        Assert.areEqual(0, [SELECT COUNT() FROM OrderItem WHERE OrderId = :ord.Id],
            'Contract Orders should not auto-create Order Products');
    }

    // Verifies setContractOrderStatus forces Draft only for Orders linked to a Contract.
    @IsTest
    static void testSetContractOrderStatus() {
        Quote qt = getQuote();
        Account entity = getEntity();
        Contract con = buildContract(entity.Id, qt.Id);
        insert con;

        Order withContract = new Order(ContractId = con.Id, Status = 'Activated');
        Order withoutContract = new Order(Status = 'Activated');

        Test.startTest();
        OrderTriggerHandler_CC.setContractOrderStatus(new List<Order>{ withContract, withoutContract });
        Test.stopTest();

        Assert.areEqual('Draft', withContract.Status, 'Contract Order should be reset to Draft');
        Assert.areEqual('Activated', withoutContract.Status, 'Non-contract Order status should be untouched');
    }

    // ------------------------------------------------------------------ insert from Opportunity

    // Verifies an Order created from a BAU Opportunity copies the Entity billing and primary Site
    // shipping addresses, the ship-to customer, and rolls Order totals up to the BAU Opportunity.
    @IsTest
    static void testInsertFromBauOpportunityAndRollUpAmounts() {
        Opportunity bauOpp = getBauOpp();
        Account entity = getEntity();
        PricebookEntry pbe = getPricebookEntry();

        Order ord = buildOpportunityOrder(entity.Id, bauOpp.Id);
        insert ord;
        insert new OrderItem(OrderId = ord.Id, PricebookEntryId = pbe.Id, Quantity = 2, UnitPrice = pbe.UnitPrice);

        Test.startTest();
        update new Order(Id = ord.Id, Shipping_and_Handling__c = 10);
        Test.stopTest();

        Order result = [SELECT BillingStreet, BillingCity, ShippingStreet, ShippingCity, Ship_to_Customer_No_CC__c, TotalAmount
                        FROM Order WHERE Id = :ord.Id WITH SYSTEM_MODE];
        Assert.areEqual('123 Test Street', result.BillingStreet, 'Billing street should come from the Entity');
        Assert.areEqual('Test City', result.BillingCity, 'Billing city should come from the Entity');
        Assert.areEqual('456 Site Street', result.ShippingStreet, 'Shipping street should come from the primary Site');
        Assert.areEqual('Site City', result.ShippingCity, 'Shipping city should come from the primary Site');
        Assert.isNotNull(bauOpp.Ship_To_Site_CC__c, 'Setup should give the BAU Opportunity a ship-to site');
        Assert.areEqual(bauOpp.Ship_To_Site_CC__c, result.Ship_to_Customer_No_CC__c, 'Ship-to customer should be the Opportunity ship-to site');

        Opportunity opp = getBauOpp();
        Decimal[] totals = orderTotals(bauOpp.Id);
        Assert.isTrue(totals[0] > 0, 'Order should have a positive total after adding a product');
        Assert.areEqual(totals[0], opp.BAU_Amount_Without_Freight_CC__c, 'BAU amount without freight should equal the Order total');
        Assert.areEqual(totals[1], opp.BAU_Amount_With_Freight_CC__c, 'BAU amount with freight should equal the Order grand total');
        Assert.isTrue(opp.BAU_Amount_With_Freight_CC__c > opp.BAU_Amount_Without_Freight_CC__c, 'Amount with freight should exceed the amount without freight once shipping is set');
    }

    // Returns {SUM(TotalAmount), SUM(Grand_Total__c)} of the Orders on an Opportunity (nulls as zero).
    private static Decimal[] orderTotals(Id opportunityId) {
        AggregateResult ar = [SELECT SUM(TotalAmount) total, SUM(Grand_Total__c) grand FROM Order
                              WHERE OpportunityId = :opportunityId WITH SYSTEM_MODE];
        Decimal total = (Decimal) ar.get('total');
        Decimal grand = (Decimal) ar.get('grand');
        return new Decimal[]{ total == null ? 0 : total, grand == null ? 0 : grand };
    }

    // Verifies deleting and undeleting an Order recalculates the BAU Opportunity amounts.
    @IsTest
    static void testDeleteAndUndeleteRecalculatesBauAmounts() {
        Opportunity bauOpp = getBauOpp();
        Account entity = getEntity();
        PricebookEntry pbe = getPricebookEntry();
        Order ord = buildOpportunityOrder(entity.Id, bauOpp.Id);
        ord.Shipping_and_Handling__c = 5;
        insert ord;
        insert new OrderItem(OrderId = ord.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = pbe.UnitPrice);
        update new Order(Id = ord.Id, Shipping_and_Handling__c = 5);
        Decimal[] totals = orderTotals(bauOpp.Id);
        Assert.isTrue(totals[0] > 0, 'Order should have a positive total');
        Assert.areEqual(totals[0], getBauOpp().BAU_Amount_Without_Freight_CC__c, 'Amount should be rolled up before delete');

        Test.startTest();
        delete new Order(Id = ord.Id);
        Opportunity afterDelete = getBauOpp();
        undelete new Order(Id = ord.Id);
        Test.stopTest();

        Assert.areEqual(0, afterDelete.BAU_Amount_Without_Freight_CC__c, 'Amount without freight should be zero after delete');
        Assert.areEqual(0, afterDelete.BAU_Amount_With_Freight_CC__c, 'Amount with freight should be zero after delete');
        Opportunity afterUndelete = getBauOpp();
        Assert.areEqual(totals[0], afterUndelete.BAU_Amount_Without_Freight_CC__c, 'Amount should be restored after undelete');
        Assert.areEqual(totals[1], afterUndelete.BAU_Amount_With_Freight_CC__c, 'Amount with freight should be restored after undelete');
    }

    // Verifies an Opportunity Order without a primary Site can be created while that check is disabled.
    @IsTest
    static void testOpportunityOrderWithoutPrimarySiteFails() {
        Account entity = getEntity();
        Opportunity opp = TestDataFactory_CC.createOpportunity(entity.Id, 'BAU', true);

        Test.startTest();
        Database.SaveResult sr = Database.insert(buildOpportunityOrder(entity.Id, opp.Id), false);
        Test.stopTest();

        Assert.isTrue(sr.isSuccess(), 'The primary Site requirement is disabled: ' + sr.getErrors());
    }

    // Verifies a BAU Opportunity Order is rejected when the Entity has no billing address.
    @IsTest
    static void testBauOrderWithoutBillingAddressFails() {
        Opportunity opp = [SELECT Id, AccountId FROM Opportunity WHERE Name = 'No Billing Opp' LIMIT 1];
        Account entity = new Account(Id = opp.AccountId, BillingStreet = null, BillingCity = null,
            BillingStateCode = null, BillingPostalCode = null, BillingCountryCode = null);
        update entity;
        entity = [SELECT Id, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry
                  FROM Account WHERE Id = :opp.AccountId];
        Assert.isTrue(String.isBlank(entity.BillingStreet) && String.isBlank(entity.BillingCity) &&
            String.isBlank(entity.BillingState) && String.isBlank(entity.BillingPostalCode) &&
            String.isBlank(entity.BillingCountry), 'The fixture must have no billing address');

        Test.startTest();
        Database.SaveResult sr = Database.insert(buildOpportunityOrder(entity.Id, opp.Id), false);
        Test.stopTest();

        Assert.isFalse(sr.isSuccess(), 'Order without an Entity billing address should fail');
        Assert.isTrue(sr.getErrors()[0].getMessage().contains('Please add Billing Address to the Entity'),
            'Unexpected error: ' + sr.getErrors()[0].getMessage());
    }

    // Verifies an Order can use a Site without shipping address while that check is disabled.
    @IsTest
    static void testBauOrderWithoutShippingAddressFails() {
        Account entity = getEntity();
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'No Shipping Opp' LIMIT 1];

        Test.startTest();
        Database.SaveResult sr = Database.insert(buildOpportunityOrder(entity.Id, opp.Id), false);
        Test.stopTest();

        Assert.isTrue(sr.isSuccess(), 'The Site shipping address requirement is disabled: ' + sr.getErrors());
    }

    // Verifies 200 Orders on a BAU Opportunity insert in bulk with addresses and customer numbers populated.
    @IsTest
    static void testBulkInsertFromBauOpportunity() {
        Opportunity bauOpp = getBauOpp();
        Account entity = getEntity();
        List<Order> orders = new List<Order>();
        for (Integer i = 0; i < 200; i++) {
            Order ord = buildOpportunityOrder(entity.Id, bauOpp.Id);
            ord.Shipping_and_Handling__c = 1;
            orders.add(ord);
        }

        Test.startTest();
        insert orders;
        Test.stopTest();

        List<Order> results = [SELECT BillingStreet, ShippingStreet, Bill_to_Customer_No_CC__c, Customer_Price_Group_CC__c,
                                      Shipping_and_Handling__c
                               FROM Order WHERE OpportunityId = :bauOpp.Id WITH SYSTEM_MODE];
        Assert.areEqual(200, results.size(), 'All 200 Orders should be inserted');
        for (Order ord : results) {
            Assert.areEqual('123 Test Street', ord.BillingStreet, 'Billing street should be synced in bulk');
            Assert.areEqual('456 Site Street', ord.ShippingStreet, 'Shipping street should be synced in bulk');
            Assert.areEqual(entity.Id, ord.Bill_to_Customer_No_CC__c, 'Bill-to customer should be synced in bulk');
            Assert.isNull(ord.Customer_Price_Group_CC__c, 'The disabled price group sync leaves this field empty');
            Assert.areEqual(1, ord.Shipping_and_Handling__c, 'Entered shipping is retained when the sync is disabled');
        }
        Assert.areEqual(0, getBauOpp().BAU_Amount_Without_Freight_CC__c, 'Orders without products roll up to zero');
    }

    // ------------------------------------------------------------------ activation and publishing

    // Verifies activating an Order enqueues the Business Central create callout.
    @IsTest
    static void testActivationPublishesToBusinessCentral() {
        Order ord = buildQuoteOrder(getEntity().Id, getQuote().Id);
        insert ord;
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{"status":"ok"}'));

        Test.startTest();
        update new Order(Id = ord.Id, Status = 'Activated');
        Test.stopTest();

        Assert.areEqual('Activated', [SELECT Status FROM Order WHERE Id = :ord.Id].Status, 'Order should be activated');
        Assert.isTrue(calloutJobCount() >= 1, 'A Business Central callout job should be enqueued on activation');
    }

    // Verifies a second Order on the same Quote cannot be activated once one is already Activated.
    @IsTest
    static void testSecondActivationOnSameQuoteBlocked() {
        Quote qt = getQuote();
        Account entity = getEntity();
        Order first = buildQuoteOrder(entity.Id, qt.Id);
        Order second = buildQuoteOrder(entity.Id, qt.Id);
        insert new List<Order>{ first, second };
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{"status":"ok"}'));

        Test.startTest();
        update new Order(Id = first.Id, Status = 'Activated');
        Test.stopTest();
        // Attempted after the callout job has run: a failed partial-save DML leaves the
        // transaction unable to perform the queued callout.
        Database.SaveResult sr = Database.update(new Order(Id = second.Id, Status = 'Activated'), false);

        Assert.isFalse(sr.isSuccess(), 'Second activation for the same Quote should fail');
        Assert.isTrue(sr.getErrors()[0].getMessage().contains('Another Order for the same Quote is already Activated.'),
            'Unexpected error: ' + sr.getErrors()[0].getMessage());
    }

    // Verifies two Orders on the same Quote cannot be activated in the same transaction.
    @IsTest
    static void testSimultaneousActivationOnSameQuoteBlocked() {
        Quote qt = getQuote();
        Account entity = getEntity();
        Order first = buildQuoteOrder(entity.Id, qt.Id);
        Order second = buildQuoteOrder(entity.Id, qt.Id);
        insert new List<Order>{ first, second };
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{"status":"ok"}'));

        Test.startTest();
        List<Database.SaveResult> results = Database.update(new List<Order>{
            new Order(Id = first.Id, Status = 'Activated'),
            new Order(Id = second.Id, Status = 'Activated')
        }, false);
        Test.stopTest();

        for (Database.SaveResult sr : results) {
            Assert.isFalse(sr.isSuccess(), 'Neither Order should be activated');
            Assert.isTrue(sr.getErrors()[0].getMessage().contains('Only one Order related to the same Quote can be Activated.'),
                'Unexpected error: ' + sr.getErrors()[0].getMessage());
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Order WHERE QuoteId = :qt.Id AND Status = 'Activated'],
            'No Order should be activated');
    }

    // Verifies populating the Business Central External Id publishes the Order Products (create)
    // and the changed Order fields (update).
    @IsTest
    static void testExternalIdSyncPublishesItemsAndUpdates() {
        Order ord = buildQuoteOrder(getEntity().Id, getQuote().Id);
        insert ord;
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{"status":"ok"}'));

        Test.startTest();
        update new Order(Id = ord.Id, External_Id_CC__c = 'BC-ORD-001');
        Integer queuedJobs = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(2, queuedJobs, 'Order Product create and Order update callouts should both be enqueued');
        Assert.isTrue(calloutJobCount() >= 2, 'Both callout jobs should be recorded');
    }

    // Verifies publishOrderUpdatesToBusinessCentral skips Orders without an External Id or without an old version.
    @IsTest
    static void testPublishOrderUpdatesSkipsUnsyncedOrders() {
        Order ord = buildQuoteOrder(getEntity().Id, getQuote().Id);
        insert ord;
        Order newVersion = new Order(Id = ord.Id, BillingCity = 'New City');
        Order oldVersion = new Order(Id = ord.Id, BillingCity = 'Old City');

        Test.startTest();
        OrderTriggerHandler_CC.publishOrderUpdatesToBusinessCentral(new List<Order>{ newVersion }, new Map<Id, Order>());
        OrderTriggerHandler_CC.publishOrderUpdatesToBusinessCentral(new List<Order>{ newVersion }, new Map<Id, Order>{ ord.Id => oldVersion });
        Integer queuedJobs = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(0, queuedJobs, 'No callout should be enqueued for Orders that are not synced to Business Central');
    }

    // Verifies the Integration User does not re-publish Orders to Business Central.
    @IsTest
    static void testIntegrationUserSkipsPublishing() {
        Order ord = buildQuoteOrder(getEntity().Id, getQuote().Id);
        insert ord;
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = TestDataFactory_CC.uniqueSuffix();
        User integrationUser = new User(FirstName = 'Integration', LastName = 'User', Alias = 'intusr',
            Email = 'intuser' + suffix + '@carltontest.invalid', Username = 'intuser' + suffix + '@carltontest.invalid',
            ProfileId = adminProfile.Id, TimeZoneSidKey = 'Europe/London', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        insert integrationUser;

        Order newVersion = new Order(Id = ord.Id, Status = 'Activated', External_Id_CC__c = 'BC-1', BillingCity = 'X');
        Order oldVersion = new Order(Id = ord.Id, Status = 'Draft', External_Id_CC__c = 'BC-1', BillingCity = 'Y');
        Integer queuedJobs;

        Test.startTest();
        System.runAs(integrationUser) {
            OrderTriggerHandler_CC.publishActivatedOrdersToBusinessCentral(new List<Order>{ newVersion }, new Map<Id, Order>{ ord.Id => oldVersion });
            OrderTriggerHandler_CC.publishOrderUpdatesToBusinessCentral(new List<Order>{ newVersion }, new Map<Id, Order>{ ord.Id => oldVersion });
            queuedJobs = Limits.getQueueableJobs();
        }
        Test.stopTest();

        Assert.areEqual(0, queuedJobs, 'The Integration User should not trigger Business Central callouts');
    }

    // ------------------------------------------------------------------ activated Order edit validation

    // Verifies non-admin users cannot change commercial fields on an Activated Order, while address
    // fields remain editable and Draft Orders are not restricted.
    @IsTest
    static void testValidateActivatedOrderUpdateAsNonAdmin() {
        Order ord = buildQuoteOrder(getEntity().Id, getQuote().Id);
        insert ord;
        User nonAdminUser = TestDataFactory_CC.createUser(NON_ADMIN_PROFILE, 'ordsales', true);
        // The validation only checks fields the running user can edit; grant the custom field used below so
        // the test does not depend on the profile's field-level security in each org.
        grantFieldEdit(nonAdminUser.Id, new List<String>{ 'Order.Shipping_and_Handling__c' });

        Order oldActivated = new Order(Id = ord.Id, Status = 'Activated', Description = 'Old', BillingCity = 'Old City',
                                       Shipping_and_Handling__c = 5);
        Order textChange = new Order(Id = ord.Id, Status = 'Activated', Description = 'New', BillingCity = 'Old City',
                                     Shipping_and_Handling__c = 5);
        Order numberChange = new Order(Id = ord.Id, Status = 'Activated', Description = 'Old', BillingCity = 'Old City',
                                       Shipping_and_Handling__c = 6);
        Order clearedValue = new Order(Id = ord.Id, Status = 'Activated', BillingCity = 'Old City', Shipping_and_Handling__c = 5);
        Order addressChange = new Order(Id = ord.Id, Status = 'Activated', Description = 'Old', BillingCity = 'New City',
                                        Shipping_and_Handling__c = 5);
        Order draftChange = new Order(Id = ord.Id, Status = 'Draft', Description = 'Changed');
        Order oldDraft = new Order(Id = ord.Id, Status = 'Draft', Description = 'Original');

        Test.startTest();
        System.runAs(nonAdminUser) {
            OrderTriggerHandler_CC.validateActivatedOrderUpdate(new List<Order>{ textChange }, new Map<Id, Order>{ ord.Id => oldActivated });
            OrderTriggerHandler_CC.validateActivatedOrderUpdate(new List<Order>{ numberChange }, new Map<Id, Order>{ ord.Id => oldActivated });
            OrderTriggerHandler_CC.validateActivatedOrderUpdate(new List<Order>{ clearedValue }, new Map<Id, Order>{ ord.Id => oldActivated });
            OrderTriggerHandler_CC.validateActivatedOrderUpdate(new List<Order>{ addressChange }, new Map<Id, Order>{ ord.Id => oldActivated });
            OrderTriggerHandler_CC.validateActivatedOrderUpdate(new List<Order>{ draftChange }, new Map<Id, Order>{ ord.Id => oldDraft });
        }
        Test.stopTest();

        Assert.isTrue(textChange.hasErrors(), 'Text field change on an Activated Order should be blocked');
        Assert.areEqual('Commercial Changes are not allowed on Activated Order.', textChange.getErrors()[0].getMessage(),
            'Unexpected error message');
        Assert.isTrue(numberChange.hasErrors(), 'Numeric field change on an Activated Order should be blocked');
        Assert.isTrue(clearedValue.hasErrors(), 'Clearing a field on an Activated Order should be blocked');
        Assert.isFalse(addressChange.hasErrors(), 'Address fields are allowed to change on an Activated Order');
        Assert.isFalse(draftChange.hasErrors(), 'Draft Orders are not restricted');
    }

    // Grants edit access on the given fields ('Object.Field') through a test-only permission set. Runs as the
    // current user so the setup-object DML does not mix with the Order DML of the test.
    private static void grantFieldEdit(Id userId, List<String> qualifiedFields) {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet permissionSet = new PermissionSet(Name = 'Order_Test_Field_Edit', Label = 'Order Test Field Edit');
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

    // Verifies System Administrators may edit an Activated Order through the trigger.
    @IsTest
    static void testAdminCanEditActivatedOrder() {
        Order ord = buildQuoteOrder(getEntity().Id, getQuote().Id);
        insert ord;
        Test.setMock(HttpCalloutMock.class, new TestDataFactory_CC.HttpMock(200, '{"status":"ok"}'));

        Test.startTest();
        update new Order(Id = ord.Id, Status = 'Activated');
        Database.SaveResult sr = Database.update(new Order(Id = ord.Id, Description = 'Admin edit'), false);
        Test.stopTest();

        Assert.isTrue(sr.isSuccess(), 'Admin should be able to edit an Activated Order: ' + sr.getErrors());
        Assert.areEqual('Admin edit', [SELECT Description FROM Order WHERE Id = :ord.Id].Description,
            'Description should be updated');
    }
}