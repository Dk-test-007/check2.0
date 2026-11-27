/** The MVP win path: a monthly forecast is independent of an optional header-only agreement. */
public with sharing class CarltonWinForecastService_CC {
    public class SavedLine {
        public Id productId;
        public Id pricebookEntryId;
        public String mode;
        public Date startMonth;
        public List<Decimal> monthlyValues;
        public List<Decimal> monthlyRevenueGBP;
    }
    public class SavedPlan {
        public Date startMonth;
        public Integer termMonths;
        public Boolean agreementNeeded;
        public Id agreementId;
        public String businessType;
        public List<SavedLine> lines;
    }

    public static SalesAgreementPlanService_CC.PlanResult completeWin(SalesAgreementPlanService_CC.PlanRequest request) {
        SalesAgreementPlanService_CC.requirePilot();
        if (request.opportunityId == null) throw SalesAgreementPlanService_CC.error('Choose an Opportunity.');
        SalesAgreementPlanService_CC.requireEditAccess(request.opportunityId);
        Opportunity opp = [SELECT Id, Name, AccountId, Amount, StageName, IsClosed, IsWon,
            RecordType.DeveloperName, Pricebook2Id, CurrencyIsoCode, Carlton_Monthly_Forecast_Plan_CC__c
            FROM Opportunity WHERE Id = :request.opportunityId WITH USER_MODE FOR UPDATE];
        if (!String.isBlank(opp.Carlton_Monthly_Forecast_Plan_CC__c)) {
            SavedPlan previous = (SavedPlan) JSON.deserialize(opp.Carlton_Monthly_Forecast_Plan_CC__c, SavedPlan.class);
            SalesAgreementPlanService_CC.PlanResult result = new SalesAgreementPlanService_CC.PlanResult();
            result.salesAgreementId = previous.agreementId;
            result.alreadyExisted = true;
            result.planStatus = 'Saved';
            result.message = 'The initial opportunity forecast was already saved; it was not duplicated.';
            return result;
        }
        if (opp.RecordType.DeveloperName != SalesAgreementPlanService_CC.NEW_BUSINESS || (opp.IsClosed && !opp.IsWon)) {
            throw SalesAgreementPlanService_CC.error('Use this action on a new-business Opportunity before or after Closed Won.');
        }
        if (!opp.IsWon && opp.StageName != 'Negotiate') {
            throw SalesAgreementPlanService_CC.error('Move the New Business opportunity to Negotiate before completing the win forecast.');
        }
        if (opp.Amount == null || opp.Amount <= 0 || opp.Pricebook2Id == null) {
            throw SalesAgreementPlanService_CC.error('Enter a positive Opportunity Amount and choose its price book.');
        }
        if (request.startMonth == null || request.startMonth.day() != 1 || request.termMonths == null
            || request.termMonths < 1 || request.termMonths > 18) {
            throw SalesAgreementPlanService_CC.error('Choose a first day of month and a term of 1 to 18 months.');
        }
        Date horizonStart = Date.today().toStartOfMonth();
        if (request.startMonth < horizonStart || request.startMonth.addMonths(request.termMonths) > horizonStart.addMonths(18)) {
            throw SalesAgreementPlanService_CC.error('The monthly plan must fit in the active 18-month account forecast horizon.');
        }
        if (request.products == null || request.products.isEmpty() || request.products.size() > 50) {
            throw SalesAgreementPlanService_CC.error('Choose 1 to 50 product lines.');
        }
        if (request.agreementNeeded && String.isBlank(request.agreementSummary)) {
            throw SalesAgreementPlanService_CC.error('Describe the agreed coverage and pricing terms.');
        }
        if (request.agreementSummary != null && request.agreementSummary.length() > 32000) {
            throw SalesAgreementPlanService_CC.error('Agreement terms are too long.');
        }
        Set<Id> entryIds = new Set<Id>();
        for (SalesAgreementPlanService_CC.ProductShare item : request.products) {
            if (item == null || item.pricebookEntryId == null || !entryIds.add(item.pricebookEntryId)) {
                throw SalesAgreementPlanService_CC.error('Choose each product once.');
            }
        }
        Map<Id, PricebookEntry> entries = new Map<Id, PricebookEntry>([SELECT Id, Product2Id, UnitPrice,
            CurrencyIsoCode, Pricebook2Id, IsActive FROM PricebookEntry WHERE Id IN :entryIds WITH USER_MODE]);
        Map<String, Decimal> rates = new Map<String, Decimal>();
        Set<String> currencyCodes = new Set<String>{'GBP', opp.CurrencyIsoCode};
        for (CurrencyType currencyRow : [SELECT IsoCode, ConversionRate FROM CurrencyType WHERE IsoCode IN :currencyCodes])
            rates.put(currencyRow.IsoCode, currencyRow.ConversionRate);
        if (!rates.containsKey('GBP') || !rates.containsKey(opp.CurrencyIsoCode)) {
            throw SalesAgreementPlanService_CC.error('A current GBP conversion rate is unavailable.');
        }
        Decimal factor = rates.get('GBP') / rates.get(opp.CurrencyIsoCode);
        SavedPlan plan = new SavedPlan();
        plan.startMonth = request.startMonth;
        plan.termMonths = request.termMonths;
        plan.agreementNeeded = request.agreementNeeded;
        plan.businessType = 'New business';
        plan.lines = new List<SavedLine>();
        List<Decimal> monthlyTotals = new List<Decimal>();
        for (Integer i = 0; i < request.termMonths; i++) monthlyTotals.add(0);
        Decimal total = 0;
        for (SalesAgreementPlanService_CC.ProductShare item : request.products) {
            PricebookEntry entry = entries.get(item.pricebookEntryId);
            if (entry == null || !entry.IsActive || entry.Pricebook2Id != opp.Pricebook2Id
                || entry.CurrencyIsoCode != opp.CurrencyIsoCode || entry.UnitPrice == null || entry.UnitPrice <= 0) {
                throw SalesAgreementPlanService_CC.error('Use active products from the Opportunity price book and currency.');
            }
            if (item.mode != 'Quantity' && item.mode != 'Value') throw SalesAgreementPlanService_CC.error('Choose Quantity or Value.');
            if (item.monthlyValues == null || item.monthlyValues.size() != request.termMonths) {
                throw SalesAgreementPlanService_CC.error('Each product needs a value for every month.');
            }
            Date lineStart = item.startMonth == null ? request.startMonth : item.startMonth;
            if (lineStart.day() != 1 || lineStart < request.startMonth || lineStart >= request.startMonth.addMonths(request.termMonths)) {
                throw SalesAgreementPlanService_CC.error('Product start month must be inside the forecast term.');
            }
            SavedLine line = new SavedLine();
            line.productId = entry.Product2Id;
            line.pricebookEntryId = entry.Id;
            line.mode = item.mode;
            line.startMonth = lineStart;
            line.monthlyValues = new List<Decimal>();
            line.monthlyRevenueGBP = new List<Decimal>();
            Decimal lineTotal = 0;
            for (Integer i = 0; i < request.termMonths; i++) {
                Decimal value = item.monthlyValues[i] == null ? 0 : item.monthlyValues[i];
                Date month = request.startMonth.addMonths(i);
                if (value < 0 || (month < lineStart && value != 0)
                    || (item.mode == 'Quantity' && value.setScale(0) != value)
                    || (item.mode == 'Value' && value.setScale(2) != value)) {
                    throw SalesAgreementPlanService_CC.error('Use nonnegative whole units or two-decimal values; earlier months must be zero.');
                }
                Decimal amount = item.mode == 'Quantity' ? (value * entry.UnitPrice).setScale(2) : value;
                line.monthlyValues.add(value);
                line.monthlyRevenueGBP.add((amount * factor).setScale(2, System.RoundingMode.HALF_UP));
                monthlyTotals[i] += amount;
                lineTotal += amount;
            }
            if (lineTotal <= 0) throw SalesAgreementPlanService_CC.error('Every selected product needs a positive forecast.');
            total += lineTotal;
            plan.lines.add(line);
        }
        if (total != opp.Amount.setScale(2)) throw SalesAgreementPlanService_CC.error('Monthly product totals must equal the Opportunity Amount.');
        if (request.monthlyAmounts == null || request.monthlyAmounts.size() != request.termMonths) {
            throw SalesAgreementPlanService_CC.error('Monthly totals are missing.');
        }
        for (Integer i = 0; i < request.termMonths; i++) {
            if (monthlyTotals[i] != request.monthlyAmounts[i]) throw SalesAgreementPlanService_CC.error('Monthly grid totals changed. Reload and review.');
        }
        Savepoint sp = Database.setSavepoint();
        try {
            if (request.agreementNeeded) {
                SalesAgreement agreement = new SalesAgreement(
                    Name = (opp.Name.left(65) + ' - Agreement').left(80),
                    AccountId = opp.AccountId, PricebookId = opp.Pricebook2Id,
                    CurrencyIsoCode = opp.CurrencyIsoCode, StartDate = request.startMonth,
                    ScheduleFrequency = 'Monthly', ScheduleCount = request.termMonths,
                    ActualsCalculationMode = 'Orders', Status = 'Draft',
                    Description = request.agreementSummary,
                    Source_Opportunity_CC__c = opp.Id,
                    UI2_Creation_Key_CC__c = SalesAgreementPlanService_CC.KEY_PREFIX + opp.Id,
                    Commercial_Scope_CC__c = String.isBlank(request.scope) ? 'Entity-wide' : request.scope
                );
                Database.insert(agreement, AccessLevel.USER_MODE);
                plan.agreementId = agreement.Id;
            }
            Opportunity winUpdate = new Opportunity(Id = opp.Id,
                Carlton_Monthly_Forecast_Plan_CC__c = JSON.serialize(plan),
                Carlton_Monthly_Forecast_Complete_CC__c = true);
            if (!opp.IsWon) winUpdate.StageName = SalesAgreementPlanService_CC.WON_STAGE;
            Database.update(winUpdate, AccessLevel.USER_MODE);
            projectToAccount(opp.AccountId, plan);
            SalesAgreementPlanService_CC.PlanResult result = new SalesAgreementPlanService_CC.PlanResult();
            result.salesAgreementId = plan.agreementId;
            result.alreadyExisted = false;
            result.planStatus = 'Saved';
            result.message = plan.agreementId == null
                ? 'Won. Initial monthly forecast saved to the Account without an agreement.'
                : 'Won. Initial monthly forecast and draft agreement header saved separately.';
            return result;
        } catch (Exception ex) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, 'CARLTON_WIN_FORECAST_SAVE: ' + ex.getMessage() + ' ' + ex.getStackTraceString());
            throw SalesAgreementPlanService_CC.error('Nothing was saved. ' + ex.getMessage());
        }
    }

    private static void projectToAccount(Id accountId, SavedPlan plan) {
        CarltonAccountForecastController.ensureUnifiedForecast(accountId);
        Id setId = [SELECT Id FROM AdvAccountForecastSet WHERE DeveloperName = 'Carlton_Account_Product_Demand'
            AND Status = 'Active' LIMIT 1].Id;
        AdvAcctForecastSetUse useRow = [SELECT Id, CurrencyIsoCode FROM AdvAcctForecastSetUse
            WHERE ForecastContextId = :accountId AND AdvAccountForecastSetId = :setId AND Status = 'Active' LIMIT 1];
        Map<Date, Id> periods = new Map<Date, Id>();
        Date firstMonth = plan.startMonth;
        Date afterTerm = plan.startMonth.addMonths(plan.termMonths);
        for (Period period : [SELECT Id, StartDate FROM Period WHERE Type = 'Month'
            AND StartDate >= :firstMonth AND StartDate < :afterTerm]) {
            periods.put(period.StartDate, period.Id);
        }
        if (periods.size() != plan.termMonths) throw SalesAgreementPlanService_CC.error('Some forecast periods are unavailable.');
        Set<Id> productIds = new Set<Id>();
        for (SavedLine line : plan.lines) productIds.add(line.productId);
        Map<String, AdvAccountForecastFact> existing = new Map<String, AdvAccountForecastFact>();
        Set<Id> periodIds = new Set<Id>(periods.values());
        Id useId = useRow.Id;
        Map<String, Object> factBinds = new Map<String, Object>{
            'accountId' => accountId, 'useId' => useId, 'productIds' => productIds, 'periodIds' => periodIds
        };
        for (SObject record : Database.queryWithBinds(
            'SELECT Id, ProductId, PeriodStartDate, ForecastedQuantity, ForecastedRevenue, '
            + 'Carlton_Account_Adjustment_Quantity_CC__c, Carlton_Account_Adjustment_Revenue_CC__c '
            + 'FROM AdvAccountForecastFact WHERE AccountId = :accountId AND AdvAcctForecastSetUseId = :useId '
            + 'AND ProductId IN :productIds AND PeriodId IN :periodIds AND Status = \'Active\' FOR UPDATE',
            factBinds, AccessLevel.SYSTEM_MODE)) {
            AdvAccountForecastFact fact = (AdvAccountForecastFact) record;
            existing.put(String.valueOf(fact.ProductId) + ':' + String.valueOf(fact.PeriodStartDate), fact);
        }
        List<AdvAccountForecastFact> changes = new List<AdvAccountForecastFact>();
        for (SavedLine line : plan.lines) {
            for (Integer i = 0; i < plan.termMonths; i++) {
                Date month = plan.startMonth.addMonths(i);
                Decimal quantity = line.mode == 'Quantity' ? line.monthlyValues[i] : 0;
                Decimal revenue = line.monthlyRevenueGBP[i];
                if (quantity == 0 && revenue == 0) continue;
                String key = String.valueOf(line.productId) + ':' + String.valueOf(month);
                AdvAccountForecastFact fact = existing.get(key);
                if (fact == null) {
                    fact = new AdvAccountForecastFact(Name = 'Carlton opportunity forecast ' + String.valueOf(month),
                        AccountId = accountId, AdvAcctForecastSetUseId = useRow.Id,
                        ProductId = line.productId, PeriodId = periods.get(month), PeriodStartDate = month,
                        CurrencyIsoCode = useRow.CurrencyIsoCode, Status = 'Active',
                        OrderQuantity = 0, OrderRevenue = 0, SalesAgreementQuantity = 0, SalesAgreementRevenue = 0,
                        OpportunityQuantity = 0, OpportunityRevenue = 0,
                        Carlton_Account_Adjustment_Quantity_CC__c = 0,
                        Carlton_Account_Adjustment_Revenue_CC__c = 0,
                        ForecastedQuantity = 0, ForecastedRevenue = 0);
                    existing.put(key, fact);
                    changes.add(fact);
                } else if (!changes.contains(fact)) changes.add(fact);
                fact.Carlton_Account_Adjustment_Quantity_CC__c =
                    (fact.Carlton_Account_Adjustment_Quantity_CC__c == null ? 0 : fact.Carlton_Account_Adjustment_Quantity_CC__c) + quantity;
                fact.Carlton_Account_Adjustment_Revenue_CC__c =
                    (fact.Carlton_Account_Adjustment_Revenue_CC__c == null ? 0 : fact.Carlton_Account_Adjustment_Revenue_CC__c) + revenue;
                fact.ForecastedQuantity = (fact.ForecastedQuantity == null ? 0 : fact.ForecastedQuantity) + quantity;
                fact.ForecastedRevenue = (fact.ForecastedRevenue == null ? 0 : fact.ForecastedRevenue) + revenue;
            }
        }
        if (!changes.isEmpty()) Database.upsert(changes, AccessLevel.SYSTEM_MODE);
    }
}