@IsTest
private class OrderActivationBatch_CCTest {

    private class BusinessCentralMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{}');
            return response;
        }
    }

    @TestSetup
    static void setup() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User integrationUser = new User(
            FirstName = 'Integration',
            LastName = 'User',
            Alias = 'intusr',
            Email = 'order.activation@example.com',
            Username = 'order.activation.' + UserInfo.getOrganizationId() + '@example.com.test',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_GB',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert integrationUser;

        System.runAs(integrationUser) {
            // Order.AccountId has a lookup filter allowing Customer Accounts only
            insert new Account(Name = 'Order Activation Account', Type = 'Customer');
            Product2 product = new Product2(Name = 'Order Activation Product', ProductCode = 'OA-001', IsActive = true);
            insert product;
            insert new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = product.Id, UnitPrice = 10, IsActive = true);
        }
    }

    private static User integrationUser() {
        return [SELECT Id FROM User WHERE Email = 'order.activation@example.com' LIMIT 1];
    }

    // Creates Draft Orders as the running user; aged Orders are back-dated past the minimum age
    private static List<Order> createOrders(Integer count, Boolean withProduct, Boolean isAged) {
        Id accountId = [SELECT Id FROM Account LIMIT 1].Id;
        PricebookEntry entry = Database.query('SELECT Id, CurrencyIsoCode FROM PricebookEntry WHERE Pricebook2Id = \'' + Test.getStandardPricebookId() + '\' LIMIT 1');

        List<Order> orders = new List<Order>();
        for (Integer i = 0; i < count; i++) {
            Order ord = new Order(AccountId = accountId, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId());
            // The org is multi-currency, so the Order must use the same currency as the price book entry
            ord.put('CurrencyIsoCode', entry.get('CurrencyIsoCode'));
            orders.add(ord);
        }
        insert orders;

        if (withProduct) {
            List<OrderItem> items = new List<OrderItem>();
            for (Order ord : orders) {
                items.add(new OrderItem(OrderId = ord.Id, PricebookEntryId = entry.Id, Quantity = 1, UnitPrice = 10));
            }
            insert items;
        }
        if (isAged) {
            for (Order ord : orders) {
                Test.setCreatedDate(ord.Id, Datetime.now().addHours(-1));
            }
        }
        return orders;
    }

    private static List<Order> createIntegrationOrders(Integer count, Boolean withProduct, Boolean isAged) {
        List<Order> orders;
        System.runAs(integrationUser()) {
            orders = createOrders(count, withProduct, isAged);
        }
        return orders;
    }

    private static Map<Id, Order> reload(List<Order> orders) {
        return new Map<Id, Order>([SELECT Id, Status FROM Order WHERE Id IN :new Map<Id, Order>(orders).keySet()]);
    }

    private static Integer batchJobCount() {
        return [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex' AND ApexClass.Name = 'OrderActivationBatch_CC'];
    }

    private static void runBatch() {
        Test.startTest();
        Database.executeBatch(new OrderActivationBatch_CC(), 50);
        Test.stopTest();
    }

    @IsTest
    static void activatesEligibleOrder() {
        List<Order> orders = createIntegrationOrders(1, true, true);
        Test.setMock(HttpCalloutMock.class, new BusinessCentralMock());

        runBatch();

        Assert.areEqual('Activated', reload(orders).get(orders[0].Id).Status, 'Eligible Order should be activated');
    }

    @IsTest
    static void activatesMultipleOrdersTogether() {
        List<Order> orders = createIntegrationOrders(5, true, true);
        Test.setMock(HttpCalloutMock.class, new BusinessCentralMock());

        runBatch();

        for (Order result : reload(orders).values()) {
            Assert.areEqual('Activated', result.Status, 'Every eligible Order should be activated');
        }
    }

    @IsTest
    static void ignoresOrdersCreatedByOtherUsers() {
        List<Order> orders = createOrders(1, true, true);

        runBatch();

        Assert.areEqual('Draft', reload(orders).get(orders[0].Id).Status, 'Orders created by other users must not be activated');
    }

    @IsTest
    static void ignoresAlreadyActivatedOrders() {
        List<Order> orders = createIntegrationOrders(1, true, true);
        System.runAs(integrationUser()) {
            update new Order(Id = orders[0].Id, Status = 'Activated');
        }

        Test.startTest();
        Boolean hasEligibleOrders = OrderActivationBatch_CC.hasEligibleOrders();
        Test.stopTest();

        Assert.isFalse(hasEligibleOrders, 'Activated Orders must not be picked up');
        Assert.areEqual('Activated', reload(orders).get(orders[0].Id).Status, 'Activated Order should stay Activated');
    }

    @IsTest
    static void skipsOrdersWithoutProductsOrStillLoading() {
        createIntegrationOrders(1, false, true);
        createIntegrationOrders(1, true, false);

        Test.startTest();
        Boolean hasEligibleOrders = OrderActivationBatch_CC.hasEligibleOrders();
        Test.stopTest();

        Assert.isFalse(hasEligibleOrders, 'Orders without products, or younger than the minimum age, are not eligible');
    }

    @IsTest
    static void submitsNoJobWhenNoEligibleOrders() {
        Test.startTest();
        Id jobId = OrderActivationBatch_CC.run();
        Test.stopTest();

        Assert.isNull(jobId, 'No batch should be submitted without eligible Orders');
        Assert.areEqual(0, batchJobCount(), 'No batch job expected');
    }

    @IsTest
    static void partialFailureDoesNotBlockOtherOrders() {
        List<Order> orders = createIntegrationOrders(2, true, true);
        delete new Order(Id = orders[1].Id);
        Test.setMock(HttpCalloutMock.class, new BusinessCentralMock());

        Test.startTest();
        OrderActivationBatch_CC.activateOrders(orders);
        Test.stopTest();

        Assert.areEqual('Activated', [SELECT Status FROM Order WHERE Id = :orders[0].Id].Status, 'The valid Order should still be activated');
    }

    @IsTest
    static void failedOrderStaysDraftForRetry() {
        List<Order> orders = createIntegrationOrders(1, true, true);
        // An invalid status value makes the activation update fail
        OrderActivationBatch_CC.targetStatus = 'Not_A_Valid_Status';

        runBatch();

        Assert.areEqual('Draft', reload(orders).get(orders[0].Id).Status, 'Failed Order should stay in Draft');
        Assert.isTrue(OrderActivationBatch_CC.hasEligibleOrders(), 'Failed Order should be picked up again on the next run');
    }

    @IsTest
    static void scheduledRunSubmitsBatch() {
        createIntegrationOrders(1, true, true);
        Test.setMock(HttpCalloutMock.class, new BusinessCentralMock());

        Test.startTest();
        System.schedule('Order Activation Test Run', '0 0 * * * ?', new OrderActivationBatch_CC());
        Test.stopTest();

        Assert.areEqual(1, batchJobCount(), 'The scheduled run should submit one batch');
    }

    @IsTest
    static void preventsDuplicateBatchJobs() {
        createIntegrationOrders(1, true, true);
        Test.setMock(HttpCalloutMock.class, new BusinessCentralMock());

        Test.startTest();
        Database.executeBatch(new OrderActivationBatch_CC(), 50);
        Id secondJobId = OrderActivationBatch_CC.run();
        Test.stopTest();

        Assert.isNull(secondJobId, 'A second batch must not be submitted while one is queued or running');
        Assert.areEqual(1, batchJobCount(), 'Only one batch job expected');
    }

    @IsTest
    static void refusesToRunAsIntegrationUser() {
        createIntegrationOrders(1, true, true);

        Id jobId;
        Test.startTest();
        System.runAs(integrationUser()) {
            jobId = OrderActivationBatch_CC.run();
        }
        Test.stopTest();

        Assert.isNull(jobId, 'The batch must not run as the Integration User, as BC sync would be skipped');
    }
}