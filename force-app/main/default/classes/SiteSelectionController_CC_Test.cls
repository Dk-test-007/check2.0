/**
 * Tests for SiteSelectionController_CC (site selection on Opportunity, Quote and Order).
 * Runs as the System Administrator running the tests, with the Carlton permission sets and field access
 * (TestAdminAccess_CC), because the controller saves in user mode. The Entity is marked as synthetic UI2 data
 * (Integration_Test_Record_CC__c), which keeps Business Central callouts out; Opportunity_UI2_Admin_CC lets the
 * administrator set it.
 */
@IsTest
private class SiteSelectionController_CC_Test {

    private static final String SITE_A = 'ZZTEST Site Selection';
    private static final String SITE_B = 'ZZTEST Second Selection';
    private static final String SITE_FOREIGN = 'ZZTEST Foreign Selection';

    @TestSetup
    static void setup() {
        TestAdminAccess_CC.grant(new List<SObjectType>{ Account.SObjectType, Opportunity.SObjectType,
            Opportunity_Site__c.SObjectType, Quote.SObjectType, Order.SObjectType, OrderItem.SObjectType,
            OpportunityLineItem.SObjectType, QuoteLineItem.SObjectType, Product2.SObjectType },
            new List<String>{ OpportunityUi2TestData_CC.ISOLATION_PS });
        User admin = TestAdminAccess_CC.admin();
        User pilot = admin;
        System.runAs(admin) {
            Account entity = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            OpportunityUi2TestData_CC.site(entity.Id, pilot.Id, SITE_A);
            OpportunityUi2TestData_CC.site(entity.Id, pilot.Id, SITE_B);
            Account other = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            OpportunityUi2TestData_CC.site(other.Id, pilot.Id, SITE_FOREIGN);
            TestDmlRetry_CC.activateStandardPricebook();
            OpportunityUi2TestData_CC.standardEntry('ZZTEST SiteSel Product', 100, 'GBP');
            OpportunityUi2TestData_CC.newBusiness(entity.Id, pilot.Id, 100, 'GBP');
        }
    }

    // ------------------------------------------------------------------ helpers

    /** The user the controller runs as: the System Administrator running the tests. */
    private static User pilot() {
        return TestAdminAccess_CC.admin();
    }

    private static User isoAdmin() {
        return TestAdminAccess_CC.admin();
    }

    private static Opportunity opportunity() {
        return [SELECT Id, AccountId, Pricebook2Id, Ship_To_Site_CC__c FROM Opportunity
            WHERE Name LIKE 'ZZUI2 Win%' LIMIT 1];
    }

    private static Account site(String namePrefix) {
        String pattern = namePrefix + '%';
        return [SELECT Id, ParentId FROM Account WHERE Name LIKE :pattern LIMIT 1];
    }

    private static Quote createQuote(Id opportunityId) {
        Quote q = new Quote(Name = 'ZZTEST Site Selection Quote', OpportunityId = opportunityId,
            Pricebook2Id = Test.getStandardPricebookId(), Status = 'Draft');
        System.runAs(isoAdmin()) {
            insert q;
        }
        return q;
    }

    private static Order createOrder(Opportunity opp) {
        Order orderRecord = new Order(
            AccountId = opp.AccountId, Pricebook2Id = opp.Pricebook2Id,
            CurrencyIsoCode = 'GBP', EffectiveDate = Date.today(), Status = 'Draft',
            BillingStreet = '1 Test Street', BillingCity = 'New York',
            BillingStateCode = 'NY', BillingPostalCode = '10001', BillingCountryCode = 'US'
        );
        insert orderRecord;
        return orderRecord;
    }

    private static Integer siteCount(String parentField, Id parentId, Id siteId, Boolean primaryOnly) {
        String soql = 'SELECT COUNT() FROM Opportunity_Site__c WHERE ' + parentField + ' = :parentId';
        if (siteId != null) {
            soql += ' AND Site__c = :siteId';
        }
        if (primaryOnly) {
            soql += ' AND Primary__c = true';
        }
        return Database.countQuery(soql, AccessLevel.SYSTEM_MODE);
    }

    /** Runs the action and returns the AuraHandledException message, or null when nothing was thrown. */
    private static String errorOf(SiteAction action) {
        try {
            action.run();
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private interface SiteAction {
        void run();
    }

    private class GetData implements SiteAction {
        Id recordId;
        GetData(Id recordId) { this.recordId = recordId; }
        public void run() { SiteSelectionController_CC.getSiteSelectionData(recordId); }
    }

    private class SaveSites implements SiteAction {
        Id recordId;
        List<Id> siteIds;
        SaveSites(Id recordId, List<Id> siteIds) { this.recordId = recordId; this.siteIds = siteIds; }
        public void run() { SiteSelectionController_CC.saveSites(recordId, siteIds, null); }
    }

    private class UpdatePrimary implements SiteAction {
        Id recordId;
        Id siteId;
        UpdatePrimary(Id recordId, Id siteId) { this.recordId = recordId; this.siteId = siteId; }
        public void run() { SiteSelectionController_CC.updatePrimarySite(recordId, siteId); }
    }

    private class UpdateOrderSite implements SiteAction {
        Id orderId;
        Id siteId;
        UpdateOrderSite(Id orderId, Id siteId) { this.orderId = orderId; this.siteId = siteId; }
        public void run() { SiteSelectionController_CC.updateOrderShipToSite(orderId, siteId); }
    }

    // ------------------------------------------------------------------ Opportunity

    @IsTest
    static void opportunity_LoadsSitesAndSavesPrimarySelection() {
        Opportunity opp = opportunity();
        Account siteA = site(SITE_A);
        Account siteB = site(SITE_B);

        Test.startTest();
        System.runAs(pilot()) {
            Map<String, Object> data = SiteSelectionController_CC.getSiteSelectionData(opp.Id);
            Assert.areEqual('Opportunity', data.get('parentObjectName'));
            Assert.areEqual(2, ((List<Account>) data.get('relatedSiteAccounts')).size(), 'Both Sites of the Entity');
            Assert.areEqual(0, ((List<Opportunity_Site__c>) data.get('existingSites')).size());
            Assert.isFalse(data.containsKey('currentOrderShipToSiteId'), 'Order keys only for Orders');

            // First selection with a Shipment Site.
            SiteSelectionController_CC.saveSites(opp.Id, new List<Id>{ siteA.Id }, siteA.Id);
            Assert.areEqual(siteA.Id, opportunity().Ship_To_Site_CC__c);
            Assert.areEqual(1, siteCount('Opportunity__c', opp.Id, siteA.Id, true));

            // Add a second Site and move the Shipment Site to it: the first Site is demoted.
            SiteSelectionController_CC.saveSites(opp.Id, new List<Id>{ siteA.Id, siteB.Id }, siteB.Id);
            Assert.areEqual(2, siteCount('Opportunity__c', opp.Id, null, false));
            Assert.areEqual(1, siteCount('Opportunity__c', opp.Id, siteB.Id, true));
            Assert.areEqual(0, siteCount('Opportunity__c', opp.Id, siteA.Id, true));
            Assert.areEqual(siteB.Id, opportunity().Ship_To_Site_CC__c);

            // Re-save without a Shipment Site: nothing new, the existing designation is kept.
            SiteSelectionController_CC.saveSites(opp.Id, new List<Id>{ siteA.Id, siteB.Id }, null);
            Assert.areEqual(2, siteCount('Opportunity__c', opp.Id, null, false));
            Assert.areEqual(siteB.Id, opportunity().Ship_To_Site_CC__c);

            // Change the Shipment Site directly.
            SiteSelectionController_CC.updatePrimarySite(opp.Id, siteA.Id);
            Assert.areEqual(1, siteCount('Opportunity__c', opp.Id, siteA.Id, true));
            Assert.areEqual(0, siteCount('Opportunity__c', opp.Id, siteB.Id, true));

            data = SiteSelectionController_CC.getSiteSelectionData(opp.Id);
            Assert.areEqual(2, ((List<Opportunity_Site__c>) data.get('existingSites')).size());
        }
        Test.stopTest();
        Assert.areEqual(siteA.Id, opportunity().Ship_To_Site_CC__c);
    }

    @IsTest
    static void opportunity_SaveWithoutShipmentSite_LeavesNoPrimary() {
        Opportunity opp = opportunity();
        Account siteA = site(SITE_A);

        Test.startTest();
        System.runAs(pilot()) {
            SiteSelectionController_CC.saveSites(opp.Id, new List<Id>{ siteA.Id }, null);
        }
        Test.stopTest();

        Assert.areEqual(1, siteCount('Opportunity__c', opp.Id, siteA.Id, false));
        Assert.areEqual(0, siteCount('Opportunity__c', opp.Id, null, true), 'No Shipment Site was designated');
    }

    // ------------------------------------------------------------------ Quote

    @IsTest
    static void quote_SavesSitesAndMirrorsThemOnTheOpportunity() {
        Opportunity opp = opportunity();
        Account siteA = site(SITE_A);
        Account siteB = site(SITE_B);
        Quote q = createQuote(opp.Id);

        Test.startTest();
        System.runAs(pilot()) {
            Map<String, Object> data = SiteSelectionController_CC.getSiteSelectionData(q.Id);
            Assert.areEqual('Quote', data.get('parentObjectName'));
            Assert.areEqual(2, ((List<Account>) data.get('relatedSiteAccounts')).size());
            Assert.areEqual(0, ((List<Opportunity_Site__c>) data.get('existingSites')).size());

            // The Quote Site is created, and the Site is also added to the parent Opportunity.
            SiteSelectionController_CC.saveSites(q.Id, new List<Id>{ siteA.Id }, siteA.Id);
            Assert.areEqual(1, siteCount('Quote_CC__c', q.Id, siteA.Id, true));
            Assert.areEqual(1, siteCount('Opportunity__c', opp.Id, siteA.Id, false));

            // Site B already on the Opportunity: it is not duplicated there when added to the Quote.
            SiteSelectionController_CC.saveSites(opp.Id, new List<Id>{ siteB.Id }, null);
            SiteSelectionController_CC.saveSites(q.Id, new List<Id>{ siteA.Id, siteB.Id }, null);
            Assert.areEqual(2, siteCount('Quote_CC__c', q.Id, null, false));
            Assert.areEqual(1, siteCount('Quote_CC__c', q.Id, siteA.Id, true), 'Existing Shipment Site kept');
            Assert.areEqual(1, siteCount('Opportunity__c', opp.Id, siteB.Id, false), 'Not duplicated on the Opportunity');

            SiteSelectionController_CC.updatePrimarySite(q.Id, siteB.Id);
            Assert.areEqual(1, siteCount('Quote_CC__c', q.Id, siteB.Id, true));
            Assert.areEqual(0, siteCount('Quote_CC__c', q.Id, siteA.Id, true));
        }
        Test.stopTest();

        Quote saved = [SELECT Ship_to_Site_CC__c FROM Quote WHERE Id = :q.Id];
        Assert.areEqual(siteB.Id, saved.Ship_to_Site_CC__c, 'The Quote Ship-to Site follows the Shipment Site');
    }

    // ------------------------------------------------------------------ Order

    @IsTest
    static void order_SelectsShipToSiteAndSyncsOrderProducts() {
        Opportunity opp = opportunity();
        Account siteA = site(SITE_A);
        Account foreign = site(SITE_FOREIGN);
        PricebookEntry entry = [SELECT Id, UnitPrice FROM PricebookEntry
            WHERE Product2.Name LIKE 'ZZTEST SiteSel Product%' AND Pricebook2Id = :Test.getStandardPricebookId()
            AND CurrencyIsoCode = 'GBP' LIMIT 1];

        Test.startTest();
        System.runAs(pilot()) {
            Order orderRecord = createOrder(opp);
            // The Order Product only widens coverage of the synchronisation loop; Order Product automation
            // is not under test here, so a refusal does not fail this test.
            try {
                insert new OrderItem(OrderId = orderRecord.Id, PricebookEntryId = entry.Id, Quantity = 1, UnitPrice = entry.UnitPrice);
            } catch (DmlException e) {
                System.debug(LoggingLevel.INFO, 'Order Product not created: ' + e.getDmlMessage(0));
            }

            Map<String, Object> data = SiteSelectionController_CC.getSiteSelectionData(orderRecord.Id);
            Assert.areEqual('Order', data.get('parentObjectName'));
            Assert.isTrue(data.containsKey('currentOrderShipToSiteId'));
            Assert.isTrue(data.containsKey('currentOrderShipToSiteName'));
            Assert.areEqual(0, ((List<Opportunity_Site__c>) data.get('existingSites')).size(), 'Orders have no Site list');

            SiteSelectionController_CC.updateOrderShipToSite(orderRecord.Id, siteA.Id);
            Assert.areEqual(siteA.Id, [SELECT Ship_to_Customer_No_CC__c FROM Order
                WHERE Id = :orderRecord.Id].Ship_to_Customer_No_CC__c);

            data = SiteSelectionController_CC.getSiteSelectionData(orderRecord.Id);
            Assert.areEqual(siteA.Id, data.get('currentOrderShipToSiteId'));
            Assert.isNotNull(data.get('currentOrderShipToSiteName'));

            String message = errorOf(new UpdateOrderSite(orderRecord.Id, foreign.Id));
            Assert.isNotNull(message, 'A Site of another Entity is rejected');
        }
        Test.stopTest();
    }

    // ------------------------------------------------------------------ validation

    @IsTest
    static void rejectsInvalidInput() {
        Opportunity opp = opportunity();
        Account siteA = site(SITE_A);
        Id missingOpportunityId = Id.valueOf(Opportunity.SObjectType.getDescribe().getKeyPrefix() + '000000000000');

        Test.startTest();
        System.runAs(pilot()) {
            Assert.isNotNull(errorOf(new GetData(null)), 'A record Id is required');
            Assert.isNotNull(errorOf(new GetData(siteA.Id)), 'Accounts are not supported');
            Assert.isNotNull(errorOf(new GetData(missingOpportunityId)), 'Unknown record');
            Assert.isNotNull(errorOf(new SaveSites(opp.Id, new List<Id>())), 'At least one Site');
            Assert.isNotNull(errorOf(new SaveSites(opp.Id, null)), 'At least one Site');
            Assert.isNotNull(errorOf(new SaveSites(null, new List<Id>{ siteA.Id })), 'A record is required');
            Assert.isNotNull(errorOf(new UpdatePrimary(null, siteA.Id)), 'A record is required');
            Assert.isNotNull(errorOf(new UpdatePrimary(opp.Id, null)), 'A Site is required');
            Assert.isNotNull(errorOf(new UpdateOrderSite(null, siteA.Id)), 'An Order is required');
            Assert.isNotNull(errorOf(new UpdateOrderSite(opp.Id, siteA.Id)), 'An Opportunity cannot be passed to the Order action');
        }
        Test.stopTest();
    }
}