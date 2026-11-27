/**
 * Tests for PricebookSyncController_CC: copying Quote Line Item prices into the Entity price books.
 *
 * Data: one Entity with a Quote of three products -
 *   SAME    : already in the Entity price book at the quoted price   -> NO_CHANGE
 *   CHANGED : in the Entity price book at a different price          -> UPDATE
 *   NEW     : not in the Entity price book                           -> CREATE
 * plus a product that is not on the Quote, and a price book that does not belong to the Entity.
 */
@IsTest
private class PricebookSyncController_CC_Test {

    private static final String ISO = 'GBP';
    private static final String ENTITY_BOOK = 'ZZPBS Entity Book';
    private static final String OTHER_BOOK = 'ZZPBS Other Book';

    @TestSetup
    static void setup() {
        // The controller queries in user mode; give the running admin access to the fields it reads.
        TestAdminAccess_CC.grant(new List<SObjectType>{ Account.SObjectType, Opportunity.SObjectType, Quote.SObjectType,
            QuoteLineItem.SObjectType, Pricebook2.SObjectType, PricebookEntry.SObjectType, Product2.SObjectType });

        // The controller looks up the standard price book with SOQL; in tests it is only visible once updated.
        TestDmlRetry_CC.activateStandardPricebook();

        Id userId = UserInfo.getUserId();
        Account entity = OpportunityUi2TestData_CC.entity(userId, false);

        PricebookEntry same = OpportunityUi2TestData_CC.standardEntry('ZZPBS Same', 10, ISO);
        PricebookEntry changed = OpportunityUi2TestData_CC.standardEntry('ZZPBS Changed', 20, ISO);
        PricebookEntry fresh = OpportunityUi2TestData_CC.standardEntry('ZZPBS New', 30, ISO);
        OpportunityUi2TestData_CC.standardEntry('ZZPBS Not On Quote', 40, ISO);

        Opportunity opp = OpportunityUi2TestData_CC.newBusiness(entity.Id, userId, 1000, ISO);
        Quote quote = new Quote(Name = 'ZZPBS Quote', OpportunityId = opp.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert quote;

        insert new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = quote.Id, PricebookEntryId = same.Id, Quantity = 1, UnitPrice = 10),
            new QuoteLineItem(QuoteId = quote.Id, PricebookEntryId = changed.Id, Quantity = 1, UnitPrice = 25),
            new QuoteLineItem(QuoteId = quote.Id, PricebookEntryId = fresh.Id, Quantity = 1, UnitPrice = 35)
        };

        Pricebook2 entityBook = new Pricebook2(Name = ENTITY_BOOK, Entity__c = entity.Id, IsActive = true);
        Pricebook2 otherBook = new Pricebook2(Name = OTHER_BOOK, IsActive = true);
        insert new List<Pricebook2>{ entityBook, otherBook };

        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = entityBook.Id, Product2Id = same.Product2Id, UnitPrice = 10, IsActive = true, CurrencyIsoCode = ISO),
            new PricebookEntry(Pricebook2Id = entityBook.Id, Product2Id = changed.Product2Id, UnitPrice = 20, IsActive = true, CurrencyIsoCode = ISO)
        };
    }

    // ------------------------------------------------------------------ helpers

    /** save() looks up the standard price book with SOQL, which only returns it in tests once it has been updated. */
    private static void exposeStandardPricebook() {
        TestDmlRetry_CC.activateStandardPricebook();
    }

    private static Quote quote() {
        return [SELECT Id FROM Quote WHERE Name = 'ZZPBS Quote' LIMIT 1];
    }

    private static Pricebook2 book(String name) {
        return [SELECT Id FROM Pricebook2 WHERE Name = :name LIMIT 1];
    }

    private static Id productId(String prefix) {
        return [SELECT Id FROM Product2 WHERE Name LIKE :(prefix + '%') LIMIT 1].Id;
    }

    private static String key(Id pricebookId, Id productId) {
        return String.valueOf(pricebookId) + ':' + String.valueOf(productId);
    }

    private static PricebookEntry entryFor(Id pricebookId, Id productId) {
        List<PricebookEntry> entries = [SELECT Id, UnitPrice, IsActive FROM PricebookEntry
                                        WHERE Pricebook2Id = :pricebookId AND Product2Id = :productId AND CurrencyIsoCode = :ISO];
        return entries.isEmpty() ? null : entries[0];
    }

    // ------------------------------------------------------------------ tests

    @IsTest
    static void listsOnlyActiveEntityPricebooks() {
        List<Pricebook2> books;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            books = PricebookSyncController_CC.getPricebooks(quote().Id);
        }
        Test.stopTest();

        Assert.areEqual(1, books.size(), 'Only the Entity\'s own active price book is offered');
        Assert.areEqual(ENTITY_BOOK, books[0].Name);
    }

    @IsTest
    static void previewClassifiesEveryQuoteLine() {
        Id entityBookId = book(ENTITY_BOOK).Id;
        Id otherBookId = book(OTHER_BOOK).Id;

        List<PricebookSyncController_CC.Row> rows;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            rows = PricebookSyncController_CC.getPreview(quote().Id, new List<Id>{ entityBookId, otherBookId });
        }
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'One row per Quote product for the Entity price book only');
        Map<Id, PricebookSyncController_CC.Row> byProduct = new Map<Id, PricebookSyncController_CC.Row>();
        for (PricebookSyncController_CC.Row r : rows) {
            Assert.areEqual(ENTITY_BOOK, r.pricebookName);
            Assert.areEqual(ISO, r.currencyIsoCode);
            Assert.isTrue(r.productUrl.startsWith('/lightning/r/Product2/'));
            byProduct.put((Id) r.key.substringAfter(':'), r);
        }

        PricebookSyncController_CC.Row same = byProduct.get(productId('ZZPBS Same'));
        Assert.areEqual('NO_CHANGE', same.action);
        Assert.isTrue(same.currentPrice == 10, 'Expected 10');

        PricebookSyncController_CC.Row changed = byProduct.get(productId('ZZPBS Changed'));
        Assert.areEqual('UPDATE', changed.action);
        Assert.isTrue(changed.currentPrice == 20, 'Expected 20');
        Assert.isTrue(changed.newPrice == 25, 'Expected 25');

        PricebookSyncController_CC.Row fresh = byProduct.get(productId('ZZPBS New'));
        Assert.areEqual('CREATE', fresh.action);
        Assert.isNull(fresh.currentPrice);
        Assert.isTrue(fresh.newPrice == 35, 'Expected 35');
    }

    @IsTest
    static void saveCreatesAndUpdatesSelectedRowsOnly() {
        exposeStandardPricebook();
        Id entityBookId = book(ENTITY_BOOK).Id;
        Id otherBookId = book(OTHER_BOOK).Id;
        Id sameId = productId('ZZPBS Same');
        Id changedId = productId('ZZPBS Changed');
        Id freshId = productId('ZZPBS New');
        Id notOnQuoteId = productId('ZZPBS Not On Quote');

        List<String> selected = new List<String>{
            key(entityBookId, sameId),       // no change -> not saved
            key(entityBookId, changedId),    // UPDATE
            key(entityBookId, freshId),      // CREATE
            key(entityBookId, notOnQuoteId), // product not on the Quote -> ignored
            key(otherBookId, freshId),       // price book of another Entity -> ignored
            '',                              // blank -> ignored
            'not-a-key'                      // malformed -> ignored
        };

        Integer saved;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            saved = PricebookSyncController_CC.save(quote().Id, new List<Id>{ entityBookId, otherBookId }, selected);
        }
        Test.stopTest();

        Assert.areEqual(2, saved, 'Only the CREATE and UPDATE rows are saved');
        Assert.isTrue(entryFor(entityBookId, changedId).UnitPrice == 25, 'Changed price is updated');
        PricebookEntry created = entryFor(entityBookId, freshId);
        Assert.isNotNull(created, 'Missing product is added to the Entity price book');
        Assert.isTrue(created.UnitPrice == 35, 'Expected 35');
        Assert.isTrue(created.IsActive);
        Assert.isTrue(entryFor(entityBookId, sameId).UnitPrice == 10, 'Unchanged entry is left as is');
        Assert.isNull(entryFor(entityBookId, notOnQuoteId), 'Products not on the Quote are never added');
        Assert.isNull(entryFor(otherBookId, freshId), 'Price books of other Entities are never changed');
    }

    @IsTest
    static void saveReactivatesInactiveEntryAtSamePrice() {
        exposeStandardPricebook();
        Id entityBookId = book(ENTITY_BOOK).Id;
        Id sameId = productId('ZZPBS Same');
        PricebookEntry existing = entryFor(entityBookId, sameId);
        update new PricebookEntry(Id = existing.Id, IsActive = false);

        Integer saved;
        Test.startTest();
        System.runAs(TestAdminAccess_CC.admin()) {
            saved = PricebookSyncController_CC.save(quote().Id, new List<Id>{ entityBookId },
                new List<String>{ key(entityBookId, sameId) });
        }
        Test.stopTest();

        Assert.areEqual(1, saved, 'An inactive entry is re-activated');
        Assert.isTrue(entryFor(entityBookId, sameId).IsActive);
    }

    @IsTest
    static void saveIgnoresEmptyOrUnlistedSelections() {
        Id quoteId = quote().Id;
        Id entityBookId = book(ENTITY_BOOK).Id;
        Id otherBookId = book(OTHER_BOOK).Id;
        Id freshId = productId('ZZPBS New');

        Test.startTest();
        Integer nullKeys = PricebookSyncController_CC.save(quoteId, new List<Id>{ entityBookId }, null);
        Integer noKeys = PricebookSyncController_CC.save(quoteId, new List<Id>{ entityBookId }, new List<String>());
        // The selected price book was not part of the reviewed price books.
        Integer unlisted = PricebookSyncController_CC.save(quoteId, new List<Id>{ otherBookId },
            new List<String>{ key(entityBookId, freshId) });
        Integer noBooks = PricebookSyncController_CC.save(quoteId, null, new List<String>{ key(entityBookId, freshId) });
        Test.stopTest();

        Assert.areEqual(0, nullKeys);
        Assert.areEqual(0, noKeys);
        Assert.areEqual(0, unlisted);
        Assert.areEqual(0, noBooks);
        Assert.isNull(entryFor(entityBookId, freshId), 'Nothing is saved');
    }
}