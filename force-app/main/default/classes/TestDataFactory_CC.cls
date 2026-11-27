/**
 * =============================================================================
 * Class Name    : TestDataFactory_CC
 * Description   : Shared test data builders for Apex unit tests.
 *
 * Created Date  : Oct 2026
 * =============================================================================
 * Usage:
 * Every builder returns the record(s) and only performs DML when doInsert is
 * true, so callers can adjust fields before inserting. Defaults satisfy the
 * Apex trigger handler checks of this org (for example, Quotes need an Entity
 * with a billing address and a primary Opportunity Site with a shipping
 * address). Validation rules are bypassed for the System Administrator
 * profile, so tests that run as Carlton profiles must populate any extra
 * fields those rules require.
 * =============================================================================
 */
@IsTest
public class TestDataFactory_CC {

    public static final String ENTITY_INC = 'Carlton Packaging INC';
    public static final String ENTITY_LLP = 'Carlton Packaging LLP';

    private static Integer uniqueCounter = 0;

    /**
     * @description Returns a value that is unique within the test transaction.
     */
    public static String uniqueSuffix() {
        uniqueCounter++;
        return String.valueOf(uniqueCounter) + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(6);
    }

    /**
     * @description Returns the Id of an active record type by developer name.
     */
    public static Id recordTypeId(Schema.SObjectType sObjectType, String developerName) {
        Schema.RecordTypeInfo info = sObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get(developerName);
        return info == null ? null : info.getRecordTypeId();
    }

    // ---------------------------------------------------------------------
    // Accounts
    // ---------------------------------------------------------------------

    /**
     * @description Builds a Corporate Group (top level) Account.
     */
    public static Account createCorporateGroup(String name, Boolean doInsert) {
        Account acc = new Account(
            Name = name,
            RecordTypeId = recordTypeId(Account.SObjectType, 'Corporate_Group')
        );
        if (doInsert) {
            insert acc;
        }
        return acc;
    }

    /**
     * @description Builds an Entity Account with a full billing address.
     */
    public static Account createEntity(String name, Id parentId, Boolean doInsert) {
        Account acc = new Account(
            Name = name,
            ParentId = parentId,
            RecordTypeId = recordTypeId(Account.SObjectType, 'Entity'),
            Entity_CC__c = ENTITY_INC,
            BillingStreet = '123 Test Street',
            BillingCity = 'Test City',
            BillingState = 'New York',   // State and Country picklists are enabled: must be a valid US state
            BillingPostalCode = '12345',
            BillingCountry = 'United States'
        );
        if (doInsert) {
            insert acc;
        }
        return acc;
    }

    /**
     * @description Builds a list of Entity Accounts (bulk scenarios).
     */
    public static List<Account> createEntities(Integer count, Boolean doInsert) {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(createEntity('Test Entity ' + i, null, false));
        }
        if (doInsert) {
            insert accounts;
        }
        return accounts;
    }

    /**
     * @description Builds a Site Account under an Entity with a full shipping address.
     */
    public static Account createSite(String name, Id entityId, Boolean doInsert) {
        Account acc = new Account(
            Name = name,
            ParentId = entityId,
            RecordTypeId = recordTypeId(Account.SObjectType, 'Site'),
            ShippingStreet = '456 Site Street',
            ShippingCity = 'Site City',
            ShippingState = 'New York',   // must be a valid US state (State and Country picklists)
            ShippingPostalCode = '54321',
            ShippingCountry = 'United States'
        );
        if (doInsert) {
            insert acc;
        }
        return acc;
    }

    // ---------------------------------------------------------------------
    // Contacts and Leads
    // ---------------------------------------------------------------------

    /**
     * @description Builds a Contact that satisfies the Contact validation rules.
     */
    public static Contact createContact(Id accountId, Boolean doInsert) {
        String suffix = uniqueSuffix();
        Contact con = new Contact(
            FirstName = 'Test',
            LastName = 'Contact ' + suffix,
            Email = 'contact' + suffix + '@carltontest.invalid',
            Phone = '+1 555 0100',
            AccountId = accountId
        );
        if (doInsert) {
            insert con;
        }
        return con;
    }

    /**
     * @description Builds a Lead in the given status with the fields the Engage/Qualified gates need.
     */
    public static Lead createLead(String lastName, String status, Boolean doInsert) {
        String suffix = uniqueSuffix();
        Lead ld = new Lead(
            FirstName = 'Test',
            LastName = lastName,
            Company = lastName + ' Co ' + suffix,
            Status = status,
            Email = 'lead' + suffix + '@carltontest.invalid',
            Phone = '+1 555 0101',
            City = 'Test City',
            Country = 'United States',
            PostalCode = '12345',
            Title = 'Buyer',
            Belongs_To_CC__c = ENTITY_INC
        );
        if (doInsert) {
            insert ld;
        }
        return ld;
    }

    // ---------------------------------------------------------------------
    // Opportunities, Products and Quotes
    // ---------------------------------------------------------------------

    /**
     * @description Builds an Opportunity. recordTypeDeveloperName is 'New_Business' or 'BAU'.
     */
    public static Opportunity createOpportunity(Id accountId, String recordTypeDeveloperName, Boolean doInsert) {
        Boolean isBau = recordTypeDeveloperName == 'BAU';
        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity ' + uniqueSuffix(),
            AccountId = accountId,
            StageName = isBau ? 'Request' : 'Discover',
            CloseDate = Date.today().addDays(30),
            RecordTypeId = recordTypeId(Opportunity.SObjectType, recordTypeDeveloperName)
        );
        if (doInsert) {
            insert opp;
        }
        return opp;
    }

    /**
     * @description Links a Site Account to an Opportunity.
     */
    public static Opportunity_Site__c createOpportunitySite(Id opportunityId, Id siteId, Boolean isPrimary, Boolean doInsert) {
        Opportunity_Site__c oppSite = new Opportunity_Site__c(
            Opportunity__c = opportunityId,
            Site__c = siteId,
            Primary__c = isPrimary
        );
        if (doInsert) {
            insert oppSite;
        }
        return oppSite;
    }

    /**
     * @description Builds an active Product2.
     */
    public static Product2 createProduct(String name, Boolean doInsert) {
        Product2 prod = new Product2(
            Name = name,
            ProductCode = 'TP-' + uniqueSuffix(),
            IsActive = true
        );
        if (doInsert) {
            insert prod;
        }
        return prod;
    }

    /**
     * @description Builds an active standard price book entry for a product.
     */
    public static PricebookEntry createStandardPricebookEntry(Id productId, Decimal unitPrice, Boolean doInsert) {
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = productId,
            UnitPrice = unitPrice,
            IsActive = true
        );
        if (doInsert) {
            insert pbe;
        }
        return pbe;
    }

    /** Reuse the entry that Product automation may have created in this org. */
    public static PricebookEntry ensureStandardPricebookEntry(Id productId, Decimal unitPrice) {
        Id standardBookId = Test.getStandardPricebookId();
        String userCurrency = UserInfo.getDefaultCurrency();
        List<PricebookEntry> existing = [SELECT Id, UnitPrice, IsActive, CurrencyIsoCode
            FROM PricebookEntry WHERE Pricebook2Id = :standardBookId AND Product2Id = :productId
            AND CurrencyIsoCode = :userCurrency WITH SYSTEM_MODE LIMIT 1];
        if (existing.isEmpty()) {
            PricebookEntry created = createStandardPricebookEntry(productId, unitPrice, true);
            return created;
        }
        PricebookEntry entry = existing[0];
        if (entry.UnitPrice != unitPrice || !entry.IsActive) {
            update new PricebookEntry(Id = entry.Id, UnitPrice = unitPrice, IsActive = true);
        }
        entry.UnitPrice = unitPrice;
        entry.IsActive = true;
        return entry;
    }

    /**
     * @description Builds a Draft Quote on the standard price book.
     */
    public static Quote createQuote(Id opportunityId, Boolean doInsert) {
        Quote qt = new Quote(
            Name = 'Test Quote ' + uniqueSuffix(),
            OpportunityId = opportunityId,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        if (doInsert) {
            insert qt;
        }
        return qt;
    }

    /**
     * @description Builds a Quote Line Item.
     */
    public static QuoteLineItem createQuoteLineItem(Id quoteId, PricebookEntry pbe, Decimal quantity, Boolean doInsert) {
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = quoteId,
            PricebookEntryId = pbe.Id,
            Product2Id = pbe.Product2Id,
            Quantity = quantity,
            UnitPrice = pbe.UnitPrice
        );
        if (doInsert) {
            insert qli;
        }
        return qli;
    }

    /**
     * @description Holder for a complete, valid Entity -> Site -> Opportunity -> Quote chain.
     */
    public class SalesChain {
        public Account entity;
        public Account site;
        public Opportunity opportunity;
        public Opportunity_Site__c opportunitySite;
        public Product2 product;
        public PricebookEntry pricebookEntry;
        public Quote quote;
        public QuoteLineItem quoteLineItem;
    }

    /**
     * @description Inserts Entity, Site, New Business Opportunity, primary Opportunity Site, Product,
     *              standard PricebookEntry, Draft Quote and one Quote Line Item.
     */
    public static SalesChain createSalesChain() {
        SalesChain chain = new SalesChain();
        chain.entity = createEntity('Chain Entity ' + uniqueSuffix(), null, true);
        chain.site = createSite('Chain Site ' + uniqueSuffix(), chain.entity.Id, true);
        chain.opportunity = createOpportunity(chain.entity.Id, 'New_Business', true);
        chain.opportunitySite = createOpportunitySite(chain.opportunity.Id, chain.site.Id, true, true);
        chain.product = createProduct('Chain Product', true);
        chain.pricebookEntry = createStandardPricebookEntry(chain.product.Id, 100, true);
        chain.quote = createQuote(chain.opportunity.Id, true);
        chain.quoteLineItem = createQuoteLineItem(chain.quote.Id, chain.pricebookEntry, 2, true);
        return chain;
    }

    // ---------------------------------------------------------------------
    // Users and queues
    // ---------------------------------------------------------------------

    /**
     * @description Builds an active User for the given profile name (for example 'Carlton Sales User').
     */
    public static User createUser(String profileName, String aliasSeed, Boolean doInsert) {
        Profile prof = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String suffix = uniqueSuffix();
        User usr = new User(
            FirstName = 'Test',
            LastName = aliasSeed + ' ' + suffix,
            Alias = aliasSeed.left(8),
            Email = aliasSeed.toLowerCase() + suffix + '@carltontest.invalid',
            Username = aliasSeed.toLowerCase() + suffix + '@carltontest.invalid',
            ProfileId = prof.Id,
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            IsActive = true
        );
        if (doInsert) {
            insert usr;
        }
        return usr;
    }

    /**
     * @description Returns the Id of a queue by developer name, or null when it does not exist.
     */
    public static Id queueId(String developerName) {
        List<Group> queues = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :developerName LIMIT 1];
        return queues.isEmpty() ? null : queues[0].Id;
    }

    // ---------------------------------------------------------------------
    // Callouts
    // ---------------------------------------------------------------------

    /**
     * @description Generic HTTP mock returning a fixed status code and body for every request.
     */
    public class HttpMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;
        public Integer callCount = 0;

        public HttpMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(body);
            return res;
        }
    }
}