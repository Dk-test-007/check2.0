/**
 * Test data for the Opportunity UI2. Uses valid state/country codes (the org enforces state and country picklists,
 * which is why the older TestDataFactory_CC address values now fail).
 */
@isTest
public class OpportunityUi2TestData_CC {

    public static final String PILOT_PS = 'Opportunity_UI2_Forecasting_CC';
    public static final String AGREEMENTS_PS = 'Opportunity_UI2_Agreements_CC';
    public static final String ISOLATION_PS = 'Opportunity_UI2_Admin_CC';
    public static final String AGREEMENTS_PSL = 'ManufacturingSalesAgreementsPsl';
    public static final String FOUNDATION_PSL = 'ManufacturingFoundationUserPsl';
    /** Standard permission sets that come with the two Manufacturing PSLs. */
    public static final List<String> NATIVE_PS = new List<String>{ 'ManufacturingSalesAgreementsPsl', 'ManufacturingFoundationUserPsl' };

    /** Native Sales Agreement entitlement: both Manufacturing PSLs and their standard permission sets. */
    public static void grantNativeAgreements(Id userId) {
        List<PermissionSetLicenseAssign> licences = new List<PermissionSetLicenseAssign>();
        for (PermissionSetLicense psl : [SELECT Id FROM PermissionSetLicense WHERE DeveloperName IN (:AGREEMENTS_PSL, :FOUNDATION_PSL)]) {
            licences.add(new PermissionSetLicenseAssign(AssigneeId = userId, PermissionSetLicenseId = psl.Id));
        }
        insert licences;
        assign(userId, NATIVE_PS);
    }
    private static Integer sequence = 0;

    public static String suffix() {
        sequence++;
        return String.valueOf(sequence) + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(6);
    }

    public static Id recordTypeId(SObjectType objectType, String developerName) {
        return objectType.getDescribe().getRecordTypeInfosByDeveloperName().get(developerName).getRecordTypeId();
    }

    public static User user(String profileName, String alias) {
        String s = suffix();
        return new User(FirstName = 'UI2', LastName = alias + ' ' + s, Alias = alias.left(8),
            Email = alias.toLowerCase() + s + '@carltontest.invalid', Username = alias.toLowerCase() + s + '@carltontest.invalid',
            ProfileId = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1].Id, TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_GB', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', CurrencyIsoCode = 'GBP', IsActive = true);
    }

    /** A Carlton Sales User with the UI2 pilot and agreement permission sets (and the agreements PSL). */
    public static User pilotUser() {
        return pilotUser('Carlton Sales User');
    }

    /**
     * Order-flow tests use 'Standard User', as the existing OrderTriggerHandlerTest_CC does: in a test runAs context
     * OrderTriggerHandler_CC.validateActivatedOrderUpdate cannot query Profile for Carlton profiles (pre-existing).
     */
    public static User pilotUser(String profileName) {
        User u = user(profileName, 'ui2pilot');
        insert u;
        grantNativeAgreements(u.Id);
        // Mirrors the real pilot persona (salesuser): the org's sales permission sets plus the UI2 sets.
        assign(u.Id, new List<String>{ PILOT_PS, AGREEMENTS_PS, 'PS_Carlton_Sales_User_CC',
            'Named_Credentials_Perm_Set_CC', 'Carlton_Agreement_Revision_Pilot' });
        return u;
    }

    /** A System Administrator who may set Account.Integration_Test_Record_CC__c (UI2 isolation admin). */
    public static User isolationAdmin() {
        User u = user('System Administrator', 'ui2isoad');
        insert u;
        grantNativeAgreements(u.Id);
        assign(u.Id, new List<String>{ ISOLATION_PS, PILOT_PS, AGREEMENTS_PS });
        return u;
    }

    /** A Carlton Sales User without UI2 access. */
    public static User nonPilotUser() {
        User u = user('Carlton Sales User', 'ui2none');
        insert u;
        return u;
    }

    public static void assign(Id userId, List<String> permissionSets) {
        List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
        for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSets]) {
            rows.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id));
        }
        insert rows;
    }

    /** Entity (Type Customer) with Sites, owned by ownerId. integrationTestRecord marks it synthetic UI2 data. */
    public static Account entity(Id ownerId, Boolean integrationTestRecord) {
        Account entity = new Account(Name = 'ZZUI2 Entity ' + suffix(), RecordTypeId = recordTypeId(Account.SObjectType, 'Entity'),
            Entity_CC__c = 'Carlton Packaging INC', OwnerId = ownerId, CurrencyIsoCode = 'GBP',
            BillingStreet = '1 Test Street', BillingCity = 'New York', BillingStateCode = 'NY', BillingPostalCode = '10001',
            BillingCountryCode = 'US', Integration_Test_Record_CC__c = integrationTestRecord);
        saveAllowingDuplicates(entity);
        saveAllowingDuplicates(new Account(Id = entity.Id, Type = 'Customer'));
        return entity;
    }

    public static Account site(Id entityId, Id ownerId, String name) {
        Account site = new Account(Name = name + ' ' + suffix(), ParentId = entityId, RecordTypeId = recordTypeId(Account.SObjectType, 'Site'),
            OwnerId = ownerId, CurrencyIsoCode = 'GBP', ShippingStreet = '2 Site Road', ShippingCity = 'Albany', ShippingStateCode = 'NY',
            ShippingPostalCode = '12207', ShippingCountryCode = 'US');
        saveAllowingDuplicates(site);
        return site;
    }

    /**
     * Inserts (no Id) or updates the Account even when an active duplicate rule reports a possible duplicate.
     * Test Accounts share an address, so the org's standard Account duplicate rule (active in new orgs) alerts on
     * them; through Apex an alert blocks the save unless allowSave is set. Any other error fails the test.
     */
    public static void saveAllowingDuplicates(Account record) {
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.SaveResult result = record.Id == null ? Database.insert(record, options) : Database.update(record, options);
        if (!result.isSuccess()) {
            throw new DmlException('Account save failed: ' + result.getErrors());
        }
    }

    public static PricebookEntry standardEntry(String productName, Decimal price, String isoCode) {
        Product2 product = new Product2(Name = productName + ' ' + suffix(), IsActive = true, ProductCode = 'ZZUI2-' + suffix());
        insert product;
        PricebookEntry entry = new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = product.Id,
            UnitPrice = price, IsActive = true, CurrencyIsoCode = isoCode);
        insert entry;
        return [SELECT Id, Product2Id, Product2.Name, UnitPrice, Pricebook2Id, CurrencyIsoCode FROM PricebookEntry WHERE Id = :entry.Id];
    }

    public static Opportunity newBusiness(Id accountId, Id ownerId, Decimal amount, String isoCode) {
        Opportunity opp = new Opportunity(Name = 'ZZUI2 Win ' + suffix(), AccountId = accountId, OwnerId = ownerId, Amount = amount,
            StageName = 'Discover', CloseDate = Date.today().addDays(30), CurrencyIsoCode = isoCode,
            Pricebook2Id = Test.getStandardPricebookId(), RecordTypeId = recordTypeId(Opportunity.SObjectType, 'New_Business'));
        insert opp;
        return opp;
    }

    public static SalesAgreementPlanService_CC.PlanRequest request(Id oppId, Date startMonth, List<Decimal> amounts, Id entryId) {
        SalesAgreementPlanService_CC.PlanRequest request = new SalesAgreementPlanService_CC.PlanRequest();
        request.opportunityId = oppId;
        request.startMonth = startMonth;
        request.termMonths = amounts.size();
        request.monthlyAmounts = amounts;
        SalesAgreementPlanService_CC.ProductShare share = new SalesAgreementPlanService_CC.ProductShare();
        share.pricebookEntryId = entryId;
        share.sharePercent = 100;
        request.products = new List<SalesAgreementPlanService_CC.ProductShare>{ share };
        request.scope = SalesAgreementPlanService_CC.SCOPE_ENTITY;
        return request;
    }

    public static List<Decimal> repeat(Decimal amount, Integer months) {
        List<Decimal> amounts = new List<Decimal>();
        for (Integer i = 0; i < months; i++) {
            amounts.add(amount);
        }
        return amounts;
    }

    public static Date firstOfMonth(Date d) {
        return Date.newInstance(d.year(), d.month(), 1);
    }
}