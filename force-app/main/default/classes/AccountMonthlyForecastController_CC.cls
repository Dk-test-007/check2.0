/**
 * Opportunity UI2: account monthly view for an Entity or a Site, one block per currency (never combined).
 *
 * Grain: Account + calendar month + currency. Every agreement counts once: plan and forecast come from
 * Agreement_Month_Plan_CC__c rows (one per agreement, month and Site share), never through the Opportunity/Site
 * junction or the Corporate Group hierarchy.
 * - Entity view: Original Plan and Current Forecast across all its agreements (Site-allocated and unallocated
 *   shares, each once); Order Actuals = native agreement schedule actuals.
 * - Site view: the Site's allocated plan shares (an Entity-wide unallocated plan is not copied to Sites); Order
 *   Actuals = activated release Orders shipped to the Site (Order Products' net amount), a Ship-To breakdown of the
 *   same Orders the native actuals count.
 * - Open new-business pipeline (BAU excluded) is reported separately from the run-rate plan.
 * - Term extension: outside an agreement's native term the Entity actuals are its activated Order lines (linked by
 *   SalesAgreementId or Agreement_Extension_CC__c, same rule as the agreement view). Actuals in an agreement-month with
 *   no plan row are Unplanned. Each currency block splits the year into original term, extension, unplanned, combined.
 */
public with sharing class AccountMonthlyForecastController_CC {

    private static final String KIND_ORIGINAL = 'ORIGINAL';
    private static final String KIND_EXTENSION = 'EXTENSION';
    private static final String KIND_UNPLANNED = 'UNPLANNED';

    public class MonthRow {
        /** Order Actuals in this month on agreements with no plan row for the month (included in orderActuals). */
        @AuraEnabled public Decimal unplannedActuals { get; set; }
        @AuraEnabled public Date monthStart { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String state { get; set; }
        @AuraEnabled public Decimal originalPlan { get; set; }
        @AuraEnabled public Decimal currentForecast { get; set; }
        @AuraEnabled public Decimal orderActuals { get; set; }
        @AuraEnabled public Decimal varianceToPlan { get; set; }
        @AuraEnabled public Decimal varianceToForecast { get; set; }
        @AuraEnabled public Decimal attainmentPercent { get; set; }
        @AuraEnabled public Decimal shortfall { get; set; }
        @AuraEnabled public Decimal pipeline { get; set; }
    }

    public class CurrencyBlock {
        @AuraEnabled public String currencyIsoCode { get; set; }
        @AuraEnabled public List<MonthRow> months { get; set; }
        @AuraEnabled public Decimal ytdPlan { get; set; }
        @AuraEnabled public Decimal ytdActuals { get; set; }
        @AuraEnabled public Decimal ytdVariance { get; set; }
        @AuraEnabled public Decimal ytdAttainmentPercent { get; set; }
        @AuraEnabled public Decimal yearPlan { get; set; }
        @AuraEnabled public Decimal yearForecast { get; set; }
        @AuraEnabled public Decimal expectedOutcome { get; set; }
        @AuraEnabled public Decimal gapToPlan { get; set; }
        @AuraEnabled public Decimal unallocatedPlan { get; set; }
        @AuraEnabled public Decimal openPipeline { get; set; }
        /** Site view only: Orders shipped to this Site on Entity-wide agreements (no Site plan to measure them against). */
        @AuraEnabled public Decimal entityWideShipToActuals { get; set; }
        @AuraEnabled public String periodLabel { get; set; }
        /** The year split by agreement-month: original term, extension months, unplanned months, and all combined. */
        @AuraEnabled public ForecastMetrics_CC.TermSplit originalTerm { get; set; }
        @AuraEnabled public ForecastMetrics_CC.TermSplit extension { get; set; }
        @AuraEnabled public ForecastMetrics_CC.TermSplit unplanned { get; set; }
        @AuraEnabled public ForecastMetrics_CC.TermSplit combined { get; set; }
        @AuraEnabled public List<Breakdown> agreements { get; set; }
        @AuraEnabled public List<Breakdown> sites { get; set; }
        @AuraEnabled public List<Breakdown> products { get; set; }
    }

    public class Breakdown {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String detail { get; set; }
        @AuraEnabled public Decimal originalPlan { get; set; }
        @AuraEnabled public Decimal currentForecast { get; set; }
        @AuraEnabled public Decimal orderActuals { get; set; }
        @AuraEnabled public Decimal unplannedActuals { get; set; }
    }

    public class AccountView {
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public Boolean isSite { get; set; }
        @AuraEnabled public Id entityId { get; set; }
        @AuraEnabled public String entityName { get; set; }
        @AuraEnabled public Integer year { get; set; }
        @AuraEnabled public Datetime oldestActualsCalculation { get; set; }
        @AuraEnabled public List<CurrencyBlock> currencies { get; set; }
        @AuraEnabled public List<String> exceptions { get; set; }
        @AuraEnabled public String basisNote { get; set; }
    }

    private class Bucket {
        Map<Date, Decimal> plan = new Map<Date, Decimal>();
        Map<Date, Decimal> forecast = new Map<Date, Decimal>();
        Map<Date, Decimal> actuals = new Map<Date, Decimal>();
        Map<Date, Decimal> pipeline = new Map<Date, Decimal>();
        Map<String, Map<Date, Decimal>> planByKind = kindMaps();
        Map<String, Map<Date, Decimal>> forecastByKind = kindMaps();
        Map<String, Map<Date, Decimal>> actualsByKind = kindMaps();
        Decimal unallocated = 0;
        Decimal entityWideShipTo = 0;
        Map<Id, Breakdown> agreements = new Map<Id, Breakdown>();
        Map<String, Breakdown> sites = new Map<String, Breakdown>();
        Map<String, Breakdown> products = new Map<String, Breakdown>();
    }

    @AuraEnabled
    public static AccountView getAccountView(Id accountId, Integer year) {
        SalesAgreementPlanService_CC.requirePilot();
        Account acc = [SELECT Id, Name, ParentId, Parent.Name, RecordType.DeveloperName FROM Account WHERE Id = :accountId WITH USER_MODE];
        AccountView view = new AccountView();
        view.accountId = acc.Id;
        view.accountName = acc.Name;
        view.isSite = acc.RecordType.DeveloperName == AgreementSiteRules_CC.SITE_RECORD_TYPE;
        view.entityId = view.isSite ? acc.ParentId : acc.Id;
        view.entityName = view.isSite ? acc.Parent.Name : acc.Name;
        view.year = year == null ? Date.today().year() : year;
        Date yearStart = Date.newInstance(view.year, 1, 1);
        Date yearEnd = Date.newInstance(view.year, 12, 31);
        Date today = Date.today();

        Map<String, Bucket> buckets = new Map<String, Bucket>();
        Map<Id, SalesAgreement> agreements = new Map<Id, SalesAgreement>([
            SELECT Id, Name, CurrencyIsoCode, Commercial_Scope_CC__c, Status, LastActualsCalculatedDate, StartDate, EndDate,
                   Extended_Through_CC__c
            FROM SalesAgreement WHERE AccountId = :view.entityId WITH USER_MODE
        ]);
        // agreementId|month -> extension month? Absent = no plan row for that agreement-month here (Unplanned).
        Map<String, Boolean> planKinds = new Map<String, Boolean>();
        Map<Id, Set<Date>> unplannedByAgreement = new Map<Id, Set<Date>>();
        for (SalesAgreement agreement : agreements.values()) {
            if (agreement.LastActualsCalculatedDate != null && (view.oldestActualsCalculation == null
                    || agreement.LastActualsCalculatedDate < view.oldestActualsCalculation)) {
                view.oldestActualsCalculation = agreement.LastActualsCalculatedDate;
            }
        }

        // Plan and forecast, each month-plan row once. Month plans are readable org-wide, so keep only the agreements this
        // user can see - the same set the native actuals below come from - so plan and actuals never disagree.
        String planFilter = view.isSite ? 'Site_CC__c = :accountId' : 'Account_CC__c = :entityId';
        Id entityId = view.entityId;
        Set<Id> visibleAgreementIds = agreements.keySet();
        Set<Id> plannedHere = new Set<Id>();
        for (Agreement_Month_Plan_CC__c plan : Database.query(
                'SELECT Sales_Agreement_CC__c, Sales_Agreement_CC__r.Name, Site_CC__c, Site_CC__r.Name, Month_Start_CC__c, '
                + 'CurrencyIsoCode, Original_Plan_Amount_CC__c, Current_Forecast_Amount_CC__c, Is_Extension_CC__c FROM Agreement_Month_Plan_CC__c '
                + 'WHERE ' + planFilter + ' AND Sales_Agreement_CC__c IN :visibleAgreementIds '
                + 'AND Month_Start_CC__c >= :yearStart AND Month_Start_CC__c <= :yearEnd WITH USER_MODE')) {
            Bucket b = bucket(buckets, plan.CurrencyIsoCode);
            plannedHere.add(plan.Sales_Agreement_CC__c);
            ForecastMetrics_CC.add(b.plan, plan.Month_Start_CC__c, plan.Original_Plan_Amount_CC__c);
            ForecastMetrics_CC.add(b.forecast, plan.Month_Start_CC__c, plan.Current_Forecast_Amount_CC__c);
            String kind = plan.Is_Extension_CC__c ? KIND_EXTENSION : KIND_ORIGINAL;
            ForecastMetrics_CC.add(b.planByKind.get(kind), plan.Month_Start_CC__c, plan.Original_Plan_Amount_CC__c);
            ForecastMetrics_CC.add(b.forecastByKind.get(kind), plan.Month_Start_CC__c, plan.Current_Forecast_Amount_CC__c);
            planKinds.put(kindKey(plan.Sales_Agreement_CC__c, plan.Month_Start_CC__c), plan.Is_Extension_CC__c);
            if (plan.Site_CC__c == null) {
                b.unallocated += plan.Current_Forecast_Amount_CC__c;
            }
            Breakdown agreementRow = breakdown(b.agreements, plan.Sales_Agreement_CC__c, plan.Sales_Agreement_CC__r.Name,
                agreementDetail(agreements.get(plan.Sales_Agreement_CC__c)));
            agreementRow.originalPlan += plan.Original_Plan_Amount_CC__c;
            agreementRow.currentForecast += plan.Current_Forecast_Amount_CC__c;
            String siteKey = plan.Site_CC__c == null ? 'UNALLOCATED' : String.valueOf(plan.Site_CC__c);
            Breakdown siteRow = breakdown(b.sites, siteKey, plan.Site_CC__c == null ? 'Unallocated (Entity-wide plan)' : plan.Site_CC__r.Name, null);
            siteRow.recordId = plan.Site_CC__c;
            siteRow.originalPlan += plan.Original_Plan_Amount_CC__c;
            siteRow.currentForecast += plan.Current_Forecast_Amount_CC__c;
        }

        if (!view.isSite) {
            // Entity: native agreement actuals per month, and per product.
            // Summed in Apex, never with SOQL SUM(): aggregates on currency fields convert to the user's currency.
            for (SalesAgreementProductSchedule schedule : [
                    SELECT SalesAgreementProduct.SalesAgreementId, SalesAgreementProduct.SalesAgreement.CurrencyIsoCode,
                           SalesAgreementProduct.Name, StartDate, ActualAmount, DerivedPlannedAmount, ForecastedAmount
                    FROM SalesAgreementProductSchedule
                    WHERE SalesAgreementProduct.SalesAgreement.AccountId = :entityId AND StartDate >= :yearStart AND StartDate <= :yearEnd
                    WITH USER_MODE]) {
                Bucket b = bucket(buckets, schedule.SalesAgreementProduct.SalesAgreement.CurrencyIsoCode);
                Decimal actual = decimalOf(schedule.ActualAmount);
                Id agreementId = schedule.SalesAgreementProduct.SalesAgreementId;
                SalesAgreement agreement = agreements.get(agreementId);
                Breakdown agreementRow = breakdown(b.agreements, agreementId, agreement?.Name, agreementDetail(agreement));
                addActual(b, planKinds, unplannedByAgreement, agreementRow, agreementId, schedule.StartDate, actual);
                String productName = schedule.SalesAgreementProduct.Name;
                Breakdown productRow = breakdown(b.products, productName, productName, null);
                productRow.originalPlan += decimalOf(schedule.DerivedPlannedAmount);
                productRow.currentForecast += decimalOf(schedule.ForecastedAmount);
                productRow.orderActuals += actual;
            }
            // Outside each agreement's native term: activated Order lines, same rule as the agreement view.
            for (SalesAgreementForecastService_CC.OrderActual line :
                    SalesAgreementForecastService_CC.orderActualsOutsideNativeTerm(agreements, yearStart, yearEnd)) {
                SalesAgreement agreement = agreements.get(line.agreementId);
                Bucket b = bucket(buckets, agreement.CurrencyIsoCode);
                Breakdown agreementRow = breakdown(b.agreements, line.agreementId, agreement.Name, agreementDetail(agreement));
                addActual(b, planKinds, unplannedByAgreement, agreementRow, line.agreementId, line.month, line.amount);
                breakdown(b.products, line.productName, line.productName, null).orderActuals += line.amount;
            }
        }

        // Ship-To breakdown of activated release Orders (Site view actuals; Entity view Site drill-down).
        String orderFilter = view.isSite ? 'Order.Ship_to_Customer_No_CC__c = :accountId' : 'Order.AccountId = :entityId';
        for (OrderItem item : Database.query(
                'SELECT Order.CurrencyIsoCode, Order.SalesAgreementId, Order.Agreement_Extension_CC__c, Order.Ship_to_Customer_No_CC__c, '
                + 'Order.Ship_to_Customer_No_CC__r.Name, Order.EffectiveDate, TotalPrice FROM OrderItem WHERE ' + orderFilter
                + ' AND (Order.SalesAgreementId != null OR Order.Agreement_Extension_CC__c != null) '
                + 'AND Order.StatusCode = \'Activated\' AND Order.EffectiveDate >= :yearStart AND Order.EffectiveDate <= :yearEnd '
                + 'WITH USER_MODE')) {
            Bucket b = bucket(buckets, item.Order.CurrencyIsoCode);
            Decimal amount = decimalOf(item.TotalPrice);
            Date month = Date.newInstance(item.Order.EffectiveDate.year(), item.Order.EffectiveDate.month(), 1);
            Id agreementId = item.Order.SalesAgreementId != null ? item.Order.SalesAgreementId : item.Order.Agreement_Extension_CC__c;
            // Site view: only Orders on agreements planned at this Site count against its plan; Orders shipped here on
            // Entity-wide agreements are reported apart, so attainment compares like with like.
            if (view.isSite && plannedHere.contains(agreementId)) {
                SalesAgreement agreement = agreements.get(agreementId);
                Breakdown agreementRow = breakdown(b.agreements, agreementId, agreement?.Name, agreementDetail(agreement));
                addActual(b, planKinds, unplannedByAgreement, agreementRow, agreementId, month, amount);
            } else if (view.isSite) {
                b.entityWideShipTo += amount;
            }
            Id siteId = item.Order.Ship_to_Customer_No_CC__c;
            String siteKey = siteId == null ? 'NO_SHIP_TO' : String.valueOf(siteId);
            Breakdown siteRow = breakdown(b.sites, siteKey, siteId == null ? 'No Ship-To Site' : item.Order.Ship_to_Customer_No_CC__r.Name, null);
            siteRow.recordId = siteId;
            siteRow.orderActuals += amount;
        }

        // Open new-business pipeline, BAU excluded, kept apart from the run-rate plan.
        if (!view.isSite) {
            for (Opportunity opp : [
                    SELECT CurrencyIsoCode, CloseDate, Amount FROM Opportunity
                    WHERE AccountId = :entityId AND IsClosed = false AND RecordType.DeveloperName = :SalesAgreementPlanService_CC.NEW_BUSINESS
                    AND BAU_Opportunity_CC__c = false AND CloseDate >= :yearStart AND CloseDate <= :yearEnd WITH USER_MODE]) {
                Bucket b = bucket(buckets, opp.CurrencyIsoCode);
                ForecastMetrics_CC.add(b.pipeline, Date.newInstance(opp.CloseDate.year(), opp.CloseDate.month(), 1), decimalOf(opp.Amount));
            }
        }

        view.currencies = new List<CurrencyBlock>();
        List<String> isoCodes = new List<String>(buckets.keySet());
        isoCodes.sort();
        for (String iso : isoCodes) {
            view.currencies.add(block(iso, buckets.get(iso), view.year, today, view.isSite));
        }
        view.exceptions = exceptions(view, agreements, yearStart, yearEnd);
        for (Id agreementId : unplannedByAgreement.keySet()) {
            view.exceptions.add(agreements.get(agreementId)?.Name + ' has activated Orders in ' + unplannedByAgreement.get(agreementId).size()
                + ' month(s) with no plan; they count in Order Actuals and are shown as Unplanned.');
        }
        view.basisNote = 'Net Order Product amounts excluding tax and freight. Order Actuals are activated release Orders on '
            + 'the agreements, not invoices or payments. Each currency is shown separately; no conversion is applied.';
        return view;
    }

    private static CurrencyBlock block(String iso, Bucket b, Integer year, Date today, Boolean isSite) {
        CurrencyBlock block = new CurrencyBlock();
        block.currencyIsoCode = iso;
        block.months = new List<MonthRow>();
        block.ytdPlan = 0;
        block.ytdActuals = 0;
        block.openPipeline = 0;
        // Unplanned months join the period with a forecast of 0, so their actuals count in the combined measures.
        Map<Date, Decimal> unplannedForecast = new Map<Date, Decimal>();
        for (Date month : b.actualsByKind.get(KIND_UNPLANNED).keySet()) {
            ForecastMetrics_CC.add(b.forecast, month, 0);
            unplannedForecast.put(month, 0);
        }
        for (Integer m = 1; m <= 12; m++) {
            Date month = Date.newInstance(year, m, 1);
            MonthRow row = new MonthRow();
            row.monthStart = month;
            row.label = ForecastMetrics_CC.label(month);
            row.state = ForecastMetrics_CC.monthState(month, today);
            row.originalPlan = ForecastMetrics_CC.valueOf(b.plan, month);
            row.currentForecast = ForecastMetrics_CC.valueOf(b.forecast, month);
            row.orderActuals = ForecastMetrics_CC.valueOf(b.actuals, month);
            row.unplannedActuals = ForecastMetrics_CC.valueOf(b.actualsByKind.get(KIND_UNPLANNED), month);
            row.varianceToPlan = row.orderActuals - row.originalPlan;
            row.varianceToForecast = row.orderActuals - row.currentForecast;
            row.attainmentPercent = ForecastMetrics_CC.attainment(row.orderActuals, row.originalPlan);
            row.shortfall = row.state == ForecastMetrics_CC.COMPLETED ? Math.max(0, row.originalPlan - row.orderActuals) : null;
            row.pipeline = ForecastMetrics_CC.valueOf(b.pipeline, month);
            block.openPipeline += row.pipeline;
            if (row.state == ForecastMetrics_CC.COMPLETED) {
                block.ytdPlan += row.originalPlan;
                block.ytdActuals += row.orderActuals;
            }
            block.months.add(row);
        }
        ForecastMetrics_CC.PeriodTotals period = ForecastMetrics_CC.periodTotals(b.plan, b.forecast, b.actuals, today);
        block.ytdVariance = block.ytdActuals - block.ytdPlan;
        block.ytdAttainmentPercent = ForecastMetrics_CC.attainment(block.ytdActuals, block.ytdPlan);
        block.yearPlan = period.originalPlan;
        block.yearForecast = period.currentForecast;
        block.expectedOutcome = period.expectedOutcome;
        block.gapToPlan = period.originalPlan - period.expectedOutcome;
        block.unallocatedPlan = isSite ? null : b.unallocated;
        block.entityWideShipToActuals = isSite ? b.entityWideShipTo : null;
        block.periodLabel = 'Calendar ' + year + '. YTD = completed months. ' + period.label;
        block.originalTerm = ForecastMetrics_CC.termSplit(SalesAgreementForecastService_CC.ORIGINAL_TERM,
            b.planByKind.get(KIND_ORIGINAL), b.forecastByKind.get(KIND_ORIGINAL), b.actualsByKind.get(KIND_ORIGINAL), today);
        block.extension = ForecastMetrics_CC.termSplit(SalesAgreementForecastService_CC.EXTENSION,
            b.planByKind.get(KIND_EXTENSION), b.forecastByKind.get(KIND_EXTENSION), b.actualsByKind.get(KIND_EXTENSION), today);
        block.unplanned = ForecastMetrics_CC.termSplit(SalesAgreementForecastService_CC.UNPLANNED,
            new Map<Date, Decimal>(), unplannedForecast, b.actualsByKind.get(KIND_UNPLANNED), today);
        block.combined = ForecastMetrics_CC.termSplit('Combined', b.plan, b.forecast, b.actuals, today);
        block.agreements = b.agreements.values();
        block.sites = b.sites.values();
        block.products = b.products.values();
        return block;
    }

    private static List<String> exceptions(AccountView view, Map<Id, SalesAgreement> agreements, Date yearStart, Date yearEnd) {
        List<String> notes = new List<String>();
        Id entityId = view.entityId;
        Integer unassigned = [SELECT COUNT() FROM Order WHERE AccountId = :entityId AND SalesAgreementId = null
                              AND Agreement_Extension_CC__c = null AND StatusCode = 'Activated' AND EffectiveDate >= :yearStart AND EffectiveDate <= :yearEnd WITH USER_MODE];
        if (unassigned > 0) {
            notes.add(unassigned + ' activated Order(s) this year are not assigned to any Sales Agreement and are not in Order Actuals.');
        }
        Integer hidden = [SELECT COUNT() FROM SalesAgreement WHERE AccountId = :entityId WITH SYSTEM_MODE] - agreements.size();
        if (hidden > 0) {
            notes.add(hidden + ' Sales Agreement(s) at this Entity are not shared with you and are excluded from plan, forecast and actuals.');
        }
        Map<Id, Set<Id>> productsByAgreement = new Map<Id, Set<Id>>();
        for (SalesAgreementProduct product : [SELECT SalesAgreementId, PricebookEntry.Product2Id FROM SalesAgreementProduct
                                              WHERE SalesAgreementId IN :agreements.keySet() WITH USER_MODE]) {
            if (!productsByAgreement.containsKey(product.SalesAgreementId)) {
                productsByAgreement.put(product.SalesAgreementId, new Set<Id>());
            }
            productsByAgreement.get(product.SalesAgreementId).add(product.PricebookEntry.Product2Id);
        }
        Integer unmatched = 0;
        Set<Id> agreementIds = agreements.keySet();
        for (OrderItem item : [SELECT Order.SalesAgreementId, Order.Agreement_Extension_CC__c, Product2Id FROM OrderItem
                               WHERE (Order.SalesAgreementId IN :agreementIds OR Order.Agreement_Extension_CC__c IN :agreementIds)
                               AND Order.StatusCode = 'Activated'
                               AND Order.EffectiveDate >= :yearStart AND Order.EffectiveDate <= :yearEnd WITH USER_MODE]) {
            Id agreementId = item.Order.SalesAgreementId != null ? item.Order.SalesAgreementId : item.Order.Agreement_Extension_CC__c;
            Set<Id> allowed = productsByAgreement.get(agreementId);
            if (allowed == null || !allowed.contains(item.Product2Id)) {
                unmatched++;
            }
        }
        if (unmatched > 0) {
            notes.add(unmatched + ' Order Product line(s) on agreement Orders are for products not on that agreement; Order Actuals do not count them.');
        }
        // Overlapping agreements: same product in more than one agreement for the same month. Attribution follows
        // each Order's own SalesAgreementId, so nothing is credited twice; listed so the overlap is visible.
        Map<String, Set<Id>> agreementsByProductMonth = new Map<String, Set<Id>>();
        for (SalesAgreementProductSchedule schedule : [
                SELECT StartDate, SalesAgreementProduct.SalesAgreementId, SalesAgreementProduct.PricebookEntry.Product2Id
                FROM SalesAgreementProductSchedule WHERE SalesAgreementProduct.SalesAgreementId IN :agreements.keySet()
                AND StartDate >= :yearStart AND StartDate <= :yearEnd WITH USER_MODE]) {
            String key = schedule.SalesAgreementProduct.PricebookEntry.Product2Id + '|' + schedule.StartDate;
            if (!agreementsByProductMonth.containsKey(key)) {
                agreementsByProductMonth.put(key, new Set<Id>());
            }
            agreementsByProductMonth.get(key).add(schedule.SalesAgreementProduct.SalesAgreementId);
        }
        Integer overlaps = 0;
        for (Set<Id> ids : agreementsByProductMonth.values()) {
            if (ids.size() > 1) {
                overlaps++;
            }
        }
        if (overlaps > 0) {
            notes.add(overlaps + ' product-month(s) are covered by more than one agreement. Each Order counts only for the agreement it is placed on.');
        }
        for (SalesAgreement agreement : agreements.values()) {
            if (agreement.Status != 'Activated') {
                notes.add(agreement.Name + ' is ' + agreement.Status + '; native actuals are calculated for activated agreements.');
            }
        }
        return notes;
    }

    private static Map<String, Map<Date, Decimal>> kindMaps() {
        return new Map<String, Map<Date, Decimal>>{
            KIND_ORIGINAL => new Map<Date, Decimal>(),
            KIND_EXTENSION => new Map<Date, Decimal>(),
            KIND_UNPLANNED => new Map<Date, Decimal>()
        };
    }

    private static String kindKey(Id agreementId, Date month) {
        return agreementId + '|' + String.valueOf(month);
    }

    /** Adds an agreement-month's actual to the month, the agreement row and its slice (original, extension, unplanned). */
    private static void addActual(Bucket b, Map<String, Boolean> planKinds, Map<Id, Set<Date>> unplannedByAgreement,
            Breakdown agreementRow, Id agreementId, Date month, Decimal amount) {
        ForecastMetrics_CC.add(b.actuals, month, amount);
        agreementRow.orderActuals += amount;
        String key = kindKey(agreementId, month);
        String kind = !planKinds.containsKey(key) ? KIND_UNPLANNED : (planKinds.get(key) ? KIND_EXTENSION : KIND_ORIGINAL);
        ForecastMetrics_CC.add(b.actualsByKind.get(kind), month, amount);
        if (kind == KIND_UNPLANNED && amount != 0) {
            agreementRow.unplannedActuals += amount;
            if (!unplannedByAgreement.containsKey(agreementId)) {
                unplannedByAgreement.put(agreementId, new Set<Date>());
            }
            unplannedByAgreement.get(agreementId).add(month);
        }
    }

    private static String agreementDetail(SalesAgreement agreement) {
        if (agreement == null) {
            return null;
        }
        return agreement.Extended_Through_CC__c == null ? agreement.Commercial_Scope_CC__c
            : agreement.Commercial_Scope_CC__c + ' · extended through ' + agreement.Extended_Through_CC__c.format();
    }

    private static Bucket bucket(Map<String, Bucket> buckets, String iso) {
        if (!buckets.containsKey(iso)) {
            buckets.put(iso, new Bucket());
        }
        return buckets.get(iso);
    }

    private static Breakdown breakdown(Map<Id, Breakdown> rows, Id key, String name, String detail) {
        if (!rows.containsKey(key)) {
            rows.put(key, newBreakdown(key, name, detail));
        }
        return rows.get(key);
    }

    private static Breakdown breakdown(Map<String, Breakdown> rows, String key, String name, String detail) {
        if (!rows.containsKey(key)) {
            rows.put(key, newBreakdown(null, name, detail));
        }
        return rows.get(key);
    }

    private static Breakdown newBreakdown(Id recordId, String name, String detail) {
        Breakdown row = new Breakdown();
        row.recordId = recordId;
        row.name = name;
        row.detail = detail;
        row.originalPlan = 0;
        row.currentForecast = 0;
        row.orderActuals = 0;
        row.unplannedActuals = 0;
        return row;
    }

    private static Decimal decimalOf(Object value) {
        return value == null ? 0 : (Decimal) value;
    }
}