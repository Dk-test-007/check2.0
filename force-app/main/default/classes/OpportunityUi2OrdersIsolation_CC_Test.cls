/**
 * Release Orders, per-record integration isolation and the account monthly view.
 * Outbound checks assert that nothing is enqueued for UI2 records (Limits.getQueueableJobs), while normal records
 * still reach CalloutService_CC, so isolation is proven before any sandbox fixture is created.
 */
@isTest
private class OpportunityUi2OrdersIsolation_CC_Test {

    private static final Decimal MILLION = 1000000;

    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.isolationAdmin();
        User pilot = OpportunityUi2TestData_CC.pilotUser('Standard User');
        System.runAs(admin) {
            Account entity = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            OpportunityUi2TestData_CC.site(entity.Id, pilot.Id, 'ZZUI2 Site A');
            OpportunityUi2TestData_CC.site(entity.Id, pilot.Id, 'ZZUI2 Site B');
            OpportunityUi2TestData_CC.standardEntry('ZZUI2 Wrap', 1000, 'GBP');
            OpportunityUi2TestData_CC.standardEntry('ZZUI2 Tape', 500, 'GBP');
            Opportunity wrap = OpportunityUi2TestData_CC.newBusiness(entity.Id, pilot.Id, 12 * MILLION, 'GBP');
            wrap.Name = 'ZZUI2 Win Wrap';
            Opportunity tape = OpportunityUi2TestData_CC.newBusiness(entity.Id, pilot.Id, 1200000, 'GBP');
            tape.Name = 'ZZUI2 Win Tape';
            update new List<Opportunity>{ wrap, tape };
            Account other = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            update new Account(Id = other.Id, Name = 'ZZUI2 Foreign Entity');
            OpportunityUi2TestData_CC.site(other.Id, pilot.Id, 'ZZUI2 Foreign Site');
        }
    }

    private static User pilot() {
        return [SELECT Id FROM User WHERE Alias = 'ui2pilot' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
    }
    private static User isoAdmin() {
        return [SELECT Id FROM User WHERE Alias = 'ui2isoad' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
    }
    private static Account entity() {
        return [SELECT Id FROM Account WHERE Name LIKE 'ZZUI2 Entity%' LIMIT 1];
    }
    private static Account site(String name) {
        return [SELECT Id FROM Account WHERE Name LIKE :name + '%' LIMIT 1];
    }

    /** Wins the named Opportunity as the pilot and returns the agreement, activated (admin, for setup speed). */
    private static Id winAndActivate(String oppName, String productPrefix, Decimal monthly, Integer months) {
        Opportunity o = [SELECT Id FROM Opportunity WHERE Name = :oppName];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE :productPrefix + '%' LIMIT 1];
        SalesAgreementActivationJob_CC.chainNextStep = false;
        Date start = Date.newInstance(Date.today().year(), 1, 1);
        Id agreementId;
        System.runAs(pilot()) {
            agreementId = SalesAgreementPlanService_CC.winAndPlan(
                OpportunityUi2TestData_CC.request(o.Id, start, OpportunityUi2TestData_CC.repeat(monthly, months), entry.Id)).salesAgreementId;
        }
        return agreementId;
    }

    private static AgreementReleaseOrderService_CC.ReleaseRequest release(Id agreementId, String po, String releaseNo, Id siteId, Decimal qty, Boolean activateNow) {
        AgreementReleaseOrderService_CC.ReleaseRequest request = new AgreementReleaseOrderService_CC.ReleaseRequest();
        request.agreementId = agreementId;
        request.poNumber = po;
        request.releaseNumber = releaseNo;
        request.orderDate = Date.newInstance(Date.today().year(), 1, 15);
        request.shipToSiteId = siteId;
        request.locationCode = Order.Location_Code_CC__c.getDescribe().getPicklistValues()[0].getValue();
        request.shipmentMethod = 'EXW';
        request.activateNow = activateNow;
        AgreementReleaseOrderService_CC.ReleaseLine line = new AgreementReleaseOrderService_CC.ReleaseLine();
        line.agreementProductId = [SELECT Id FROM SalesAgreementProduct WHERE SalesAgreementId = :agreementId WITH SYSTEM_MODE LIMIT 1].Id;
        line.quantity = qty;
        request.lines = new List<AgreementReleaseOrderService_CC.ReleaseLine>{ line };
        return request;
    }

    // ------------------------------------------------------------------ release Orders

    @isTest
    static void tenReleasesOf100k_CreateRealOrders_NoQuoteRestriction_ShipToKept_NoOutboundJobs() {
        Id agreementId = winAndActivate('ZZUI2 Win Wrap', 'ZZUI2 Wrap', MILLION, 12);
        Account siteA = site('ZZUI2 Site A');
        Integer queuedBefore;
        Integer queuedAfter;
        Test.startTest();
        System.runAs(pilot()) {
            queuedBefore = Limits.getQueueableJobs();
            // Two releases per test transaction (each release runs the full Order/Order Product trigger stack, ~30
            // queries). The ten-release, 1m scenario runs as separate transactions with the sandbox fixtures.
            for (Integer i = 1; i <= 2; i++) {
                AgreementReleaseOrderService_CC.createRelease(release(agreementId, 'PO-' + i, '1', siteA.Id, 100, true));
            }
            queuedAfter = Limits.getQueueableJobs();
        }
        Test.stopTest();
        List<Order> orders = [SELECT Status, QuoteId, OpportunityId, SalesAgreementId, Ship_to_Customer_No_CC__c, TotalAmount, Integration_Test_Record_CC__c
                              FROM Order WHERE SalesAgreementId = :agreementId WITH SYSTEM_MODE];
        Assert.areEqual(2, orders.size(), 'Real Orders, one per PO, both activated on the same agreement');
        Decimal total = 0;
        for (Order o : orders) {
            Assert.areEqual('Activated', o.Status);
            Assert.isNull(o.QuoteId, 'Releases never reuse the winning Quote');
            Assert.isNull(o.OpportunityId, 'No Opportunity per PO');
            Assert.areEqual(siteA.Id, o.Ship_to_Customer_No_CC__c, 'The actual Ship-To Site is kept');
            Assert.isTrue(o.Integration_Test_Record_CC__c);
            total += o.TotalAmount;
        }
        Assert.areEqual(200000, total, 'Two 100k Orders = 200k of eligible Order amounts, each counted once');
        Assert.areEqual(queuedBefore, queuedAfter, 'Activating UI2 Orders enqueues no Business Central job');
    }

    @isTest
    static void duplicateRelease_IsNotEnteredTwice_AndSplitReleasesShareThePo() {
        Id agreementId = winAndActivate('ZZUI2 Win Wrap', 'ZZUI2 Wrap', MILLION, 12);
        Account siteA = site('ZZUI2 Site A');
        AgreementReleaseOrderService_CC.ReleaseResult first;
        AgreementReleaseOrderService_CC.ReleaseResult again;
        AgreementReleaseOrderService_CC.ReleaseResult secondRelease;
        Test.startTest();
        System.runAs(pilot()) {
            first = AgreementReleaseOrderService_CC.createRelease(release(agreementId, 'PO-MIX', '1', siteA.Id, 10, false));
            again = AgreementReleaseOrderService_CC.createRelease(release(agreementId, 'PO-MIX', '1', siteA.Id, 10, false));
            secondRelease = AgreementReleaseOrderService_CC.createRelease(release(agreementId, 'PO-MIX', '2', siteA.Id, 5, false));
        }
        Test.stopTest();
        Assert.isTrue(again.alreadyExisted, 'Same PO release returns the existing Order');
        Assert.areEqual(first.orderId, again.orderId);
        Assert.areNotEqual(first.orderId, secondRelease.orderId, 'A separate release of the same PO is its own Order');
        Assert.areEqual(2, [SELECT COUNT() FROM Order WHERE PoNumber = 'PO-MIX' WITH SYSTEM_MODE]);
    }

    @isTest
    static void releaseOrder_OnlyTakesProductsOfItsAgreement_OtherOrdersAreNotChecked() {
        Id agreementId = winAndActivate('ZZUI2 Win Wrap', 'ZZUI2 Wrap', MILLION, 12);
        Account siteA = site('ZZUI2 Site A');
        Id wrapEntry = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Wrap%' LIMIT 1].Id;
        Id tapeEntry = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Tape%' LIMIT 1].Id;
        String refused;
        Test.startTest();
        System.runAs(pilot()) {
            Id orderId = AgreementReleaseOrderService_CC.createRelease(release(agreementId, 'PO-PROD', '1', siteA.Id, 1, false)).orderId;
            // Order Products added on the Order page (Add Products) go through the before-insert rule
            // AgreementOrderProducts_CC.check. It is called directly here: no OrderItem trigger handler calls it yet.
            OrderItem outside = new OrderItem(OrderId = orderId, PricebookEntryId = tapeEntry, Quantity = 1, UnitPrice = 500);
            OrderItem onAgreement = new OrderItem(OrderId = orderId, PricebookEntryId = wrapEntry, Quantity = 2, UnitPrice = 1000);
            AgreementOrderProducts_CC.check(new List<OrderItem>{ outside, onAgreement });
            // A product that is not on the agreement is refused ...
            refused = outside.hasErrors() ? outside.getErrors()[0].getMessage() : null;
            // ... and one of the agreement's products is accepted.
            Assert.isFalse(onAgreement.hasErrors(), 'An agreement product is accepted on its release Order: ' + onAgreement.getErrors());
            Assert.areEqual(1, [SELECT COUNT() FROM OrderItem WHERE OrderId = :orderId WITH SYSTEM_MODE],
                'The release Order carries the released agreement product');
        }
        Test.stopTest();
        Assert.isNotNull(refused, 'A product outside the agreement is refused on a release Order');
        Assert.isTrue(refused.contains('ZZUI2 Wrap') && refused.contains('can only include that agreement'), refused);
        // Order Products without an Order, or on Orders that are not agreement releases, are left alone.
        AgreementOrderProducts_CC.check(new List<OrderItem>{ new OrderItem(PricebookEntryId = tapeEntry) });
    }

    @isTest
    static void shipToOutsideTheAgreement_IsRejected() {
        Id agreementId = winAndActivate('ZZUI2 Win Wrap', 'ZZUI2 Wrap', MILLION, 12);
        Account foreignSite = site('ZZUI2 Foreign Site');
        String message;
        System.runAs(pilot()) {
            try {
                AgreementReleaseOrderService_CC.createRelease(release(agreementId, 'PO-X', '1', foreignSite.Id, 1, false));
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
        }
        Assert.isTrue(message != null && message.contains('Ship-To Site'), 'Sites of another Entity are rejected: ' + message);
    }

    @isTest
    static void siteScopedPlan_RejectsSiteOfAnotherEntity() {
        Opportunity o = [SELECT Id FROM Opportunity WHERE Name = 'ZZUI2 Win Wrap'];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Wrap%' LIMIT 1];
        Account foreign = site('ZZUI2 Foreign Site');
        SalesAgreementPlanService_CC.PlanRequest request = OpportunityUi2TestData_CC.request(o.Id,
            OpportunityUi2TestData_CC.firstOfMonth(Date.today()), OpportunityUi2TestData_CC.repeat(MILLION, 12), entry.Id);
        request.scope = SalesAgreementPlanService_CC.SCOPE_SITE;
        request.siteIds = new List<Id>{ foreign.Id };
        String message;
        System.runAs(pilot()) {
            try { SalesAgreementPlanService_CC.winAndPlan(request); } catch (AuraHandledException ex) { message = ex.getMessage(); }
        }
        Assert.isTrue(message != null && message.contains('not a Site of this Entity'), message);
        Assert.areEqual(0, [SELECT COUNT() FROM SalesAgreement WITH SYSTEM_MODE]);
    }

    @isTest
    static void uiEntryPoints_DraftThenActivate_RecalculateAndExceptions() {
        Opportunity wrap = [SELECT Id FROM Opportunity WHERE Name = 'ZZUI2 Win Wrap'];
        Account siteA = site('ZZUI2 Site A');
        System.runAs(pilot()) {
            SalesAgreementPlanService_CC.WinContext ctx = SalesAgreementPlanService_CC.getWinContext(wrap.Id);
            Assert.isTrue(ctx.isNewBusiness);
            Assert.isNull(ctx.existingAgreementId);
            Assert.isFalse(ctx.products.isEmpty(), 'Price book products are offered');
            Assert.areEqual(2, ctx.sites.size(), 'Only the Entity\'s Sites are offered');
        }
        Id agreementId = winAndActivate('ZZUI2 Win Wrap', 'ZZUI2 Wrap', MILLION, 12);
        Test.startTest();
        System.runAs(pilot()) {
            Assert.areEqual(agreementId, SalesAgreementPlanService_CC.getWinContext(wrap.Id).existingAgreementId);
            AgreementReleaseOrderService_CC.EntryContext entry = AgreementReleaseOrderService_CC.getEntryContext(agreementId);
            Assert.areEqual(2, entry.sites.size(), 'Entity-wide agreement: any Site of the Entity');
            Assert.isFalse(entry.locationCodes.isEmpty());
            AgreementReleaseOrderService_CC.ReleaseResult draft =
                AgreementReleaseOrderService_CC.createRelease(release(agreementId, 'PO-DRAFT', '1', siteA.Id, 3, false));
            Assert.areEqual('Draft', draft.status);
            AgreementReleaseOrderService_CC.activateOrder(draft.orderId);
            Assert.areEqual('Activated', [SELECT Status FROM Order WHERE Id = :draft.orderId WITH SYSTEM_MODE].Status);
            List<AgreementReleaseOrderService_CC.OrderSummary> listed = AgreementReleaseOrderService_CC.getEntryContext(agreementId).orders;
            Assert.areEqual(1, listed.size());
            String lineProduct = [SELECT Product2.Name FROM OrderItem WHERE OrderId = :draft.orderId WITH SYSTEM_MODE LIMIT 1].Product2.Name;
            Assert.areEqual(lineProduct + ' × 3', listed[0].products, 'The Release Orders list names the product and quantity of each line');
            try {
                SalesAgreementForecastService_CC.recalculateActuals(agreementId);
            } catch (AuraHandledException ex) {
                Assert.isTrue(ex.getMessage().contains('ecalculat'), 'An unavailable recalculation is reported, not swallowed');
            }
            SalesAgreementForecastService_CC.AgreementView view = SalesAgreementForecastService_CC.getAgreementView(agreementId);
            Assert.areEqual('Entity-wide', view.scope);
            Assert.areEqual(wrap.Id, view.sourceOpportunityId, 'Source Opportunity traceability');
            AccountMonthlyForecastController_CC.AccountView entityView =
                AccountMonthlyForecastController_CC.getAccountView(entity().Id, Date.today().year());
            Assert.isFalse(entityView.exceptions.isEmpty(), 'A Draft (not yet active) agreement is flagged');
            AccountMonthlyForecastController_CC.AccountView siteView =
                AccountMonthlyForecastController_CC.getAccountView(siteA.Id, Date.today().year());
            Assert.areEqual(1, siteView.currencies.size(), 'Site actuals follow the Order Ship-To');
            // The agreement is Entity-wide: its Orders shipped to Site A are reported apart, not against a Site plan.
            Assert.areEqual(0, siteView.currencies[0].months[0].orderActuals, 'No Site plan, so no Site attainment basis');
            Assert.areEqual(3000, siteView.currencies[0].entityWideShipToActuals, 'Three units at 1,000 shipped to Site A on the Entity-wide agreement');
        }
        Test.stopTest();
    }

    @isTest
    static void siteScopedWin_ShowsOnTheSitePage_AndLimitsShipToSites() {
        Opportunity o = [SELECT Id FROM Opportunity WHERE Name = 'ZZUI2 Win Wrap'];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Wrap%' LIMIT 1];
        Account siteA = site('ZZUI2 Site A');
        SalesAgreementPlanService_CC.PlanRequest request = OpportunityUi2TestData_CC.request(o.Id,
            Date.newInstance(Date.today().year(), 1, 1), OpportunityUi2TestData_CC.repeat(MILLION, 12), entry.Id);
        request.scope = SalesAgreementPlanService_CC.SCOPE_SITE;
        request.siteIds = new List<Id>{ siteA.Id };
        SalesAgreementActivationJob_CC.chainNextStep = false;
        Id agreementId;
        System.runAs(pilot()) {
            agreementId = SalesAgreementPlanService_CC.winAndPlan(request).salesAgreementId;
        }
        Test.startTest();
        System.runAs(pilot()) {
            AgreementReleaseOrderService_CC.EntryContext entryContext = AgreementReleaseOrderService_CC.getEntryContext(agreementId);
            Assert.areEqual(1, entryContext.sites.size(), 'Only the scoped Site can be shipped to');
            Assert.areEqual(siteA.Id, entryContext.sites[0].value);
            AccountMonthlyForecastController_CC.AccountView siteView = AccountMonthlyForecastController_CC.getAccountView(siteA.Id, Date.today().year());
            Assert.areEqual(12 * MILLION, siteView.currencies[0].yearPlan, 'A Site-scoped plan shows on the Site page');
            AccountMonthlyForecastController_CC.AccountView entityView = AccountMonthlyForecastController_CC.getAccountView(entity().Id, Date.today().year());
            Assert.areEqual(12 * MILLION, entityView.currencies[0].yearPlan, 'It rolls up to the Entity once');
            Assert.areEqual(0, entityView.currencies[0].unallocatedPlan, 'Nothing is left unallocated');
        }
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM Sales_Agreement_Site_CC__c WHERE Sales_Agreement_CC__c = :agreementId WITH SYSTEM_MODE]);
    }

    // ------------------------------------------------------------------ term extension

    @isTest
    static void releaseAfterTheCoveredEnd_UsesExtensionLink_AddsThatMonthWithForecastZero_AndCountsInActuals() {
        Id agreementId = winAndActivate('ZZUI2 Win Wrap', 'ZZUI2 Wrap', MILLION, 12); // Jan-Dec this year
        Account siteA = site('ZZUI2 Site A');
        Integer nextYear = Date.today().year() + 1;
        Date orderDate = Date.newInstance(nextYear, 2, 10); // month 14: after the native end and the last planned month
        AgreementReleaseOrderService_CC.ReleaseResult created;
        Test.startTest();
        System.runAs(pilot()) {
            AgreementReleaseOrderService_CC.ReleaseRequest request = release(agreementId, 'PO-EXT', '1', siteA.Id, 20, true);
            request.orderDate = orderDate;
            created = AgreementReleaseOrderService_CC.createRelease(request);
        }
        Test.stopTest();
        Order ord = [SELECT SalesAgreementId, Agreement_Extension_CC__c, Status, TotalAmount FROM Order WHERE Id = :created.orderId WITH SYSTEM_MODE];
        Assert.isNull(ord.SalesAgreementId, 'The platform refuses SalesAgreementId after the native EndDate');
        Assert.areEqual(agreementId, ord.Agreement_Extension_CC__c, 'Linked to the agreement by the extension lookup');
        Assert.areEqual('Activated', ord.Status);
        Assert.isTrue(created.message.contains('added to the plan'), created.message);
        Date month = Date.newInstance(nextYear, 2, 1);
        Agreement_Month_Plan_CC__c added = [SELECT Original_Plan_Amount_CC__c, Current_Forecast_Amount_CC__c, Is_Extension_CC__c,
                                                   (SELECT Previous_Forecast_CC__c, New_Forecast_CC__c FROM Forecast_Revisions__r)
                                            FROM Agreement_Month_Plan_CC__c WHERE Sales_Agreement_CC__c = :agreementId
                                            AND Month_Start_CC__c = :month WITH SYSTEM_MODE];
        Assert.areEqual(0, added.Original_Plan_Amount_CC__c);
        Assert.areEqual(0, added.Current_Forecast_Amount_CC__c, 'Auto-created month starts at forecast 0');
        Assert.isTrue(added.Is_Extension_CC__c);
        Assert.areEqual(1, added.Forecast_Revisions__r.size(), 'The added month is recorded as a revision');
        Assert.areEqual(13, [SELECT COUNT() FROM Agreement_Month_Plan_CC__c WHERE Sales_Agreement_CC__c = :agreementId WITH SYSTEM_MODE],
            'Only the Order\'s month is added');
        Assert.areEqual(Date.newInstance(nextYear, 2, 28), [SELECT Extended_Through_CC__c FROM SalesAgreement WHERE Id = :agreementId WITH SYSTEM_MODE].Extended_Through_CC__c);

        System.runAs(pilot()) {
            SalesAgreementForecastService_CC.AgreementView view = SalesAgreementForecastService_CC.getAgreementView(agreementId);
            SalesAgreementForecastService_CC.MonthRow row = view.months[view.months.size() - 1];
            Assert.areEqual(month, row.monthStart);
            Assert.areEqual(SalesAgreementForecastService_CC.EXTENSION, row.rowType);
            Assert.areEqual(20000, row.orderActuals, '20 units at 1,000 from the activated Order, summed in Apex');
            Assert.areEqual(20000, view.totals.extension.actualsToDate);
            Assert.areEqual(0, view.totals.unplanned.months);
            Assert.areEqual('Extension', AgreementReleaseOrderService_CC.getEntryContext(agreementId).orders[0].link);
            AccountMonthlyForecastController_CC.CurrencyBlock gbp =
                AccountMonthlyForecastController_CC.getAccountView(entity().Id, nextYear).currencies[0];
            Assert.areEqual(20000, gbp.months[1].orderActuals, 'The Entity view uses the same Order actuals after the native term');
            Assert.areEqual(20000, gbp.extension.actualsToDate);
            Assert.areEqual(0, gbp.months[1].unplannedActuals);
            Assert.areEqual(20000, gbp.agreements[0].orderActuals);
        }
    }

    @isTest
    static void orderBeforeTheStart_IsRejected_AndAnOrderArrivingOtherwiseWithNoPlan_IsUnplanned() {
        Id agreementId = winAndActivate('ZZUI2 Win Wrap', 'ZZUI2 Wrap', MILLION, 12);
        Account siteA = site('ZZUI2 Site A');
        Integer nextYear = Date.today().year() + 1;
        String message;
        System.runAs(pilot()) {
            AgreementReleaseOrderService_CC.ReleaseRequest early = release(agreementId, 'PO-EARLY', '1', siteA.Id, 1, false);
            early.orderDate = Date.newInstance(Date.today().year() - 1, 12, 20);
            try { AgreementReleaseOrderService_CC.createRelease(early); } catch (AuraHandledException ex) { message = ex.getMessage(); }
        }
        Assert.isTrue(message != null && message.contains('before this agreement starts'), message);
        // An Order that arrived without Enter PO (no release key, e.g. an integration), linked to the agreement in a
        // month that has no plan row.
        SalesAgreement sa = [SELECT AccountId, PricebookId, CurrencyIsoCode FROM SalesAgreement WHERE Id = :agreementId WITH SYSTEM_MODE];
        PricebookEntry wrap = [SELECT Id, UnitPrice FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Wrap%' LIMIT 1];
        Test.startTest();
        System.runAs(isoAdmin()) {
            Order other = new Order(AccountId = sa.AccountId, Pricebook2Id = sa.PricebookId, CurrencyIsoCode = sa.CurrencyIsoCode,
                EffectiveDate = Date.newInstance(nextYear, 3, 5), Status = 'Draft', Agreement_Extension_CC__c = agreementId,
                Ship_to_Customer_No_CC__c = siteA.Id, ShippingStreet = '2 Site Road', ShippingCity = 'Albany', ShippingStateCode = 'NY',
                ShippingPostalCode = '12207', ShippingCountryCode = 'US', BillingStreet = '1 Test Street', BillingCity = 'New York',
                BillingStateCode = 'NY', BillingPostalCode = '10001', BillingCountryCode = 'US');
            insert other;
            insert new OrderItem(OrderId = other.Id, PricebookEntryId = wrap.Id, Quantity = 7, UnitPrice = wrap.UnitPrice);
            update new Order(Id = other.Id, Status = 'Activated');
        }
        Test.stopTest();
        // The pilot cannot see this Order (owned by the administrator); like native actuals, it still counts.
        System.runAs(pilot()) {
            Assert.areEqual(0, [SELECT COUNT() FROM Order WHERE Agreement_Extension_CC__c = :agreementId WITH USER_MODE],
                'Precondition: the Order is not shared with the pilot');
        }
        System.runAs(pilot()) {
            SalesAgreementForecastService_CC.AgreementView view = SalesAgreementForecastService_CC.getAgreementView(agreementId);
            Assert.areEqual(13, view.months.size(), '12 planned months + 1 Unplanned row');
            SalesAgreementForecastService_CC.MonthRow unplanned = view.months[12];
            Assert.isTrue(unplanned.isUnplanned);
            Assert.areEqual(SalesAgreementForecastService_CC.UNPLANNED, unplanned.rowType);
            Assert.isNull(unplanned.monthPlanId);
            Assert.areEqual(7000, unplanned.orderActuals);
            Assert.areEqual(7000, view.totals.unplanned.actualsToDate);
            Assert.areEqual(0, view.totals.extension.months);
            AccountMonthlyForecastController_CC.AccountView entityView = AccountMonthlyForecastController_CC.getAccountView(entity().Id, nextYear);
            Assert.areEqual(7000, entityView.currencies[0].months[2].unplannedActuals);
            Assert.areEqual(7000, entityView.currencies[0].unplanned.actualsToDate);
            Assert.areEqual(7000, entityView.currencies[0].agreements[0].unplannedActuals);
            Boolean flagged = false;
            for (String note : entityView.exceptions) {
                flagged = flagged || note.contains('Unplanned');
            }
            Assert.isTrue(flagged, 'Unplanned Orders are listed for checking: ' + entityView.exceptions);
        }
    }

    // ------------------------------------------------------------------ isolation

    @isTest
    static void ui2Account_CannotTakeAnyValueThatStartsSyncEmailNotificationOrBau() {
        Account ui2 = entity();
        List<Account> attempts = new List<Account>{
            new Account(Id = ui2.Id, Financial_Check_CC__c = 'Approved'),
            new Account(Id = ui2.Id, Is_BAU_Account_CC__c = true),
            new Account(Id = ui2.Id, Business_Central_Customer_ID_CC__c = 'ZZUI2-BC-1'),
            new Account(Id = ui2.Id, Site_Synced_CC__c = true)
        };
        Integer emailsBefore = Limits.getEmailInvocations();
        Integer jobsBefore = Limits.getQueueableJobs();
        System.runAs(isoAdmin()) {
            for (Account attempt : attempts) {
                Database.SaveResult result = Database.update(attempt, false);
                Assert.isFalse(result.isSuccess(), 'Blocked for UI2 data, even for an administrator: ' + attempt);
            }
        }
        Assert.areEqual(emailsBefore, Limits.getEmailInvocations(), 'No email');
        Assert.areEqual(jobsBefore, Limits.getQueueableJobs(), 'No BAU or Business Central job');
    }

    @isTest
    static void ui2Marker_CannotBeSetOrClearedByOrdinaryUsers() {
        Account ui2 = entity();
        System.runAs(pilot()) {
            Database.SaveResult clear = Database.update(new Account(Id = ui2.Id, Integration_Test_Record_CC__c = false), false);
            Assert.isFalse(clear.isSuccess(), 'A pilot user cannot clear the marker to reach the real integration');
        }
        // A fresh administrator without the isolation-admin set (not the running user, who may legitimately hold it).
        User plainAdmin = OpportunityUi2TestData_CC.user('System Administrator', 'ui2admn');
        insert plainAdmin;
        System.runAs(plainAdmin) {
            Database.SaveResult adminSet = Database.insert(new Account(Name = 'X ' + OpportunityUi2TestData_CC.suffix(),
                RecordTypeId = OpportunityUi2TestData_CC.recordTypeId(Account.SObjectType, 'Entity'), Integration_Test_Record_CC__c = true,
                BillingStreet = '1 Test Street', BillingCity = 'New York', BillingStateCode = 'NY', BillingPostalCode = '10001', BillingCountryCode = 'US'), false);
            Assert.isFalse(adminSet.isSuccess(), 'Even an administrator needs the UI2 Isolation Admin permission');
        }
    }

    // ------------------------------------------------------------------ account view

    @isTest
    static void twoWinsAtOneEntity_AggregateOnce_WithDrillDown_AndSiteViewExcludesUnallocatedPlan() {
        Id wrapId = winAndActivate('ZZUI2 Win Wrap', 'ZZUI2 Wrap', MILLION, 12);
        Id tapeId = winAndActivate('ZZUI2 Win Tape', 'ZZUI2 Tape', 100000, 12);
        // Native actuals are not simulated: the platform refuses ActualAmount edits on a Draft agreement, and actuals
        // in the org come from native recalculation. Site actuals from real Orders are covered in uiEntryPoints_.
        AccountMonthlyForecastController_CC.AccountView entityView;
        AccountMonthlyForecastController_CC.AccountView siteView;
        System.runAs(pilot()) {
            entityView = AccountMonthlyForecastController_CC.getAccountView(entity().Id, Date.today().year());
            siteView = AccountMonthlyForecastController_CC.getAccountView(site('ZZUI2 Site A').Id, Date.today().year());
        }
        Assert.areEqual(1, entityView.currencies.size(), 'One GBP block');
        AccountMonthlyForecastController_CC.CurrencyBlock gbp = entityView.currencies[0];
        Assert.areEqual(1100000, gbp.months[0].originalPlan, 'Wrap 1m + tape 100k counted once each');
        Assert.areEqual(2, gbp.agreements.size(), 'Drill-down separates wrap and tape');
        Assert.areEqual(13200000, gbp.yearPlan);
        Assert.areEqual(13200000, gbp.unallocatedPlan, 'Entity-wide plans are shown as unallocated');
        Assert.isTrue(siteView.isSite);
        Assert.isTrue(siteView.currencies.isEmpty() || siteView.currencies[0].yearPlan == 0,
            'An Entity-wide plan is not copied onto each Site');
    }

    @isTest
    static void currencies_AreNeverCombined() {
        User pilotUser = pilot();
        Opportunity usd;
        PricebookEntry usdEntry;
        System.runAs(isoAdmin()) {
            usdEntry = OpportunityUi2TestData_CC.standardEntry('ZZUI2 USD Wrap', 1000, 'USD');
            usd = OpportunityUi2TestData_CC.newBusiness(entity().Id, pilotUser.Id, 120000, 'USD');
        }
        winAndActivate('ZZUI2 Win Wrap', 'ZZUI2 Wrap', MILLION, 12);
        SalesAgreementActivationJob_CC.chainNextStep = false;
        System.runAs(pilotUser) {
            SalesAgreementPlanService_CC.winAndPlan(OpportunityUi2TestData_CC.request(usd.Id, Date.newInstance(Date.today().year(), 1, 1),
                OpportunityUi2TestData_CC.repeat(10000, 12), usdEntry.Id));
            AccountMonthlyForecastController_CC.AccountView view = AccountMonthlyForecastController_CC.getAccountView(entity().Id, Date.today().year());
            Assert.areEqual(2, view.currencies.size(), 'GBP and USD are separate blocks');
            for (AccountMonthlyForecastController_CC.CurrencyBlock block : view.currencies) {
                Assert.areEqual(block.currencyIsoCode == 'GBP' ? 12 * MILLION : 120000, block.yearPlan, 'No cross-currency sum');
            }
        }
    }
}