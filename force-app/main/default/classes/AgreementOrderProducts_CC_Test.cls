/**
 * Tests for AgreementOrderProducts_CC: an Order entered as a Sales Agreement release (Agreement Release Key set) may
 * only carry that agreement's products; Order Products of other Orders, or without an Order, are not checked.
 * The release Orders are inserted directly (system mode, by the UI2 isolation administrator) so the check is tested on
 * its own, independently of the release service and of the Order Product trigger wiring.
 */
@IsTest
private class AgreementOrderProducts_CC_Test {

    private static final Decimal MILLION = 1000000;

    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.isolationAdmin();
        User pilot = OpportunityUi2TestData_CC.pilotUser();
        System.runAs(admin) {
            Account entity = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            OpportunityUi2TestData_CC.site(entity.Id, pilot.Id, 'ZZAOP Site');
            OpportunityUi2TestData_CC.standardEntry('ZZAOP Wrap', 1000, 'GBP');
            OpportunityUi2TestData_CC.standardEntry('ZZAOP Tape', 500, 'GBP');
            OpportunityUi2TestData_CC.newBusiness(entity.Id, pilot.Id, 12 * MILLION, 'GBP');
        }
    }

    private static User pilot() {
        return [SELECT Id FROM User WHERE Alias = 'ui2pilot' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static User isoAdmin() {
        return [SELECT Id FROM User WHERE Alias = 'ui2isoad' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static Id entryId(String productPrefix) {
        String pattern = productPrefix + '%';
        return [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE :pattern AND CurrencyIsoCode = 'GBP'
                AND Pricebook2Id = :Test.getStandardPricebookId() LIMIT 1].Id;
    }

    /** Wins the Opportunity as the pilot; the agreement has one product (Wrap). */
    private static Id plan() {
        Opportunity o = [SELECT Id FROM Opportunity WHERE Name LIKE 'ZZUI2 Win%' LIMIT 1];
        SalesAgreementActivationJob_CC.chainNextStep = false;
        Id agreementId;
        System.runAs(pilot()) {
            agreementId = SalesAgreementPlanService_CC.winAndPlan(OpportunityUi2TestData_CC.request(o.Id,
                OpportunityUi2TestData_CC.firstOfMonth(Date.today()), OpportunityUi2TestData_CC.repeat(MILLION, 12),
                entryId('ZZAOP Wrap'))).salesAgreementId;
        }
        return agreementId;
    }

    private static Order buildOrder(Id accountId, Date effectiveDate) {
        return new Order(AccountId = accountId, Pricebook2Id = Test.getStandardPricebookId(), CurrencyIsoCode = 'GBP',
            EffectiveDate = effectiveDate, Status = 'Draft',
            BillingStreet = '1 Test Street', BillingCity = 'New York', BillingStateCode = 'NY',
            BillingPostalCode = '10001', BillingCountryCode = 'US');
    }

    @IsTest
    static void releaseOrders_OnlyAcceptTheirAgreementsProducts() {
        Id agreementId = plan();
        SalesAgreement agreement;
        // Sales Agreement access needs the Manufacturing licences, which the isolation administrator holds.
        System.runAs(isoAdmin()) {
            agreement = [SELECT Id, Name, AccountId, StartDate FROM SalesAgreement WHERE Id = :agreementId WITH SYSTEM_MODE];
        }
        Id wrapEntry = entryId('ZZAOP Wrap');
        Id tapeEntry = entryId('ZZAOP Tape');

        Order extensionRelease = buildOrder(agreement.AccountId, Date.today());
        extensionRelease.Agreement_Extension_CC__c = agreementId;
        extensionRelease.Agreement_Release_Key_CC__c = agreementId + '|ZZAOP-EXT|1';
        Order nativeRelease = buildOrder(agreement.AccountId, agreement.StartDate.addDays(1));
        nativeRelease.SalesAgreementId = agreementId;
        nativeRelease.Agreement_Release_Key_CC__c = agreementId + '|ZZAOP-NATIVE|1';
        Order ordinary = buildOrder(agreement.AccountId, Date.today());
        Boolean nativeLinked = false;
        System.runAs(isoAdmin()) {
            Database.insert(new List<Order>{ extensionRelease, ordinary }, AccessLevel.SYSTEM_MODE);
            // The platform decides whether a native agreement link is accepted for this agreement's status.
            nativeLinked = Database.insert(nativeRelease, false, AccessLevel.SYSTEM_MODE).isSuccess();
        }

        OrderItem noOrder = new OrderItem(PricebookEntryId = tapeEntry);
        OrderItem extensionAllowed = new OrderItem(OrderId = extensionRelease.Id, PricebookEntryId = wrapEntry);
        OrderItem extensionRefused = new OrderItem(OrderId = extensionRelease.Id, PricebookEntryId = tapeEntry);
        OrderItem ordinaryItem = new OrderItem(OrderId = ordinary.Id, PricebookEntryId = tapeEntry);
        List<OrderItem> items = new List<OrderItem>{ noOrder, extensionAllowed, extensionRefused, ordinaryItem };
        OrderItem nativeRefused;
        OrderItem nativeAllowed;
        if (nativeLinked) {
            nativeRefused = new OrderItem(OrderId = nativeRelease.Id, PricebookEntryId = tapeEntry);
            nativeAllowed = new OrderItem(OrderId = nativeRelease.Id, PricebookEntryId = wrapEntry);
            items.add(nativeRefused);
            items.add(nativeAllowed);
        }

        Test.startTest();
        System.runAs(isoAdmin()) {
            AgreementOrderProducts_CC.check(items);
        }
        Test.stopTest();

        Assert.isFalse(noOrder.hasErrors(), 'Order Products without an Order are not checked');
        Assert.isFalse(ordinaryItem.hasErrors(), 'Orders that are not agreement releases are not checked');
        Assert.isFalse(extensionAllowed.hasErrors(), 'The agreement product is accepted');
        Assert.isTrue(extensionRefused.hasErrors(), 'A product outside the agreement is refused');
        String message = extensionRefused.getErrors()[0].getMessage();
        Assert.isTrue(message.contains(agreement.Name), message);
        Assert.isTrue(message.contains('can only include that agreement'), message);
        if (nativeLinked) {
            Assert.isTrue(nativeRefused.hasErrors(), 'Native release: a product outside the agreement is refused');
            Assert.isFalse(nativeAllowed.hasErrors(), 'Native release: the agreement product is accepted');
        }
    }

    @IsTest
    static void ordersThatAreNotReleases_AreLeftAlone() {
        Id tapeEntry = entryId('ZZAOP Tape');
        Account entity = [SELECT Id FROM Account WHERE Name LIKE 'ZZUI2 Entity%' LIMIT 1];
        Order ordinary = buildOrder(entity.Id, Date.today());
        System.runAs(isoAdmin()) {
            Database.insert(ordinary, AccessLevel.SYSTEM_MODE);
        }
        OrderItem item = new OrderItem(OrderId = ordinary.Id, PricebookEntryId = tapeEntry);
        OrderItem orphan = new OrderItem(PricebookEntryId = tapeEntry);

        Test.startTest();
        System.runAs(isoAdmin()) {
            AgreementOrderProducts_CC.check(new List<OrderItem>{ orphan });
            AgreementOrderProducts_CC.check(new List<OrderItem>{ item });
        }
        Test.stopTest();

        Assert.isFalse(orphan.hasErrors());
        Assert.isFalse(item.hasErrors());
    }

    @IsTest
    static void message_NamesTheAgreementAndItsProducts() {
        String extension;
        String nativeLink;
        System.runAs(isoAdmin()) {
            Order extensionRelease = new Order(Agreement_Extension_CC__r = new SalesAgreement(Name = 'ZZAOP Extension Agreement'));
            extension = AgreementOrderProducts_CC.message(extensionRelease, new List<String>());
            Order nativeRelease = new Order(
                SalesAgreementId = Id.valueOf(SalesAgreement.SObjectType.getDescribe().getKeyPrefix() + '000000000000'),
                SalesAgreement = new SalesAgreement(Name = 'ZZAOP Native Agreement'));
            nativeLink = AgreementOrderProducts_CC.message(nativeRelease, new List<String>{ 'Wrap', 'Tape' });
        }
        Assert.isTrue(extension.contains('ZZAOP Extension Agreement') && extension.contains('(none)'), extension);
        Assert.isTrue(nativeLink.contains('ZZAOP Native Agreement') && nativeLink.contains('Wrap, Tape'), nativeLink);
    }
}