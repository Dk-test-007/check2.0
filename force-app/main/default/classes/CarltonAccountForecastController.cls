public with sharing class CarltonAccountForecastController {
    private static String accountCurrency(Id accountId) {
        Account account = [SELECT CurrencyIsoCode FROM Account WHERE Id = :accountId LIMIT 1];
        if (String.isNotBlank(account.CurrencyIsoCode)) return account.CurrencyIsoCode;
        User viewer = [SELECT DefaultCurrencyIsoCode FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        return viewer.DefaultCurrencyIsoCode;
    }

    private static Id indicativeRevenueProductId() {
        List<Product2> products = [SELECT Id FROM Product2
            WHERE ProductCode = 'CARLTON-INDICATIVE-REVENUE' AND IsActive = true LIMIT 1];
        if (products.isEmpty()) throw new AuraHandledException('The indicative revenue dimension is unavailable.');
        return products[0].Id;
    }

    public class ForecastRow {
        @AuraEnabled public String key { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public Date monthStart { get; set; }
        @AuraEnabled public String monthLabel { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public Decimal agreementQuantity { get; set; }
        @AuraEnabled public Decimal agreementRevenue { get; set; }
        @AuraEnabled public Decimal actualQuantity { get; set; }
        @AuraEnabled public Decimal actualRevenue { get; set; }
        @AuraEnabled public Decimal forecastQuantity { get; set; }
        @AuraEnabled public Decimal forecastRevenue { get; set; }
        @AuraEnabled public Boolean isIndicative { get; set; }
        @AuraEnabled public Boolean isValueMode { get; set; }
        @AuraEnabled public Boolean isTotal { get; set; }
        @AuraEnabled public String rowClass { get; set; }
        @AuraEnabled public List<ForecastSource> sources { get; set; }
    }

    public class ForecastSource {
        @AuraEnabled public Id scheduleId { get; set; }
        @AuraEnabled public Id agreementId { get; set; }
        @AuraEnabled public String agreementName { get; set; }
        @AuraEnabled public Id opportunityId { get; set; }
        @AuraEnabled public String opportunityName { get; set; }
        @AuraEnabled public Decimal agreementQuantity { get; set; }
        @AuraEnabled public Decimal agreementRevenue { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean isValueMode { get; set; }
        @AuraEnabled public Boolean isAgreement { get; set; }
        @AuraEnabled public String businessType { get; set; }
    }

    public class ForecastOverview {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public String accountCurrencyCode { get; set; }
        @AuraEnabled public String storedCurrencyCode { get; set; }
        @AuraEnabled public List<SourceCurrencySummary> sourceAgreementCurrencies { get; set; }
        @AuraEnabled public Boolean forecastFactCurrencyConsistent { get; set; }
        @AuraEnabled public Id forecastUseId { get; set; }
        @AuraEnabled public List<ForecastRow> rows { get; set; }
    }

    public class SourceCurrencySummary {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Integer agreementCount { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static ForecastOverview getOverview(Id accountId) {
        ForecastOverview result = new ForecastOverview();
        result.rows = new List<ForecastRow>();
        if (accountId == null) return result;
        result.accountCurrencyCode = accountCurrency(accountId);
        result.currencyCode = result.accountCurrencyCode;
        result.sourceAgreementCurrencies = new List<SourceCurrencySummary>();
        result.forecastFactCurrencyConsistent = true;

        List<AdvAccountForecastSet> sets = [
            SELECT Id FROM AdvAccountForecastSet
            WHERE DeveloperName = 'Carlton_Account_Product_Demand' AND Status = 'Active'
            LIMIT 1
        ];
        if (sets.isEmpty()) return result;
        Id setId = sets[0].Id;

        List<AdvAcctForecastSetUse> uses = [
            SELECT Id, CurrencyIsoCode FROM AdvAcctForecastSetUse
            WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :setId
            AND Status = 'Active' LIMIT 1
        ];
        if (uses.isEmpty()) return result;
        result.forecastUseId = uses[0].Id;
        result.storedCurrencyCode = uses[0].CurrencyIsoCode;
        result.currencyCode = result.storedCurrencyCode;
        Id useId = uses[0].Id;
        Date startMonth = Date.today().toStartOfMonth();
        Id indicativeProductId = indicativeRevenueProductId();

        List<AdvAccountForecastFact> facts = [
            SELECT Id, CurrencyIsoCode, PeriodStartDate, ProductId, SalesAgreementQuantity,
                SalesAgreementRevenue, OrderQuantity, OrderRevenue,
                ForecastedQuantity, ForecastedRevenue
            FROM AdvAccountForecastFact
            WHERE AccountId = :accountId AND AdvAcctForecastSetUseId = :useId
                AND Status = 'Active' AND PeriodStartDate >= :startMonth
            ORDER BY PeriodStartDate, ProductId
            LIMIT 2000
        ];
        Set<Id> productIds = new Set<Id>();
        for (AdvAccountForecastFact fact : facts) {
            if (fact.ProductId != null) productIds.add(fact.ProductId);
            if (fact.CurrencyIsoCode != result.storedCurrencyCode) result.forecastFactCurrencyConsistent = false;
        }
        Map<Id, Product2> products = new Map<Id, Product2>([
            SELECT Id, Name FROM Product2 WHERE Id IN :productIds
        ]);
        Map<String, List<ForecastSource>> sourcesByProductMonth = new Map<String, List<ForecastSource>>();
        Map<String, Set<Id>> agreementIdsByCurrency = new Map<String, Set<Id>>();
        if (!productIds.isEmpty()) {
            for (SalesAgreementProductSchedule schedule : [
                SELECT Id, CurrencyIsoCode, StartDate, ForecastedQuantityValue, ForecastedAmount, SalesPrice, Carlton_Value_Mode_CC__c,
                    SalesAgreementProduct.ProductId,
                    SalesAgreementProduct.IsQuantityInDecimals,
                    SalesAgreementProduct.SalesAgreementId, SalesAgreementProduct.SalesAgreement.Name,
                    SalesAgreementProduct.SalesAgreement.Source_Opportunity_CC__c,
                    SalesAgreementProduct.SalesAgreement.Source_Opportunity_CC__r.Name
                FROM SalesAgreementProductSchedule
                WHERE SalesAgreementProduct.SalesAgreement.AccountId = :accountId
                    AND SalesAgreementProduct.ProductId IN :productIds
                ORDER BY StartDate LIMIT 10000
            ]) {
                String sourceKey = String.valueOf(schedule.SalesAgreementProduct.ProductId)
                    + ':' + String.valueOf(schedule.StartDate.toStartOfMonth());
                if (!sourcesByProductMonth.containsKey(sourceKey)) {
                    sourcesByProductMonth.put(sourceKey, new List<ForecastSource>());
                }
                ForecastSource source = new ForecastSource();
                source.scheduleId = schedule.Id;
                source.agreementId = schedule.SalesAgreementProduct.SalesAgreementId;
                source.agreementName = schedule.SalesAgreementProduct.SalesAgreement.Name;
                source.opportunityId = schedule.SalesAgreementProduct.SalesAgreement.Source_Opportunity_CC__c;
                source.opportunityName = schedule.SalesAgreementProduct.SalesAgreement.Source_Opportunity_CC__r == null
                    ? null : schedule.SalesAgreementProduct.SalesAgreement.Source_Opportunity_CC__r.Name;
                source.isValueMode = schedule.Carlton_Value_Mode_CC__c;
                source.isAgreement = true;
                source.currencyCode = schedule.CurrencyIsoCode;
                source.businessType = source.opportunityId == null ? 'Existing business' : 'New business';
                source.agreementQuantity = source.isValueMode ? 0 : schedule.ForecastedQuantityValue;
                source.agreementRevenue = schedule.ForecastedAmount;
                sourcesByProductMonth.get(sourceKey).add(source);
                if (schedule.StartDate >= startMonth) {
                    if (!agreementIdsByCurrency.containsKey(schedule.CurrencyIsoCode))
                        agreementIdsByCurrency.put(schedule.CurrencyIsoCode, new Set<Id>());
                    agreementIdsByCurrency.get(schedule.CurrencyIsoCode)
                        .add(schedule.SalesAgreementProduct.SalesAgreementId);
                }
            }
        }
        List<String> sourceCurrencyCodes = new List<String>(agreementIdsByCurrency.keySet());
        sourceCurrencyCodes.sort();
        for (String code : sourceCurrencyCodes) {
            SourceCurrencySummary summary = new SourceCurrencySummary();
            summary.currencyCode = code;
            summary.agreementCount = agreementIdsByCurrency.get(code).size();
            result.sourceAgreementCurrencies.add(summary);
        }
        // The new Closed Won path writes a forecast directly, without inventing agreement schedules.
        for (Opportunity sourceOpp : [SELECT Id, Name, Carlton_Monthly_Forecast_Plan_CC__c
            FROM Opportunity WHERE AccountId = :accountId AND IsWon = true ORDER BY CreatedDate DESC LIMIT 200]) {
            if (String.isBlank(sourceOpp.Carlton_Monthly_Forecast_Plan_CC__c)) continue;
            CarltonWinForecastService_CC.SavedPlan saved = (CarltonWinForecastService_CC.SavedPlan)
                JSON.deserialize(sourceOpp.Carlton_Monthly_Forecast_Plan_CC__c, CarltonWinForecastService_CC.SavedPlan.class);
            if (saved == null || saved.lines == null) continue;
            for (CarltonWinForecastService_CC.SavedLine line : saved.lines) {
                if (!productIds.contains(line.productId)) continue;
                for (Integer i = 0; i < saved.termMonths; i++) {
                    Date month = saved.startMonth.addMonths(i);
                    if (month < startMonth || line.monthlyRevenueGBP[i] == 0) continue;
                    String key = String.valueOf(line.productId) + ':' + String.valueOf(month);
                    if (!sourcesByProductMonth.containsKey(key)) sourcesByProductMonth.put(key, new List<ForecastSource>());
                    ForecastSource source = new ForecastSource();
                    source.opportunityId = sourceOpp.Id;
                    source.opportunityName = sourceOpp.Name;
                    source.isAgreement = false;
                    source.currencyCode = 'GBP';
                    source.businessType = saved.businessType;
                    source.isValueMode = line.mode == 'Value';
                    source.agreementQuantity = source.isValueMode ? 0 : line.monthlyValues[i];
                    source.agreementRevenue = line.monthlyRevenueGBP[i];
                    sourcesByProductMonth.get(key).add(source);
                }
            }
        }

        Map<Date, ForecastRow> totals = new Map<Date, ForecastRow>();
        Date previousMonth;
        for (AdvAccountForecastFact fact : facts) {
            Decimal quantity = fact.ForecastedQuantity == null ? 0 : fact.ForecastedQuantity;
            Decimal revenue = fact.ForecastedRevenue == null ? 0 : fact.ForecastedRevenue;
            Date month = fact.PeriodStartDate;
            if (previousMonth != null && month != previousMonth) {
                result.rows.add(totals.get(previousMonth));
            }
            if (!totals.containsKey(month)) {
                ForecastRow total = new ForecastRow();
                total.key = 'total-' + String.valueOf(month);
                total.monthStart = month;
                total.monthLabel = DateTime.newInstance(month, Time.newInstance(12, 0, 0, 0)).format('MMMM yyyy');
                total.productName = 'ACCOUNT TOTAL';
                total.agreementQuantity = 0;
                total.agreementRevenue = 0;
                total.actualQuantity = 0;
                total.actualRevenue = 0;
                total.forecastQuantity = 0;
                total.forecastRevenue = 0;
                total.isTotal = true;
                total.rowClass = 'total';
                totals.put(month, total);
            }
            ForecastRow row = new ForecastRow();
            row.key = String.valueOf(fact.Id);
            row.productId = fact.ProductId;
            row.isIndicative = fact.ProductId == indicativeProductId;
            List<ForecastSource> contributing = sourcesByProductMonth.get(String.valueOf(fact.ProductId) + ':' + String.valueOf(month));
            row.isValueMode = contributing != null && !contributing.isEmpty();
            if (row.isValueMode) for (ForecastSource source : contributing) if (!source.isValueMode) row.isValueMode = false;
            row.monthStart = month;
            row.monthLabel = totals.get(month).monthLabel;
            row.productName = products.containsKey(fact.ProductId) ? products.get(fact.ProductId).Name : 'Unspecified product';
            row.agreementQuantity = row.isValueMode ? 0 : (fact.SalesAgreementQuantity == null ? 0 : fact.SalesAgreementQuantity);
            row.agreementRevenue = fact.SalesAgreementRevenue == null ? 0 : fact.SalesAgreementRevenue;
            row.actualQuantity = fact.OrderQuantity == null ? 0 : fact.OrderQuantity;
            row.actualRevenue = fact.OrderRevenue == null ? 0 : fact.OrderRevenue;
            row.forecastQuantity = row.isValueMode ? 0 : quantity;
            row.forecastRevenue = revenue;
            row.isTotal = false;
            row.rowClass = '';
            row.sources = sourcesByProductMonth.get(String.valueOf(fact.ProductId) + ':' + String.valueOf(month));
            result.rows.add(row);
            ForecastRow total = totals.get(month);
            total.agreementQuantity += row.agreementQuantity;
            total.agreementRevenue += row.agreementRevenue;
            total.actualQuantity += row.actualQuantity;
            total.actualRevenue += row.actualRevenue;
            total.forecastQuantity += row.forecastQuantity;
            total.forecastRevenue += row.forecastRevenue;
            previousMonth = month;
        }
        if (previousMonth != null) result.rows.add(totals.get(previousMonth));
        return result;
    }

    /** Add one native forecast dimension member for unallocated revenue to the DPE-backed product set. */
    @AuraEnabled
    public static Integer ensureUnifiedForecast(Id accountId) {
        if (accountId == null) throw new AuraHandledException('Select an account.');
        Id indicativeId = indicativeRevenueProductId();
        List<AdvAccountForecastSet> sets = [SELECT Id, DeveloperName FROM AdvAccountForecastSet
            WHERE DeveloperName IN ('Carlton_Account_Product_Demand', 'Carlton_Account_Revenue_Only')
                AND Status = 'Active'];
        Map<String, Id> setIds = new Map<String, Id>();
        for (AdvAccountForecastSet forecastSet : sets) setIds.put(forecastSet.DeveloperName, forecastSet.Id);
        if (!setIds.containsKey('Carlton_Account_Product_Demand')) {
            throw new AuraHandledException('The product DPE forecast set is unavailable.');
        }
        Id productSetId = setIds.get('Carlton_Account_Product_Demand');
        List<AdvAcctForecastSetUse> uses = [SELECT Id, CurrencyIsoCode FROM AdvAcctForecastSetUse
            WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :productSetId
                AND Status = 'Active' LIMIT 1];
        AdvAcctForecastSetUse productUse;
        if (uses.isEmpty()) {
            Account account = [SELECT Name FROM Account WHERE Id = :accountId LIMIT 1];
            productUse = new AdvAcctForecastSetUse(Name = account.Name.left(60) + ' forecast',
                AdvAccountForecastSetId = productSetId, ForecastContextId = accountId,
                CurrencyIsoCode = 'GBP', Status = 'Active');
            Database.insert(productUse, AccessLevel.SYSTEM_MODE);
        } else productUse = uses[0];
        Map<Id, AdvAccountForecastFact> existing = new Map<Id, AdvAccountForecastFact>();
        for (AdvAccountForecastFact fact : [SELECT Id, PeriodId FROM AdvAccountForecastFact
            WHERE AdvAcctForecastSetUseId = :productUse.Id AND AccountId = :accountId
                AND ProductId = :indicativeId AND Status = 'Active' LIMIT 1000]) {
            existing.put(fact.PeriodId, fact);
        }
        Map<Id, Decimal> legacyIndicative = new Map<Id, Decimal>();
        Id revenueSetId = setIds.get('Carlton_Account_Revenue_Only');
        if (revenueSetId != null) {
            List<AdvAcctForecastSetUse> revenueUses = [SELECT Id FROM AdvAcctForecastSetUse
                WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :revenueSetId
                    AND Status = 'Active' LIMIT 1];
            if (!revenueUses.isEmpty()) {
                for (AdvAccountForecastFact fact : [SELECT PeriodId, Carlton_Account_Adjustment_Revenue_CC__c
                    FROM AdvAccountForecastFact WHERE AdvAcctForecastSetUseId = :revenueUses[0].Id
                        AND AccountId = :accountId AND ProductId = :indicativeId
                        AND Status = 'Active' LIMIT 1000]) {
                    legacyIndicative.put(fact.PeriodId, fact.Carlton_Account_Adjustment_Revenue_CC__c == null
                        ? 0 : fact.Carlton_Account_Adjustment_Revenue_CC__c);
                }
            }
        }
        Date firstMonth = Date.today().toStartOfMonth();
        Date afterHorizon = firstMonth.addMonths(18);
        List<AdvAccountForecastFact> newFacts = new List<AdvAccountForecastFact>();
        for (Period period : [SELECT Id, StartDate FROM Period WHERE Type = 'Month'
            AND StartDate >= :firstMonth AND StartDate < :afterHorizon ORDER BY StartDate LIMIT 18]) {
            if (existing.containsKey(period.Id)) continue;
            Decimal amount = legacyIndicative.containsKey(period.Id) ? legacyIndicative.get(period.Id) : 0;
            newFacts.add(new AdvAccountForecastFact(
                Name = 'Carlton indicative revenue ' + String.valueOf(period.StartDate),
                AccountId = accountId, AdvAcctForecastSetUseId = productUse.Id,
                PeriodId = period.Id, PeriodStartDate = period.StartDate, ProductId = indicativeId,
                CurrencyIsoCode = productUse.CurrencyIsoCode, Status = 'Active',
                SalesAgreementQuantity = 0, SalesAgreementRevenue = 0,
                OrderQuantity = 0, OrderRevenue = 0,
                OpportunityQuantity = 0, OpportunityRevenue = 0,
                Carlton_Account_Adjustment_Quantity_CC__c = 0,
                Carlton_Account_Adjustment_Revenue_CC__c = amount,
                ForecastedQuantity = 0, ForecastedRevenue = amount));
        }
        if (!newFacts.isEmpty()) Database.insert(newFacts, AccessLevel.SYSTEM_MODE);
        return newFacts.size();
    }

    public class ForecastEdit {
        @AuraEnabled public Id factId { get; set; }
        @AuraEnabled public Decimal forecastQuantity { get; set; }
        @AuraEnabled public Decimal forecastRevenue { get; set; }
    }

    public class ProductOption {
        @AuraEnabled public Id value { get; set; }
        @AuraEnabled public String label { get; set; }
    }

    /** Existing-business products can be placed on the Account forecast without an Opportunity. */
    @AuraEnabled(cacheable=true)
    public static List<ProductOption> getExistingProductOptions(Id accountId) {
        List<ProductOption> options = new List<ProductOption>();
        if (accountId == null) return options;
        Id indicativeId = indicativeRevenueProductId();
        Set<Id> seen = new Set<Id>();
        for (PricebookEntry entry : [SELECT Product2Id, Product2.Name FROM PricebookEntry
            WHERE Pricebook2.IsStandard = true AND IsActive = true AND Product2.IsActive = true
                AND CurrencyIsoCode = 'GBP' ORDER BY Product2.Name LIMIT 500]) {
            if (entry.Product2Id == indicativeId || !seen.add(entry.Product2Id)) continue;
            ProductOption option = new ProductOption();
            option.value = entry.Product2Id;
            option.label = entry.Product2.Name;
            options.add(option);
        }
        return options;
    }

    @AuraEnabled
    public static Integer addExistingProduct(Id accountId, Id productId) {
        if (accountId == null || productId == null) throw new AuraHandledException('Choose an Account and price-book product.');
        List<PricebookEntry> valid = [SELECT Id FROM PricebookEntry WHERE Product2Id = :productId
            AND Pricebook2.IsStandard = true AND IsActive = true AND Product2.IsActive = true
            AND CurrencyIsoCode = 'GBP' LIMIT 1];
        if (valid.isEmpty() || productId == indicativeRevenueProductId()) {
            throw new AuraHandledException('Choose an active standard price-book product.');
        }
        ensureUnifiedForecast(accountId);
        Id setId = [SELECT Id FROM AdvAccountForecastSet WHERE DeveloperName = 'Carlton_Account_Product_Demand'
            AND Status = 'Active' LIMIT 1].Id;
        AdvAcctForecastSetUse useRow = [SELECT Id, CurrencyIsoCode FROM AdvAcctForecastSetUse
            WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :setId
            AND Status = 'Active' LIMIT 1];
        Date firstMonth = Date.today().toStartOfMonth();
        Date afterHorizon = firstMonth.addMonths(18);
        Set<Id> existingPeriods = new Set<Id>();
        for (AdvAccountForecastFact fact : [SELECT PeriodId FROM AdvAccountForecastFact
            WHERE AccountId = :accountId AND AdvAcctForecastSetUseId = :useRow.Id
            AND ProductId = :productId AND Status = 'Active']) existingPeriods.add(fact.PeriodId);
        List<AdvAccountForecastFact> additions = new List<AdvAccountForecastFact>();
        for (Period period : [SELECT Id, StartDate FROM Period WHERE Type = 'Month'
            AND StartDate >= :firstMonth AND StartDate < :afterHorizon ORDER BY StartDate LIMIT 18]) {
            if (existingPeriods.contains(period.Id)) continue;
            additions.add(new AdvAccountForecastFact(
                Name = 'Carlton existing business ' + String.valueOf(period.StartDate),
                AccountId = accountId, AdvAcctForecastSetUseId = useRow.Id,
                ProductId = productId, PeriodId = period.Id, PeriodStartDate = period.StartDate,
                CurrencyIsoCode = useRow.CurrencyIsoCode, Status = 'Active',
                OrderQuantity = 0, OrderRevenue = 0, SalesAgreementQuantity = 0, SalesAgreementRevenue = 0,
                OpportunityQuantity = 0, OpportunityRevenue = 0,
                Carlton_Account_Adjustment_Quantity_CC__c = 0,
                Carlton_Account_Adjustment_Revenue_CC__c = 0,
                ForecastedQuantity = 0, ForecastedRevenue = 0));
        }
        if (!additions.isEmpty()) insert additions;
        return additions.size();
    }

    /** Save many months in one transaction. Only tracked forecast adjustments are changed. */
    @AuraEnabled
    public static Integer saveForecastEdits(Id accountId, List<ForecastEdit> edits) {
        if (accountId == null || edits == null || edits.isEmpty() || edits.size() > 500) {
            throw new AuraHandledException('Select an account and up to 500 forecast months.');
        }
        Set<Id> factIds = new Set<Id>();
        Map<Id, ForecastEdit> requested = new Map<Id, ForecastEdit>();
        for (ForecastEdit edit : edits) {
            if (edit == null || edit.factId == null || requested.containsKey(edit.factId)) {
                throw new AuraHandledException('Each forecast month must be selected once.');
            }
            factIds.add(edit.factId);
            requested.put(edit.factId, edit);
        }
        Id indicativeId = indicativeRevenueProductId();
        AdvAccountForecastSet forecastSet = [SELECT Id FROM AdvAccountForecastSet
            WHERE DeveloperName = 'Carlton_Account_Product_Demand' AND Status = 'Active' LIMIT 1];
        List<AdvAcctForecastSetUse> uses = [SELECT Id FROM AdvAcctForecastSetUse
            WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :forecastSet.Id
                AND Status = 'Active' LIMIT 1];
        if (uses.isEmpty()) throw new AuraHandledException('Start the account forecast first.');
        Id useId = uses[0].Id;
        List<AdvAccountForecastFact> facts = [SELECT Id, ProductId, OrderQuantity, OrderRevenue,
            SalesAgreementQuantity, SalesAgreementRevenue, OpportunityQuantity, OpportunityRevenue,
            ForecastedQuantity, ForecastedRevenue FROM AdvAccountForecastFact
            WHERE Id IN :factIds AND AccountId = :accountId AND AdvAcctForecastSetUseId = :useId
                AND Status = 'Active' FOR UPDATE];
        if (facts.size() != factIds.size()) throw new AuraHandledException('Some forecast months are unavailable. Reload the grid.');
        for (AdvAccountForecastFact fact : facts) {
            ForecastEdit edit = requested.get(fact.Id);
            Decimal quantity = edit.forecastQuantity == null ? fact.ForecastedQuantity : edit.forecastQuantity;
            Decimal revenue = edit.forecastRevenue == null ? fact.ForecastedRevenue : edit.forecastRevenue;
            if (quantity == null || revenue == null || quantity < 0 || revenue < 0
                || quantity.setScale(0) != quantity || revenue.setScale(2) != revenue
                || (fact.ProductId == indicativeId && quantity != 0)) {
                throw new AuraHandledException('Enter nonnegative whole units and revenue to two decimal places.');
            }
            Decimal baseQuantity = Math.max(fact.OrderQuantity == null ? 0 : fact.OrderQuantity,
                fact.SalesAgreementQuantity == null ? 0 : fact.SalesAgreementQuantity)
                + (fact.OpportunityQuantity == null ? 0 : fact.OpportunityQuantity);
            Decimal baseRevenue = Math.max(fact.OrderRevenue == null ? 0 : fact.OrderRevenue,
                fact.SalesAgreementRevenue == null ? 0 : fact.SalesAgreementRevenue)
                + (fact.OpportunityRevenue == null ? 0 : fact.OpportunityRevenue);
            fact.Carlton_Account_Adjustment_Quantity_CC__c = quantity - baseQuantity;
            fact.Carlton_Account_Adjustment_Revenue_CC__c = revenue - baseRevenue;
            fact.ForecastedQuantity = quantity;
            fact.ForecastedRevenue = revenue;
        }
        update facts;
        return facts.size();
    }

    @AuraEnabled
    public static Integer changeProductForecast(Id accountId, Id productId, Date fromMonth,
        Date throughMonth, Decimal percentChange) {
        if (accountId == null || productId == null || fromMonth == null || throughMonth == null
            || fromMonth.day() != 1 || throughMonth.day() != 1 || fromMonth > throughMonth
            || percentChange == null || percentChange < -100 || percentChange > 1000) {
            throw new AuraHandledException('Select a product, valid month range, and change between -100% and 1000%.');
        }
        List<AdvAccountForecastSet> sets = [SELECT Id FROM AdvAccountForecastSet
            WHERE DeveloperName = 'Carlton_Account_Product_Demand' AND Status = 'Active' LIMIT 1];
        if (sets.isEmpty()) throw new AuraHandledException('The product forecast set is unavailable.');
        List<AdvAcctForecastSetUse> uses = [SELECT Id FROM AdvAcctForecastSetUse
            WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :sets[0].Id
                AND Status = 'Active' LIMIT 1];
        if (uses.isEmpty()) throw new AuraHandledException('This account has no active product forecast.');
        Id useId = uses[0].Id;
        List<AdvAccountForecastFact> facts = [
            SELECT Id, OrderQuantity, OrderRevenue, SalesAgreementQuantity, SalesAgreementRevenue,
                OpportunityQuantity, OpportunityRevenue, ForecastedQuantity, ForecastedRevenue
            FROM AdvAccountForecastFact WHERE AccountId = :accountId
                AND AdvAcctForecastSetUseId = :useId AND ProductId = :productId
                AND Status = 'Active' AND PeriodStartDate >= :fromMonth
                AND PeriodStartDate <= :throughMonth FOR UPDATE
        ];
        if (facts.isEmpty()) throw new AuraHandledException('No product forecast months match the selection.');
        Decimal multiplier = 1 + percentChange / 100;
        for (AdvAccountForecastFact fact : facts) {
            Decimal baseQuantity = Math.max(fact.OrderQuantity == null ? 0 : fact.OrderQuantity,
                fact.SalesAgreementQuantity == null ? 0 : fact.SalesAgreementQuantity)
                + (fact.OpportunityQuantity == null ? 0 : fact.OpportunityQuantity);
            Decimal baseRevenue = Math.max(fact.OrderRevenue == null ? 0 : fact.OrderRevenue,
                fact.SalesAgreementRevenue == null ? 0 : fact.SalesAgreementRevenue)
                + (fact.OpportunityRevenue == null ? 0 : fact.OpportunityRevenue);
            Decimal targetQuantity = ((fact.ForecastedQuantity == null ? 0 : fact.ForecastedQuantity) * multiplier).setScale(0);
            Decimal targetRevenue = ((fact.ForecastedRevenue == null ? 0 : fact.ForecastedRevenue) * multiplier).setScale(2);
            fact.Carlton_Account_Adjustment_Quantity_CC__c = targetQuantity - baseQuantity;
            fact.Carlton_Account_Adjustment_Revenue_CC__c = targetRevenue - baseRevenue;
            fact.ForecastedQuantity = targetQuantity;
            fact.ForecastedRevenue = targetRevenue;
        }
        update facts;
        return facts.size();
    }

    @AuraEnabled(cacheable=true)
    public static ForecastOverview getRevenueOverview(Id accountId) {
        ForecastOverview result = new ForecastOverview();
        result.rows = new List<ForecastRow>();
        if (accountId == null) return result;
        List<AdvAccountForecastSet> sets = [SELECT Id FROM AdvAccountForecastSet
            WHERE DeveloperName = 'Carlton_Account_Revenue_Only' AND Status = 'Active' LIMIT 1];
        if (sets.isEmpty()) return result;
        List<AdvAcctForecastSetUse> uses = [SELECT Id, CurrencyIsoCode FROM AdvAcctForecastSetUse
            WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :sets[0].Id
                AND Status = 'Active' LIMIT 1];
        if (uses.isEmpty()) return result;
        result.forecastUseId = uses[0].Id;
        result.currencyCode = uses[0].CurrencyIsoCode;
        Id useId = uses[0].Id;
        Id indicativeProductId = indicativeRevenueProductId();
        Date startMonth = Date.today().toStartOfMonth();
        for (AdvAccountForecastFact fact : [
            SELECT Id, PeriodStartDate, SalesAgreementRevenue, OrderRevenue, ForecastedRevenue
            FROM AdvAccountForecastFact WHERE AccountId = :accountId
                AND AdvAcctForecastSetUseId = :useId AND ProductId = :indicativeProductId
                AND Status = 'Active' AND PeriodStartDate >= :startMonth
            ORDER BY PeriodStartDate LIMIT 24
        ]) {
            ForecastRow row = new ForecastRow();
            row.key = String.valueOf(fact.Id);
            row.monthStart = fact.PeriodStartDate;
            row.monthLabel = DateTime.newInstance(fact.PeriodStartDate, Time.newInstance(12, 0, 0, 0)).format('MMMM yyyy');
            row.productName = 'ACCOUNT REVENUE';
            row.agreementRevenue = fact.SalesAgreementRevenue == null ? 0 : fact.SalesAgreementRevenue;
            row.actualRevenue = fact.OrderRevenue == null ? 0 : fact.OrderRevenue;
            row.forecastRevenue = fact.ForecastedRevenue == null ? 0 : fact.ForecastedRevenue;
            row.isTotal = true;
            result.rows.add(row);
        }
        return result;
    }

    @AuraEnabled
    public static Integer syncRevenueForecast(Id accountId) {
        if (accountId == null) throw new AuraHandledException('Select an account.');
        List<AdvAccountForecastSet> sets = [SELECT Id, DeveloperName FROM AdvAccountForecastSet
            WHERE DeveloperName IN ('Carlton_Account_Product_Demand', 'Carlton_Account_Revenue_Only')
                AND Status = 'Active'];
        Map<String, Id> setIds = new Map<String, Id>();
        for (AdvAccountForecastSet forecastSet : sets) setIds.put(forecastSet.DeveloperName, forecastSet.Id);
        if (!setIds.containsKey('Carlton_Account_Revenue_Only')) {
            throw new AuraHandledException('The revenue forecast set is unavailable.');
        }
        Id revenueSetId = setIds.get('Carlton_Account_Revenue_Only');
        Id productSetId = setIds.get('Carlton_Account_Product_Demand');
        Id indicativeProductId = indicativeRevenueProductId();
        List<AdvAcctForecastSetUse> revenueUses = [SELECT Id, CurrencyIsoCode FROM AdvAcctForecastSetUse
            WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :revenueSetId
                AND Status = 'Active' LIMIT 1];
        AdvAcctForecastSetUse revenueUse;
        if (revenueUses.isEmpty()) {
            Account account = [SELECT Name FROM Account WHERE Id = :accountId LIMIT 1];
            revenueUse = new AdvAcctForecastSetUse(Name = account.Name.left(60) + ' revenue forecast',
                AdvAccountForecastSetId = revenueSetId, ForecastContextId = accountId,
                CurrencyIsoCode = 'GBP', Status = 'Active');
            insert revenueUse;
        } else revenueUse = revenueUses[0];

        Map<Id, Decimal> productRevenueByPeriod = new Map<Id, Decimal>();
        Map<Id, Decimal> orderRevenueByPeriod = new Map<Id, Decimal>();
        if (productSetId != null) {
            List<AdvAcctForecastSetUse> productUses = [SELECT Id FROM AdvAcctForecastSetUse
                WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :productSetId
                    AND Status = 'Active' LIMIT 1];
            if (!productUses.isEmpty()) {
                Id productUseId = productUses[0].Id;
                // Sum GBP fact fields in Apex. SOQL SUM converts currency into the running user's currency.
                for (AdvAccountForecastFact source : [SELECT PeriodId, ForecastedRevenue, OrderRevenue
                    FROM AdvAccountForecastFact WHERE AdvAcctForecastSetUseId = :productUseId
                        AND AccountId = :accountId AND Status = 'Active' AND ProductId != null
                        AND ProductId != :indicativeProductId
                    ]) {
                    productRevenueByPeriod.put(source.PeriodId,
                        (productRevenueByPeriod.containsKey(source.PeriodId) ? productRevenueByPeriod.get(source.PeriodId) : 0)
                        + (source.ForecastedRevenue == null ? 0 : source.ForecastedRevenue));
                    orderRevenueByPeriod.put(source.PeriodId,
                        (orderRevenueByPeriod.containsKey(source.PeriodId) ? orderRevenueByPeriod.get(source.PeriodId) : 0)
                        + (source.OrderRevenue == null ? 0 : source.OrderRevenue));
                }
            }
        }
        Map<Id, AdvAccountForecastFact> existing = new Map<Id, AdvAccountForecastFact>();
        for (AdvAccountForecastFact fact : [SELECT Id, Name, PeriodId, Carlton_Account_Adjustment_Revenue_CC__c
            FROM AdvAccountForecastFact WHERE AdvAcctForecastSetUseId = :revenueUse.Id
                AND AccountId = :accountId AND (ProductId = :indicativeProductId OR ProductId = null)
                AND Status = 'Active' LIMIT 1000]) {
            existing.put(fact.PeriodId, fact);
        }
        // The shared DPE definitions can recreate product-grain rows in this revenue set.
        // Keep the native revenue grid to one indicative-product row per month.
        List<AdvAccountForecastFact> superseded = [SELECT Id, Status
            FROM AdvAccountForecastFact WHERE AdvAcctForecastSetUseId = :revenueUse.Id
                AND AccountId = :accountId AND ProductId != :indicativeProductId
                AND Status = 'Active' LIMIT 1000];
        for (AdvAccountForecastFact fact : superseded) fact.Status = 'Inactive';
        if (!superseded.isEmpty()) update superseded;
        Date firstMonth = Date.today().toStartOfMonth();
        Date afterHorizon = firstMonth.addMonths(18);
        List<AdvAccountForecastFact> updates = new List<AdvAccountForecastFact>();
        for (Period period : [SELECT Id, StartDate FROM Period WHERE Type = 'Month'
            AND StartDate >= :firstMonth AND StartDate < :afterHorizon ORDER BY StartDate LIMIT 18]) {
            AdvAccountForecastFact fact = existing.get(period.Id);
            Boolean isNew = fact == null;
            if (isNew) fact = new AdvAccountForecastFact();
            Decimal productRevenue = productRevenueByPeriod.containsKey(period.Id)
                ? productRevenueByPeriod.get(period.Id) : 0;
            // Older pilot account facts copied a product adjustment. Replace that legacy duplicate once.
            Decimal indicative = isNew || !fact.Name.startsWith('Carlton account revenue ')
                ? 0 : (fact.Carlton_Account_Adjustment_Revenue_CC__c == null
                    ? 0 : fact.Carlton_Account_Adjustment_Revenue_CC__c);
            fact.Name = 'Carlton account revenue ' + String.valueOf(period.StartDate);
            fact.AccountId = accountId;
            fact.AdvAcctForecastSetUseId = revenueUse.Id;
            fact.PeriodId = period.Id;
            fact.PeriodStartDate = period.StartDate;
            fact.ProductId = indicativeProductId;
            fact.CurrencyIsoCode = revenueUse.CurrencyIsoCode;
            fact.Status = 'Active';
            fact.SalesAgreementRevenue = productRevenue;
            fact.OrderRevenue = orderRevenueByPeriod.containsKey(period.Id)
                ? orderRevenueByPeriod.get(period.Id) : 0;
            fact.OpportunityRevenue = 0;
            fact.Carlton_Account_Adjustment_Revenue_CC__c = indicative;
            fact.ForecastedRevenue = productRevenue + indicative;
            updates.add(fact);
        }
        upsert updates;
        return updates.size();
    }

    @AuraEnabled
    public static Integer setMonthlyRevenue(Id accountId, Date fromMonth, Date throughMonth, Decimal amount) {
        if (accountId == null || fromMonth == null || throughMonth == null
            || fromMonth.day() != 1 || throughMonth.day() != 1 || fromMonth > throughMonth
            || amount == null || amount < 0) {
            throw new AuraHandledException('Enter a nonnegative amount and valid first-of-month range.');
        }
        List<AdvAccountForecastSet> sets = [SELECT Id FROM AdvAccountForecastSet
            WHERE DeveloperName = 'Carlton_Account_Revenue_Only' AND Status = 'Active' LIMIT 1];
        if (sets.isEmpty()) throw new AuraHandledException('The revenue forecast set is unavailable.');
        List<AdvAcctForecastSetUse> uses = [SELECT Id FROM AdvAcctForecastSetUse
            WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :sets[0].Id
                AND Status = 'Active' LIMIT 1];
        if (uses.isEmpty()) throw new AuraHandledException('Refresh the account revenue forecast first.');
        Id useId = uses[0].Id;
        Id indicativeProductId = indicativeRevenueProductId();
        List<AdvAccountForecastFact> facts = [SELECT Id, SalesAgreementRevenue
            FROM AdvAccountForecastFact WHERE AccountId = :accountId AND AdvAcctForecastSetUseId = :useId
                AND ProductId = :indicativeProductId AND Status = 'Active' AND PeriodStartDate >= :fromMonth
                AND PeriodStartDate <= :throughMonth FOR UPDATE];
        if (facts.isEmpty()) throw new AuraHandledException('No account revenue months match the selection.');
        for (AdvAccountForecastFact fact : facts) {
            Decimal baseRevenue = fact.SalesAgreementRevenue == null ? 0 : fact.SalesAgreementRevenue;
            fact.Carlton_Account_Adjustment_Revenue_CC__c = amount - baseRevenue;
            fact.ForecastedRevenue = amount;
        }
        update facts;
        return facts.size();
    }
}