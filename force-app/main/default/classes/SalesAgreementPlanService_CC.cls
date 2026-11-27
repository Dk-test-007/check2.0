/**
 * Opportunity UI2: Win and Set Monthly Forecast.
 *
 * Wins a new-business Opportunity and, in the same transaction, creates its native Sales Agreement (one per win),
 * agreement products, monthly product schedules and the immutable monthly baseline (Agreement_Month_Plan_CC__c).
 *
 * Integrity:
 * - Feature access: custom permission Opportunity_UI2_Pilot_CC, checked here on every entry point.
 * - Records are written in user mode (CRUD, FLS and sharing enforced). Month plans are read-only to users so a
 *   forecast can only change through SalesAgreementForecastService_CC, which records a reason; they are inserted
 *   here in system mode after the permission and record-access checks.
 * - Idempotency: SalesAgreement.UI2_Creation_Key_CC__c = 'WIN-' + Opportunity Id is unique. A double click, retry,
 *   concurrent request or reopen/reclose returns the existing agreement; its baseline is never reset.
 * - Initial gate (UI2 default, to be reviewed): monthly amounts must total the Opportunity Amount to the currency's
 *   decimal places. It applies once, when the baseline is established; later revisions may total more or less.
 * - Native activation (Draft, Approved, Activated) needs separate transactions, so it is queued
 *   (SalesAgreementActivationJob_CC) with a visible Plan Status and a resume action.
 */
public with sharing class SalesAgreementPlanService_CC {

    public static final String PILOT_PERMISSION = 'Opportunity_UI2_Pilot_CC';
    public static final String KEY_PREFIX = 'WIN-';
    public static final String SCOPE_ENTITY = 'Entity-wide';
    public static final String SCOPE_SITE = 'Site-scoped';
    public static final String WON_STAGE = 'Closed Won';
    public static final String NEW_BUSINESS = 'New_Business';
    public static final Integer DEFAULT_TERM = 12;
    public static final Integer MAX_TERM = 36;
    private static final String ENTITY_PLAN_SCOPE = 'ENTITY';

    public class PlanRequest {
        @AuraEnabled public Id opportunityId { get; set; }
        @AuraEnabled public Date startMonth { get; set; }
        @AuraEnabled public Integer termMonths { get; set; }
        @AuraEnabled public List<Decimal> monthlyAmounts { get; set; }
        @AuraEnabled public List<ProductShare> products { get; set; }
        @AuraEnabled public String scope { get; set; }
        @AuraEnabled public List<Id> siteIds { get; set; }
        @AuraEnabled public Boolean agreementNeeded { get; set; }
        @AuraEnabled public String agreementSummary { get; set; }
    }

    /** A product the plan is allocated to, with its share of every month (shares total 100). */
    public class ProductShare {
        @AuraEnabled public Id pricebookEntryId { get; set; }
        @AuraEnabled public Decimal sharePercent { get; set; }
        @AuraEnabled public String mode { get; set; }
        @AuraEnabled public Date startMonth { get; set; }
        @AuraEnabled public List<Decimal> monthlyValues { get; set; }
    }

    public class PlanResult {
        @AuraEnabled public Id salesAgreementId { get; set; }
        @AuraEnabled public Boolean alreadyExisted { get; set; }
        @AuraEnabled public String planStatus { get; set; }
        @AuraEnabled public String message { get; set; }
    }

    /** Context the Win screen needs: the Opportunity, its products, allowed Sites and any existing agreement. */
    public class WinContext {
        @AuraEnabled public Id opportunityId { get; set; }
        @AuraEnabled public String opportunityName { get; set; }
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String currencyIsoCode { get; set; }
        @AuraEnabled public Integer currencyDecimals { get; set; }
        @AuraEnabled public Id pricebookId { get; set; }
        @AuraEnabled public String pricebookName { get; set; }
        @AuraEnabled public String stageName { get; set; }
        @AuraEnabled public Boolean isClosed { get; set; }
        @AuraEnabled public Boolean isNewBusiness { get; set; }
        @AuraEnabled public Id existingAgreementId { get; set; }
        @AuraEnabled public String existingAgreementName { get; set; }
        @AuraEnabled public Boolean hasInitialForecast { get; set; }
        @AuraEnabled public List<Option> products { get; set; }
        @AuraEnabled public List<Option> sites { get; set; }
        @AuraEnabled public Date defaultStartMonth { get; set; }
        @AuraEnabled public Integer defaultTerm { get; set; }
    }

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public Boolean fromOpportunity { get; set; }
    }

    // ------------------------------------------------------------------ entry points

    @AuraEnabled
    public static WinContext getWinContext(Id opportunityId) {
        requirePilot();
        Opportunity opp = loadOpportunity(opportunityId);
        WinContext ctx = new WinContext();
        ctx.opportunityId = opp.Id;
        ctx.opportunityName = opp.Name;
        ctx.accountId = opp.AccountId;
        ctx.accountName = opp.Account.Name;
        ctx.amount = opp.Amount;
        ctx.currencyIsoCode = currencyOf(opp);
        ctx.currencyDecimals = currencyDecimals(ctx.currencyIsoCode);
        Id pricebookId = pricebookFor(opp);
        ctx.pricebookId = pricebookId;
        List<Pricebook2> pricebooks = [SELECT Name FROM Pricebook2 WHERE Id = :pricebookId WITH USER_MODE];
        ctx.pricebookName = pricebooks.isEmpty() ? null : pricebooks[0].Name;
        ctx.stageName = opp.StageName;
        ctx.isClosed = opp.IsClosed;
        ctx.isNewBusiness = opp.RecordType.DeveloperName == NEW_BUSINESS;
        SalesAgreement existing = existingAgreement(opp.Id);
        ctx.existingAgreementId = existing?.Id;
        ctx.existingAgreementName = existing?.Name;
        ctx.hasInitialForecast = !String.isBlank(opp.Carlton_Monthly_Forecast_Plan_CC__c);
        ctx.products = productOptions(opp, pricebookId);
        ctx.sites = siteOptions(opp.AccountId);
        Date today = Date.today();
        ctx.defaultStartMonth = Date.newInstance(today.year(), today.month(), 1);
        ctx.defaultTerm = DEFAULT_TERM;
        return ctx;
    }

    @AuraEnabled
    public static PlanResult winAndPlan(PlanRequest request) {
        if (request != null && request.agreementNeeded != null) {
            return CarltonWinForecastService_CC.completeWin(request);
        }
        requirePilot();
        if (request == null || request.opportunityId == null) {
            throw error('Choose the Opportunity to win.');
        }
        Opportunity opp = loadOpportunity(request.opportunityId);
        requireEditAccess(opp.Id);

        SalesAgreement existing = existingAgreement(opp.Id);
        if (existing != null) {
            return existingResult(existing, 'This win already has its Sales Agreement; the original plan was kept.');
        }
        PlanInputs inputs = validate(opp, request);

        Savepoint sp = Database.setSavepoint();
        try {
            if (!opp.IsClosed) {
                Database.update(new Opportunity(Id = opp.Id, StageName = WON_STAGE), AccessLevel.USER_MODE);
            }
            SalesAgreement agreement = new SalesAgreement(
                Name = (opp.Name.left(70) + ' - Plan').left(80),
                AccountId = opp.AccountId,
                PricebookId = inputs.pricebookId,
                CurrencyIsoCode = inputs.currencyIsoCode,
                StartDate = inputs.startMonth,
                ScheduleFrequency = 'Monthly',
                ScheduleCount = inputs.term,
                ActualsCalculationMode = 'Orders',
                Status = 'Draft',
                Source_Opportunity_CC__c = opp.Id,
                UI2_Creation_Key_CC__c = KEY_PREFIX + opp.Id,
                Commercial_Scope_CC__c = inputs.scope,
                Original_Win_Amount_CC__c = opp.Amount,
                Plan_Status_CC__c = 'Activation Pending',
                Plan_Status_Detail_CC__c = 'Plan saved; activation queued.'
            );
            Database.SaveResult saved = Database.insert(agreement, false, AccessLevel.USER_MODE);
            if (!saved.isSuccess()) {
                Database.rollback(sp);
                SalesAgreement concurrent = isDuplicateKey(saved) ? existingAgreement(opp.Id) : null;
                if (concurrent != null) {
                    return existingResult(concurrent, 'Another request created this win\'s Sales Agreement first; it was kept.');
                }
                throw error('The Sales Agreement could not be saved: ' + saved.getErrors()[0].getMessage());
            }
            createProductsAndSchedules(agreement, inputs);
            createMonthPlans(agreement, opp, inputs);
            createAgreementSites(agreement, inputs);
            SalesAgreementActivationJob_CC.enqueue(agreement.Id);

            PlanResult result = new PlanResult();
            result.salesAgreementId = agreement.Id;
            result.alreadyExisted = false;
            result.planStatus = 'Activation Pending';
            result.message = 'Won. Sales Agreement and ' + inputs.term + '-month plan saved; activation is running.';
            return result;
        } catch (Exception ex) {
            Database.rollback(sp);
            if (ex instanceof AuraHandledException) {
                throw ex;
            }
            throw error('Nothing was saved. ' + (ex instanceof DmlException ? ((DmlException) ex).getDmlMessage(0) : ex.getMessage()));
        }
    }

    // ------------------------------------------------------------------ validation

    private class PlanInputs {
        Date startMonth;
        Integer term;
        List<Decimal> amounts;
        String currencyIsoCode;
        Integer decimals;
        Id pricebookId;
        String scope;
        List<Id> siteIds;
        List<PricebookEntry> entries;
        List<Decimal> shares;
        List<List<Decimal>> productAmounts;
        List<List<Decimal>> productValues;
        List<String> modes;
    }

    @TestVisible
    private static PlanInputs validate(Opportunity opp, PlanRequest request) {
        if (opp.RecordType.DeveloperName != NEW_BUSINESS) {
            throw error('Only new-business Opportunities use Win and Set Monthly Forecast.');
        }
        if (opp.IsClosed && !opp.IsWon) {
            throw error('This Opportunity is closed lost.');
        }
        if (opp.Amount == null || opp.Amount <= 0) {
            throw error('Enter the Opportunity Amount before winning it.');
        }
        PlanInputs inputs = new PlanInputs();
        inputs.term = request.termMonths == null ? DEFAULT_TERM : request.termMonths;
        if (inputs.term < 1 || inputs.term > MAX_TERM) {
            throw error('The term must be between 1 and ' + MAX_TERM + ' months.');
        }
        if (request.startMonth == null) {
            throw error('Choose the start month.');
        }
        inputs.startMonth = Date.newInstance(request.startMonth.year(), request.startMonth.month(), 1);
        inputs.currencyIsoCode = currencyOf(opp);
        inputs.decimals = currencyDecimals(inputs.currencyIsoCode);
        inputs.amounts = new List<Decimal>();
        if (request.monthlyAmounts == null || request.monthlyAmounts.size() != inputs.term) {
            throw error('Enter an amount for each of the ' + inputs.term + ' months (zero is allowed).');
        }
        Decimal total = 0;
        for (Decimal amount : request.monthlyAmounts) {
            Decimal value = amount == null ? 0 : amount;
            if (value < 0) {
                throw error('Monthly amounts cannot be negative.');
            }
            if (value.scale() > inputs.decimals && value.setScale(inputs.decimals) != value) {
                throw error(inputs.currencyIsoCode + ' amounts allow ' + inputs.decimals + ' decimal places.');
            }
            value = value.setScale(inputs.decimals);
            inputs.amounts.add(value);
            total += value;
        }
        Decimal winAmount = opp.Amount.setScale(inputs.decimals, System.RoundingMode.HALF_UP);
        if (total != winAmount) {
            throw error('The monthly amounts total ' + format(total, inputs) + ' but the win is ' + format(winAmount, inputs)
                + '. The initial plan must equal the Opportunity Amount (difference ' + format(winAmount - total, inputs) + ').');
        }
        inputs.pricebookId = pricebookFor(opp);
        if (inputs.pricebookId == null) {
            throw error('Choose a price book on the Opportunity first.');
        }
        loadProducts(request, inputs);
        inputs.scope = String.isBlank(request.scope) ? SCOPE_ENTITY : request.scope;
        inputs.siteIds = request.siteIds == null ? new List<Id>() : request.siteIds;
        if (inputs.scope != SCOPE_ENTITY && inputs.scope != SCOPE_SITE) {
            throw error('Choose Entity-wide or Site-scoped.');
        }
        if (inputs.scope == SCOPE_SITE && inputs.siteIds.size() != 1) {
            throw error('A Site-scoped plan needs exactly one Site in this UI2; split Entity-wide plans later.');
        }
        if (inputs.scope == SCOPE_ENTITY) {
            inputs.siteIds = new List<Id>();
        }
        AgreementSiteRules_CC.requireSitesOfEntity(opp.AccountId, new Set<Id>(inputs.siteIds));
        return inputs;
    }

    private static void loadProducts(PlanRequest request, PlanInputs inputs) {
        if (request.products == null || request.products.isEmpty()) {
            throw error('Choose at least one product for the plan.');
        }
        Boolean gridMode = request.products[0].monthlyValues != null;
        Map<Id, ProductShare> byEntry = new Map<Id, ProductShare>();
        Decimal shareTotal = 0;
        for (ProductShare product : request.products) {
            if (product.pricebookEntryId == null) {
                throw error('Choose a product on every line.');
            }
            if (byEntry.containsKey(product.pricebookEntryId)) {
                throw error('Each product can appear once.');
            }
            if (gridMode != (product.monthlyValues != null)) {
                throw error('Every product must use the same monthly grid format.');
            }
            if (!gridMode && (product.sharePercent == null || product.sharePercent <= 0)) {
                throw error('Each product needs a share above zero.');
            }
            byEntry.put(product.pricebookEntryId, product);
            if (!gridMode) shareTotal += product.sharePercent;
        }
        if (!gridMode && shareTotal != 100) {
            throw error('Product shares must total 100%.');
        }
        Map<Id, PricebookEntry> entries = new Map<Id, PricebookEntry>([
            SELECT Id, Product2Id, Product2.Name, UnitPrice, Pricebook2Id, CurrencyIsoCode, IsActive
            FROM PricebookEntry WHERE Id IN :byEntry.keySet() WITH USER_MODE
        ]);
        inputs.entries = new List<PricebookEntry>();
        inputs.shares = new List<Decimal>();
        inputs.productAmounts = new List<List<Decimal>>();
        inputs.productValues = new List<List<Decimal>>();
        inputs.modes = new List<String>();
        List<Decimal> monthlyTotals = new List<Decimal>();
        for (Integer i = 0; i < inputs.term; i++) monthlyTotals.add(0);
        for (ProductShare selected : request.products) {
            Id entryId = selected.pricebookEntryId;
            PricebookEntry entry = entries.get(entryId);
            if (entry == null || !entry.IsActive || entry.Pricebook2Id != inputs.pricebookId
                || entry.CurrencyIsoCode != inputs.currencyIsoCode || entry.UnitPrice == null || entry.UnitPrice <= 0) {
                throw error('Every product must be an active, priced entry in the Opportunity\'s price book and currency.');
            }
            inputs.entries.add(entry);
            if (!gridMode) {
                inputs.shares.add(selected.sharePercent);
                inputs.modes.add('Quantity');
                continue;
            }
            String mode = selected.mode;
            if (mode != 'Quantity' && mode != 'Value') throw error('Choose Quantity or Value for every product.');
            inputs.modes.add(mode);
            if (selected.monthlyValues.size() != inputs.term) throw error('Every product needs a value for each month.');
            Integer startIndex = selected.startMonth == null ? 0 : monthsBetween(inputs.startMonth, selected.startMonth);
            if (startIndex < 0 || startIndex >= inputs.term || (selected.startMonth != null && selected.startMonth.day() != 1)) {
                throw error('A product start month must be within the agreement term.');
            }
            List<Decimal> values = new List<Decimal>();
            List<Decimal> amounts = new List<Decimal>();
            Decimal productTotal = 0;
            for (Integer i = 0; i < inputs.term; i++) {
                Decimal value = selected.monthlyValues[i] == null ? 0 : selected.monthlyValues[i];
                if (value < 0 || (i < startIndex && value != 0)) throw error('Product values before their start month must be zero.');
                if (mode == 'Quantity' && value.setScale(0) != value) throw error('Product quantities must be whole units.');
                if (mode == 'Value' && value.setScale(inputs.decimals) != value) throw error('Product values exceed currency precision.');
                Decimal amount = mode == 'Quantity' ? (value * entry.UnitPrice).setScale(inputs.decimals) : value;
                values.add(value);
                amounts.add(amount);
                productTotal += amount;
                monthlyTotals[i] += amount;
            }
            if (productTotal <= 0) throw error('Every selected product needs a positive monthly quantity or value.');
            inputs.productValues.add(values);
            inputs.productAmounts.add(amounts);
        }
        if (gridMode) {
            for (Integer i = 0; i < inputs.term; i++) {
                if (monthlyTotals[i] != inputs.amounts[i]) throw error('Monthly total does not match its product lines for ' + inputs.startMonth.addMonths(i).format() + '.');
            }
        } else {
            inputs.productAmounts = splitByShare(inputs.amounts, inputs.shares, inputs.decimals);
            for (Integer p = 0; p < inputs.entries.size(); p++) {
                List<Decimal> values = new List<Decimal>();
                for (Decimal amount : inputs.productAmounts[p]) values.add((amount / inputs.entries[p].UnitPrice).round(System.RoundingMode.HALF_UP));
                inputs.productValues.add(values);
            }
        }
    }

    // ------------------------------------------------------------------ creation

    private static void createProductsAndSchedules(SalesAgreement agreement, PlanInputs inputs) {
        // Split each month across products by share; the last product takes any rounding remainder.
        List<SalesAgreementProduct> products = new List<SalesAgreementProduct>();
        for (Integer p = 0; p < inputs.entries.size(); p++) {
            PricebookEntry entry = inputs.entries[p];
            Decimal productTotal = 0;
            for (Decimal amount : inputs.productAmounts[p]) {
                productTotal += amount;
            }
            Boolean valueMode = inputs.modes[p] == 'Value';
            products.add(new SalesAgreementProduct(
                Name = entry.Product2.Name.left(80),
                SalesAgreementId = agreement.Id,
                PricebookEntryId = entry.Id,
                SalesPrice = valueMode ? 1 : entry.UnitPrice,
                IsQuantityInDecimals = valueMode,
                InitialPlannedQuantity = valueMode ? Math.max(1, productTotal.round(System.RoundingMode.HALF_UP).intValue()) : Math.max(1, (productTotal / entry.UnitPrice).round(System.RoundingMode.HALF_UP).intValue()),
                InitialPlannedQtyValue = valueMode ? productTotal : null,
                InitialPlannedAmount = productTotal,
                CurrencyIsoCode = inputs.currencyIsoCode
            ));
        }
        Database.insert(products, AccessLevel.USER_MODE);

        Map<Id, Integer> productIndex = new Map<Id, Integer>();
        for (Integer p = 0; p < products.size(); p++) {
            productIndex.put(products[p].Id, p);
        }
        List<SalesAgreementProductSchedule> schedules = [
            SELECT Id, StartDate, EndDate, SalesAgreementProductId
            FROM SalesAgreementProductSchedule WHERE SalesAgreementProductId IN :productIndex.keySet()
            WITH USER_MODE ORDER BY StartDate
        ];
        List<SalesAgreementProductSchedule> updates = new List<SalesAgreementProductSchedule>();
        for (SalesAgreementProductSchedule schedule : schedules) {
            Integer monthIndex = monthsBetween(inputs.startMonth, schedule.StartDate);
            if (monthIndex < 0 || monthIndex >= inputs.term || !isCalendarMonth(schedule)) {
                throw error('The native schedules did not align to calendar months; nothing was saved.');
            }
            Integer p = productIndex.get(schedule.SalesAgreementProductId);
            Decimal amount = inputs.productAmounts[p][monthIndex];
            Decimal quantity = inputs.productValues[p][monthIndex];
            Boolean valueMode = inputs.modes[p] == 'Value';
            updates.add(new SalesAgreementProductSchedule(
                Id = schedule.Id,
                PlannedQuantity = valueMode ? 0 : quantity.intValue(),
                ForecastedQuantity = valueMode ? 0 : quantity.intValue(),
                PlannedQuantityValue = quantity,
                ForecastedQuantityValue = quantity,
                Carlton_Value_Mode_CC__c = valueMode,
                SalesPrice = valueMode ? 1 : inputs.entries[p].UnitPrice,
                PlannedAmount = amount,
                ForecastedAmount = amount
            ));
        }
        if (updates.size() != inputs.term * products.size()) {
            throw error('Expected ' + (inputs.term * products.size()) + ' monthly schedules but the platform created '
                + updates.size() + '; nothing was saved.');
        }
        Database.update(updates, AccessLevel.USER_MODE);
    }

    private static void createMonthPlans(SalesAgreement agreement, Opportunity opp, PlanInputs inputs) {
        Id siteId = inputs.siteIds.isEmpty() ? null : inputs.siteIds[0];
        List<Agreement_Month_Plan_CC__c> plans = new List<Agreement_Month_Plan_CC__c>();
        for (Integer i = 0; i < inputs.term; i++) {
            Date month = inputs.startMonth.addMonths(i);
            plans.add(new Agreement_Month_Plan_CC__c(
                Sales_Agreement_CC__c = agreement.Id,
                Account_CC__c = opp.AccountId,
                Site_CC__c = siteId,
                Month_Start_CC__c = month,
                Original_Plan_Amount_CC__c = inputs.amounts[i],
                Current_Forecast_Amount_CC__c = inputs.amounts[i],
                CurrencyIsoCode = inputs.currencyIsoCode,
                Plan_Key_CC__c = planKey(agreement.Id, month, siteId)
            ));
        }
        // System mode by design: month plans are read-only to users (see class comment); access was checked above.
        Database.insert(plans, AccessLevel.SYSTEM_MODE);
    }

    private static void createAgreementSites(SalesAgreement agreement, PlanInputs inputs) {
        List<Sales_Agreement_Site_CC__c> sites = new List<Sales_Agreement_Site_CC__c>();
        for (Id siteId : inputs.siteIds) {
            sites.add(new Sales_Agreement_Site_CC__c(Sales_Agreement_CC__c = agreement.Id, Site_CC__c = siteId,
                Site_Key_CC__c = agreement.Id + '|' + siteId));
        }
        if (!sites.isEmpty()) {
            Database.insert(sites, AccessLevel.SYSTEM_MODE);
        }
    }

    // ------------------------------------------------------------------ helpers

    @TestVisible
    private static List<List<Decimal>> splitByShare(List<Decimal> amounts, List<Decimal> shares, Integer decimals) {
        List<List<Decimal>> result = new List<List<Decimal>>();
        for (Integer p = 0; p < shares.size(); p++) {
            result.add(new List<Decimal>());
        }
        for (Decimal amount : amounts) {
            Decimal allocated = 0;
            for (Integer p = 0; p < shares.size(); p++) {
                Decimal part = p == shares.size() - 1
                    ? amount - allocated
                    : (amount * shares[p] / 100).setScale(decimals, System.RoundingMode.HALF_UP);
                allocated += part;
                result[p].add(part);
            }
        }
        return result;
    }

    public static String planKey(Id agreementId, Date month, Id siteId) {
        return agreementId + '|' + DateTime.newInstance(month, Time.newInstance(0, 0, 0, 0)).format('yyyy-MM') + '|'
            + (siteId == null ? ENTITY_PLAN_SCOPE : String.valueOf(siteId));
    }

    private static Integer monthsBetween(Date startMonth, Date scheduleStart) {
        return (scheduleStart.year() - startMonth.year()) * 12 + scheduleStart.month() - startMonth.month();
    }

    private static Boolean isCalendarMonth(SalesAgreementProductSchedule schedule) {
        Date start = schedule.StartDate;
        return start.day() == 1 && schedule.EndDate == start.addMonths(1).addDays(-1);
    }

    public static Integer currencyDecimals(String isoCode) {
        List<CurrencyType> types = [SELECT DecimalPlaces FROM CurrencyType WHERE IsoCode = :isoCode LIMIT 1];
        return types.isEmpty() ? 2 : types[0].DecimalPlaces;
    }

    private static String currencyOf(Opportunity opp) {
        return (String) opp.get('CurrencyIsoCode');
    }

    private static String format(Decimal value, PlanInputs inputs) {
        return inputs.currencyIsoCode + ' ' + value.setScale(inputs.decimals).format();
    }

    private static Id pricebookFor(Opportunity opp) {
        if (opp.Pricebook2Id != null) {
            return opp.Pricebook2Id;
        }
        List<Pricebook2> standard = [SELECT Id FROM Pricebook2 WHERE IsStandard = true AND IsActive = true WITH USER_MODE LIMIT 1];
        return standard.isEmpty() ? null : standard[0].Id;
    }

    private static Opportunity loadOpportunity(Id opportunityId) {
        List<Opportunity> opps = [
            SELECT Id, Name, AccountId, Account.Name, Amount, StageName, IsClosed, IsWon, Pricebook2Id, CurrencyIsoCode,
                   Carlton_Monthly_Forecast_Plan_CC__c,
                   RecordType.DeveloperName
            FROM Opportunity WHERE Id = :opportunityId WITH USER_MODE
        ];
        if (opps.isEmpty()) {
            throw error('The Opportunity was not found or you cannot see it.');
        }
        return opps[0];
    }

    private static List<Option> productOptions(Opportunity opp, Id pricebookId) {
        List<Option> options = new List<Option>();
        Set<Id> seen = new Set<Id>();
        for (OpportunityLineItem line : [SELECT PricebookEntryId, Product2.Name, TotalPrice, PricebookEntry.UnitPrice FROM OpportunityLineItem
                                         WHERE OpportunityId = :opp.Id WITH USER_MODE]) {
            if (seen.add(line.PricebookEntryId)) {
                Option selected = option(line.PricebookEntryId, line.Product2.Name, line.TotalPrice, true);
                selected.unitPrice = line.PricebookEntry.UnitPrice;
                options.add(selected);
            }
        }
        if (pricebookId != null) {
            String isoCode = currencyOf(opp);
            for (PricebookEntry entry : [SELECT Id, Product2.Name, UnitPrice FROM PricebookEntry
                                         WHERE Pricebook2Id = :pricebookId AND IsActive = true AND CurrencyIsoCode = :isoCode
                                         AND UnitPrice > 0 WITH USER_MODE ORDER BY Product2.Name LIMIT 200]) {
                if (seen.add(entry.Id)) {
                    Option selected = option(entry.Id, entry.Product2.Name + ' (' + entry.UnitPrice.format() + ')', null, false);
                    selected.unitPrice = entry.UnitPrice;
                    options.add(selected);
                }
            }
        }
        return options;
    }

    private static List<Option> siteOptions(Id entityId) {
        List<Option> options = new List<Option>();
        for (Account site : AgreementSiteRules_CC.sitesOfEntity(entityId)) {
            options.add(option(site.Id, site.Name, null, false));
        }
        return options;
    }

    private static Option option(String value, String label, Decimal amount, Boolean fromOpportunity) {
        Option o = new Option();
        o.value = value;
        o.label = label;
        o.amount = amount;
        o.fromOpportunity = fromOpportunity;
        return o;
    }

    private static SalesAgreement existingAgreement(Id opportunityId) {
        String key = KEY_PREFIX + opportunityId;
        // System mode so a retry by a user who cannot see the agreement still finds it and never duplicates it.
        List<SalesAgreement> found = [SELECT Id, Name, Plan_Status_CC__c FROM SalesAgreement
                                      WHERE UI2_Creation_Key_CC__c = :key WITH SYSTEM_MODE LIMIT 1];
        return found.isEmpty() ? null : found[0];
    }

    private static PlanResult existingResult(SalesAgreement agreement, String message) {
        PlanResult result = new PlanResult();
        result.salesAgreementId = agreement.Id;
        result.alreadyExisted = true;
        result.planStatus = agreement.Plan_Status_CC__c;
        result.message = message;
        return result;
    }

    private static Boolean isDuplicateKey(Database.SaveResult saved) {
        for (Database.Error err : saved.getErrors()) {
            if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                return true;
            }
        }
        return false;
    }

    public static void requirePilot() {
        if (!FeatureManagement.checkPermission(PILOT_PERMISSION)) {
            throw error('You do not have access to the Opportunity UI2.');
        }
    }

    public static void requireEditAccess(Id recordId) {
        UserRecordAccess access = [SELECT RecordId, HasEditAccess FROM UserRecordAccess
                                   WHERE UserId = :UserInfo.getUserId() AND RecordId = :recordId];
        if (!access.HasEditAccess) {
            throw error('You need edit access to this record.');
        }
    }

    public static AuraHandledException error(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}