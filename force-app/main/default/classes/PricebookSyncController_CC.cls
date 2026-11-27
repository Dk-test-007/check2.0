public with sharing class PricebookSyncController_CC {

    public class Row {
        @AuraEnabled public String key;
        @AuraEnabled public String action; // CREATE | UPDATE | NO_CHANGE
        @AuraEnabled public String pricebookName;
        @AuraEnabled public String productName;
        @AuraEnabled public String productUrl;
        @AuraEnabled public String currencyIsoCode;
        @AuraEnabled public Decimal currentPrice;
        @AuraEnabled public Decimal newPrice;
        PricebookEntry entry; // record to save; null when nothing changes
    }

    @AuraEnabled(cacheable=true)
    public static List<Pricebook2> getPricebooks(Id quoteId) {
        Id accountId = [SELECT AccountId FROM Quote WHERE Id = :quoteId WITH USER_MODE].AccountId;
        return [SELECT Id, Name FROM Pricebook2
                WHERE Entity__c = :accountId AND IsActive = true
                WITH USER_MODE ORDER BY Name];
    }

    @AuraEnabled
    public static List<Row> getPreview(Id quoteId, List<Id> pricebookIds) {
        return buildRows(quoteId, pricebookIds);
    }

    /** Saves only the CREATE and UPDATE rows explicitly selected in the review tables. */
    @AuraEnabled
    public static Integer save(Id quoteId, List<Id> pricebookIds, List<String> selectedRowKeys) {
        if (selectedRowKeys == null || selectedRowKeys.isEmpty()) {
            return 0;
        }

        Id accountId = [SELECT AccountId FROM Quote WHERE Id = :quoteId WITH USER_MODE].AccountId;
        Set<Id> selectedPricebookIds = new Set<Id>();
        Set<Id> selectedProductIds = new Set<Id>();
        Set<String> selectedKeys = new Set<String>();

        for (String selectedKey : selectedRowKeys) {
            if (String.isBlank(selectedKey)) {
                continue;
            }

            List<String> keyParts = selectedKey.split(':');
            if (keyParts.size() != 2) {
                continue;
            }

            Id selectedPricebookId = (Id) keyParts[0];
            Id selectedProductId = (Id) keyParts[1];

            if (pricebookIds != null && pricebookIds.contains(selectedPricebookId)) {
                selectedPricebookIds.add(selectedPricebookId);
                selectedProductIds.add(selectedProductId);
                selectedKeys.add(selectedKey);
            }
        }

        if (selectedKeys.isEmpty()) {
            return 0;
        }

        Map<Id, Pricebook2> validPricebooks = new Map<Id, Pricebook2>([
            SELECT Id, Name
            FROM Pricebook2
            WHERE Id IN :selectedPricebookIds
                AND Entity__c = :accountId
                AND IsActive = true
            WITH USER_MODE
        ]);

        Map<Id, QuoteLineItem> selectedQuoteLines = new Map<Id, QuoteLineItem>();
        Set<String> selectedCurrencies = new Set<String>();
        for (QuoteLineItem qli : [
            SELECT Product2Id, UnitPrice, CurrencyIsoCode
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
                AND Product2Id IN :selectedProductIds
            WITH USER_MODE
        ]) {
            selectedQuoteLines.put(qli.Product2Id, qli);
            selectedCurrencies.add(qli.CurrencyIsoCode);
        }

        Map<String, PricebookEntry> existingEntries = new Map<String, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, Pricebook2Id, Product2Id, UnitPrice, IsActive, CurrencyIsoCode
            FROM PricebookEntry
            WHERE Pricebook2Id IN :validPricebooks.keySet()
                AND Product2Id IN :selectedProductIds
                AND CurrencyIsoCode IN :selectedCurrencies
            WITH USER_MODE
        ]) {
            existingEntries.put(
                String.valueOf(pbe.Pricebook2Id) + ':' + String.valueOf(pbe.Product2Id) + ':' + pbe.CurrencyIsoCode,
                pbe
            );
        }

        Id standardPricebookId = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = true
            LIMIT 1
        ].Id;

        Map<String, PricebookEntry> standardEntries = new Map<String, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, CurrencyIsoCode
            FROM PricebookEntry
            WHERE Pricebook2Id = :standardPricebookId
                AND Product2Id IN :selectedProductIds
                AND CurrencyIsoCode IN :selectedCurrencies
            WITH USER_MODE
        ]) {
            standardEntries.put(
                String.valueOf(pbe.Product2Id) + ':' + pbe.CurrencyIsoCode,
                pbe
            );
        }

        List<PricebookEntry> standardEntriesToInsert = new List<PricebookEntry>();
        for (Id productId : selectedProductIds) {
            QuoteLineItem qli = selectedQuoteLines.get(productId);

            if (qli == null) {
                continue;
            }

            String standardEntryKey = String.valueOf(productId) + ':' + qli.CurrencyIsoCode;

            if (!standardEntries.containsKey(standardEntryKey)) {
                standardEntriesToInsert.add(new PricebookEntry(
                    Pricebook2Id = standardPricebookId,
                    Product2Id = productId,
                    UnitPrice = qli.UnitPrice,
                    CurrencyIsoCode = qli.CurrencyIsoCode,
                    IsActive = true
                ));
            }
        }

        List<PricebookEntry> changes = new List<PricebookEntry>();
        for (String selectedKey : selectedKeys) {
            List<String> keyParts = selectedKey.split(':');
            Id selectedPricebookId = (Id) keyParts[0];
            Id selectedProductId = (Id) keyParts[1];

            if (!validPricebooks.containsKey(selectedPricebookId)
                || !selectedQuoteLines.containsKey(selectedProductId)) {
                continue;
            }

            QuoteLineItem qli = selectedQuoteLines.get(selectedProductId);
            PricebookEntry existingEntry = existingEntries.get(selectedKey + ':' + qli.CurrencyIsoCode);

            if (existingEntry == null) {
                changes.add(new PricebookEntry(
                    Pricebook2Id = selectedPricebookId,
                    Product2Id = selectedProductId,
                    UnitPrice = qli.UnitPrice,
                    CurrencyIsoCode = qli.CurrencyIsoCode,
                    IsActive = true
                ));
            } else if (existingEntry.UnitPrice != qli.UnitPrice || !existingEntry.IsActive) {
                changes.add(new PricebookEntry(
                    Id = existingEntry.Id,
                    UnitPrice = qli.UnitPrice,
                    IsActive = true
                ));
            }
        }

        try {
            if (!standardEntriesToInsert.isEmpty()) {
                insert as user standardEntriesToInsert;
            }

            if (!changes.isEmpty()) {
                upsert as user changes;
            }
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        return changes.size();
    }

    private static List<Row> buildRows(Id quoteId, List<Id> pricebookIds) {
        Id accountId = [SELECT AccountId FROM Quote WHERE Id = :quoteId WITH USER_MODE].AccountId;

        Map<Id, QuoteLineItem> lineByProduct = new Map<Id, QuoteLineItem>();
        Set<String> currencies = new Set<String>();
        for (QuoteLineItem qli : [SELECT Product2Id, Product2.Name, UnitPrice, CurrencyIsoCode FROM QuoteLineItem
                                  WHERE QuoteId = :quoteId WITH USER_MODE ORDER BY SortOrder]) {
            lineByProduct.put(qli.Product2Id, qli);
            currencies.add(qli.CurrencyIsoCode);
        }

        Map<String, PricebookEntry> existing = new Map<String, PricebookEntry>();
        for (PricebookEntry pbe : [SELECT Pricebook2Id, Product2Id, UnitPrice, IsActive, CurrencyIsoCode FROM PricebookEntry
                                   WHERE Pricebook2Id IN :pricebookIds AND Product2Id IN :lineByProduct.keySet()
                                   AND CurrencyIsoCode IN :currencies
                                   WITH USER_MODE]) {
            existing.put(String.valueOf(pbe.Pricebook2Id) + ':' + String.valueOf(pbe.Product2Id) + ':' + pbe.CurrencyIsoCode, pbe);
        }

        List<Row> rows = new List<Row>();
        for (Pricebook2 pb : [SELECT Id, Name FROM Pricebook2
                              WHERE Id IN :pricebookIds AND Entity__c = :accountId AND IsActive = true
                              WITH USER_MODE ORDER BY Name]) {
            for (QuoteLineItem qli : lineByProduct.values()) {
                Row r = new Row();
                r.key = String.valueOf(pb.Id) + ':' + String.valueOf(qli.Product2Id);
                r.pricebookName = pb.Name;
                r.productName = qli.Product2.Name;
                r.productUrl = '/lightning/r/Product2/' + qli.Product2Id + '/view';
                r.currencyIsoCode = qli.CurrencyIsoCode;
                r.newPrice = qli.UnitPrice;

                PricebookEntry pbe = existing.get(r.key + ':' + qli.CurrencyIsoCode);
                if (pbe == null) {
                    r.action = 'CREATE';
                    r.entry = new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = qli.Product2Id,
                                                 UnitPrice = qli.UnitPrice, CurrencyIsoCode = qli.CurrencyIsoCode, IsActive = true);
                } else if (pbe.UnitPrice == qli.UnitPrice && pbe.IsActive) {
                    r.action = 'NO_CHANGE';
                    r.currentPrice = pbe.UnitPrice;
                } else {
                    r.action = 'UPDATE';
                    r.currentPrice = pbe.UnitPrice;
                    r.entry = new PricebookEntry(Id = pbe.Id, UnitPrice = qli.UnitPrice, IsActive = true);
                }
                rows.add(r);
            }
        }
        return rows;
    }
}