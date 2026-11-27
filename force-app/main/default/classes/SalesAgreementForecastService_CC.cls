/**
 * Opportunity UI2: one agreement's monthly plan, forecast revisions and native actuals recalculation.
 *
 * - Original plan (Agreement_Month_Plan_CC__c.Original_Plan_Amount_CC__c) never changes.
 * - Revise Forecast changes Current Forecast only, records an Agreement Forecast Revision with the reason, and keeps
 *   the native schedules' ForecastedAmount in step (split across the month's products by their planned share).
 *   It never changes the Opportunity Amount, and the initial equality gate is not reapplied.
 * - Order Actuals inside the native term are the native schedules' ActualAmount (actuals mode Orders: activated Orders
 *   on the agreement). Recalculate calls the standard refreshActualsCalculation action, which runs asynchronously.
 * - Term extension: an Activated agreement refuses ScheduleCount and EndDate changes (Under Revision too) and cannot
 *   return to Draft or Approved, so extension months exist only as month plans (Is_Extension_CC__c, Original Plan 0).
 *   The platform also refuses Order.SalesAgreementId when the Order date is outside StartDate-EndDate, so Orders after
 *   the native term carry Order.Agreement_Extension_CC__c. Actuals outside the native term are summed in Apex from the
 *   activated Order lines linked either way (agreement products, agreement currency).
 * - Months with such Orders but no plan row are shown as Unplanned; totals are split into original term, extension,
 *   unplanned and combined.
 */
public with sharing class SalesAgreementForecastService_CC {

    public static final String ORIGINAL_TERM = 'Original term';
    public static final String EXTENSION = 'Extension';
    public static final String UNPLANNED = 'Unplanned';
    public static final String SOURCE_NATIVE = 'Native schedules';
    public static final String SOURCE_ORDERS = 'Orders';

    public class MonthRow implements Comparable {
        @AuraEnabled public String rowKey { get; set; }
        @AuraEnabled public Id monthPlanId { get; set; }
        @AuraEnabled public Boolean isExtension { get; set; }
        @AuraEnabled public Boolean isUnplanned { get; set; }
        @AuraEnabled public String rowType { get; set; }
        @AuraEnabled public String actualsSource { get; set; }
        @AuraEnabled public Date monthStart { get; set; }
        @AuraEnabled public String siteName { get; set; }
        @AuraEnabled public Decimal originalPlan { get; set; }
        @AuraEnabled public Decimal currentForecast { get; set; }
        @AuraEnabled public Decimal orderActuals { get; set; }
        @AuraEnabled public Decimal varianceToPlan { get; set; }
        @AuraEnabled public Decimal attainmentPercent { get; set; }
        @AuraEnabled public String monthState { get; set; }
        @AuraEnabled public String lastReason { get; set; }

        public Integer compareTo(Object other) {
            MonthRow that = (MonthRow) other;
            if (monthStart != that.monthStart) {
                return monthStart < that.monthStart ? -1 : 1;
            }
            String mine = siteName == null ? '' : siteName;
            return mine.compareTo(that.siteName == null ? '' : that.siteName);
        }
    }

    public class AgreementView {
        /** Native term (cannot change once Activated). */
        @AuraEnabled public Date nativeStartDate { get; set; }
        @AuraEnabled public Date nativeEndDate { get; set; }
        /** Last day of the last planned month; Extended_Through_CC__c when the plan runs past the native term. */
        @AuraEnabled public Date coveredThrough { get; set; }
        @AuraEnabled public Date extendedThrough { get; set; }
        @AuraEnabled public Date nextExtensionMonth { get; set; }
        @AuraEnabled public Integer extensionMonths { get; set; }
        @AuraEnabled public Integer currencyDecimals { get; set; }
        @AuraEnabled public Boolean canExtend { get; set; }
        @AuraEnabled public Id agreementId { get; set; }
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public Boolean canReviseAgreement { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String planStatus { get; set; }
        @AuraEnabled public String planStatusDetail { get; set; }
        @AuraEnabled public String currencyIsoCode { get; set; }
        @AuraEnabled public String scope { get; set; }
        @AuraEnabled public Decimal originalWinAmount { get; set; }
        @AuraEnabled public Id sourceOpportunityId { get; set; }
        @AuraEnabled public String sourceOpportunityName { get; set; }
        @AuraEnabled public Datetime lastActualsCalculated { get; set; }
        @AuraEnabled public List<MonthRow> months { get; set; }
        @AuraEnabled public List<Revision> revisions { get; set; }
        @AuraEnabled public Totals totals { get; set; }
    }

    /** The top-level measures are the combined period (original term + extension + unplanned months). */
    public class Totals {
        @AuraEnabled public ForecastMetrics_CC.TermSplit originalTerm { get; set; }
        @AuraEnabled public ForecastMetrics_CC.TermSplit extension { get; set; }
        @AuraEnabled public ForecastMetrics_CC.TermSplit unplanned { get; set; }
        @AuraEnabled public ForecastMetrics_CC.TermSplit combined { get; set; }
        @AuraEnabled public Decimal originalPlan { get; set; }
        @AuraEnabled public Decimal currentForecast { get; set; }
        @AuraEnabled public Decimal completedPlan { get; set; }
        @AuraEnabled public Decimal completedActuals { get; set; }
        @AuraEnabled public Decimal completedVariance { get; set; }
        @AuraEnabled public Decimal completedAttainmentPercent { get; set; }
        @AuraEnabled public Decimal expectedOutcome { get; set; }
        @AuraEnabled public Decimal gapToOriginalPlan { get; set; }
        @AuraEnabled public String periodLabel { get; set; }
    }

    public class Revision {
        @AuraEnabled public Date monthStart { get; set; }
        @AuraEnabled public Decimal previousForecast { get; set; }
        @AuraEnabled public Decimal newForecast { get; set; }
        @AuraEnabled public String reason { get; set; }
        @AuraEnabled public String revisedBy { get; set; }
        @AuraEnabled public Datetime revisedAt { get; set; }
    }

    public class MonthChange {
        @AuraEnabled public Id monthPlanId { get; set; }
        @AuraEnabled public Decimal newForecast { get; set; }
    }

    // ------------------------------------------------------------------ read

    @AuraEnabled
    public static AgreementView getAgreementView(Id agreementId) {
        SalesAgreementPlanService_CC.requirePilot();
        SalesAgreement agreement = [
            SELECT Id, Name, AccountId, Status, Plan_Status_CC__c, Plan_Status_Detail_CC__c, CurrencyIsoCode, Commercial_Scope_CC__c,
                   Original_Win_Amount_CC__c, Source_Opportunity_CC__c, Source_Opportunity_CC__r.Name, LastActualsCalculatedDate,
                   StartDate, EndDate, Extended_Through_CC__c
            FROM SalesAgreement WHERE Id = :agreementId WITH USER_MODE
        ];
        Date today = Date.today();
        AgreementView view = new AgreementView();
        view.nativeStartDate = agreement.StartDate;
        view.nativeEndDate = agreement.EndDate;
        view.extendedThrough = agreement.Extended_Through_CC__c;
        view.currencyDecimals = SalesAgreementPlanService_CC.currencyDecimals(agreement.CurrencyIsoCode);
        view.agreementId = agreement.Id;
        view.accountId = agreement.AccountId;
        view.canReviseAgreement = FeatureManagement.checkPermission('Carlton_Revise_Agreement');
        view.name = agreement.Name;
        view.status = agreement.Status;
        view.planStatus = agreement.Plan_Status_CC__c;
        view.planStatusDetail = agreement.Plan_Status_Detail_CC__c;
        view.currencyIsoCode = agreement.CurrencyIsoCode;
        view.scope = agreement.Commercial_Scope_CC__c;
        view.originalWinAmount = agreement.Original_Win_Amount_CC__c;
        view.sourceOpportunityId = agreement.Source_Opportunity_CC__c;
        view.sourceOpportunityName = agreement.Source_Opportunity_CC__r?.Name;
        view.lastActualsCalculated = agreement.LastActualsCalculatedDate;

        // Native schedule actuals inside the native term; activated Order lines outside it (summed in Apex).
        Map<Date, Decimal> actualsByMonth = new Map<Date, Decimal>();
        Map<Date, Decimal> nativeActuals = nativeActualsByMonth(new Set<Id>{ agreementId }).get(agreementId);
        if (nativeActuals != null) {
            actualsByMonth.putAll(nativeActuals);
        }
        Set<Date> orderMonths = new Set<Date>();
        for (OrderActual line : orderActualsOutsideNativeTerm(new Map<Id, SalesAgreement>{ agreementId => agreement }, null, null)) {
            ForecastMetrics_CC.add(actualsByMonth, line.month, line.amount);
            orderMonths.add(line.month);
        }
        view.months = new List<MonthRow>();
        Map<Date, Integer> rowsPerMonth = new Map<Date, Integer>();
        List<Agreement_Month_Plan_CC__c> plans = monthPlans(agreementId);
        Date lastPlanned;
        view.extensionMonths = 0;
        for (Agreement_Month_Plan_CC__c plan : plans) {
            Integer count = rowsPerMonth.get(plan.Month_Start_CC__c);
            rowsPerMonth.put(plan.Month_Start_CC__c, count == null ? 1 : count + 1);
            lastPlanned = lastPlanned == null || plan.Month_Start_CC__c > lastPlanned ? plan.Month_Start_CC__c : lastPlanned;
            view.extensionMonths += plan.Is_Extension_CC__c ? 1 : 0;
        }
        for (Agreement_Month_Plan_CC__c plan : plans) {
            MonthRow row = new MonthRow();
            row.rowKey = plan.Id;
            row.monthPlanId = plan.Id;
            row.monthStart = plan.Month_Start_CC__c;
            row.isExtension = plan.Is_Extension_CC__c;
            row.isUnplanned = false;
            row.rowType = plan.Is_Extension_CC__c ? EXTENSION : ORIGINAL_TERM;
            row.actualsSource = isNativeMonth(agreement, plan.Month_Start_CC__c) ? SOURCE_NATIVE : SOURCE_ORDERS;
            row.siteName = plan.Site_CC__c == null ? 'Unallocated (Entity)' : plan.Site_CC__r.Name;
            row.originalPlan = plan.Original_Plan_Amount_CC__c;
            row.currentForecast = plan.Current_Forecast_Amount_CC__c;
            // Actuals are per agreement month; shown on the month's row only when the month has one row.
            Decimal actual = actualsByMonth.get(plan.Month_Start_CC__c);
            row.orderActuals = rowsPerMonth.get(plan.Month_Start_CC__c) == 1 ? (actual == null ? 0 : actual) : null;
            row.monthState = ForecastMetrics_CC.monthState(plan.Month_Start_CC__c, today);
            if (row.orderActuals != null) {
                row.varianceToPlan = row.orderActuals - row.originalPlan;
                row.attainmentPercent = ForecastMetrics_CC.attainment(row.orderActuals, row.originalPlan);
            }
            row.lastReason = plan.Last_Revision_Reason_CC__c;
            view.months.add(row);
        }
        // Orders in a month with no plan row (for example an Order that arrived without going through Enter PO).
        Set<Date> unplannedMonths = new Set<Date>();
        for (Date month : orderMonths) {
            if (!rowsPerMonth.containsKey(month)) {
                unplannedMonths.add(month);
                view.months.add(unplannedRow(month, actualsByMonth.get(month), today));
            }
        }
        view.months.sort();
        view.coveredThrough = lastPlanned == null ? null : lastPlanned.addMonths(1).addDays(-1);
        view.nextExtensionMonth = lastPlanned == null ? null : lastPlanned.addMonths(1);
        view.canExtend = lastPlanned != null && agreement.Status != 'Cancelled';
        view.totals = totals(plans, actualsByMonth, unplannedMonths, today);
        view.revisions = new List<Revision>();
        for (Agreement_Forecast_Revision_CC__c revision : [
                SELECT Month_Plan_CC__r.Month_Start_CC__c, Previous_Forecast_CC__c, New_Forecast_CC__c, Reason_CC__c,
                       CreatedBy.Name, CreatedDate
                FROM Agreement_Forecast_Revision_CC__c WHERE Month_Plan_CC__r.Sales_Agreement_CC__c = :agreementId
                WITH USER_MODE ORDER BY CreatedDate DESC, Name DESC LIMIT 200]) {
            Revision r = new Revision();
            r.monthStart = revision.Month_Plan_CC__r.Month_Start_CC__c;
            r.previousForecast = revision.Previous_Forecast_CC__c;
            r.newForecast = revision.New_Forecast_CC__c;
            r.reason = revision.Reason_CC__c;
            r.revisedBy = revision.CreatedBy.Name;
            r.revisedAt = revision.CreatedDate;
            view.revisions.add(r);
        }
        return view;
    }

    private static MonthRow unplannedRow(Date month, Decimal actual, Date today) {
        MonthRow row = new MonthRow();
        row.rowKey = 'UNPLANNED-' + String.valueOf(month);
        row.monthStart = month;
        row.isExtension = false;
        row.isUnplanned = true;
        row.rowType = UNPLANNED;
        row.actualsSource = SOURCE_ORDERS;
        row.siteName = UNPLANNED;
        row.originalPlan = 0;
        row.currentForecast = 0;
        row.orderActuals = actual == null ? 0 : actual;
        row.varianceToPlan = row.orderActuals;
        row.monthState = ForecastMetrics_CC.monthState(month, today);
        row.lastReason = 'Orders with no plan for this month';
        return row;
    }

    /** Original term, extension, unplanned and combined; the top-level measures are the combined period. */
    @TestVisible
    private static Totals totals(List<Agreement_Month_Plan_CC__c> plans, Map<Date, Decimal> actualsByMonth,
            Set<Date> unplannedMonths, Date today) {
        Map<Date, Decimal> actuals = actualsByMonth == null ? new Map<Date, Decimal>() : actualsByMonth;
        Map<Date, Decimal> planAll = new Map<Date, Decimal>();
        Map<Date, Decimal> forecastAll = new Map<Date, Decimal>();
        Map<Boolean, Map<Date, Decimal>> planByKind = new Map<Boolean, Map<Date, Decimal>>{
            false => new Map<Date, Decimal>(), true => new Map<Date, Decimal>() };
        Map<Boolean, Map<Date, Decimal>> forecastByKind = new Map<Boolean, Map<Date, Decimal>>{
            false => new Map<Date, Decimal>(), true => new Map<Date, Decimal>() };
        for (Agreement_Month_Plan_CC__c plan : plans) {
            Boolean isExtension = plan.Is_Extension_CC__c == true;
            ForecastMetrics_CC.add(planAll, plan.Month_Start_CC__c, plan.Original_Plan_Amount_CC__c);
            ForecastMetrics_CC.add(forecastAll, plan.Month_Start_CC__c, plan.Current_Forecast_Amount_CC__c);
            ForecastMetrics_CC.add(planByKind.get(isExtension), plan.Month_Start_CC__c, plan.Original_Plan_Amount_CC__c);
            ForecastMetrics_CC.add(forecastByKind.get(isExtension), plan.Month_Start_CC__c, plan.Current_Forecast_Amount_CC__c);
        }
        Map<Date, Decimal> unplannedForecast = new Map<Date, Decimal>();
        for (Date month : unplannedMonths == null ? new Set<Date>() : unplannedMonths) {
            unplannedForecast.put(month, 0);
            ForecastMetrics_CC.add(forecastAll, month, 0);
        }
        Totals t = new Totals();
        t.originalTerm = ForecastMetrics_CC.termSplit(ORIGINAL_TERM, planByKind.get(false), forecastByKind.get(false), actuals, today);
        t.extension = ForecastMetrics_CC.termSplit(EXTENSION, planByKind.get(true), forecastByKind.get(true), actuals, today);
        t.unplanned = ForecastMetrics_CC.termSplit(UNPLANNED, new Map<Date, Decimal>(), unplannedForecast, actuals, today);
        t.combined = ForecastMetrics_CC.termSplit('Combined', planAll, forecastAll, actuals, today);
        ForecastMetrics_CC.PeriodTotals period = ForecastMetrics_CC.periodTotals(planAll, forecastAll, actuals, today);
        t.originalPlan = t.combined.originalPlan;
        t.currentForecast = t.combined.currentForecast;
        t.completedPlan = t.combined.completedPlan;
        t.completedActuals = t.combined.completedActuals;
        t.completedVariance = t.combined.completedVariance;
        t.completedAttainmentPercent = t.combined.completedAttainmentPercent;
        t.expectedOutcome = t.combined.expectedOutcome;
        t.gapToOriginalPlan = t.originalPlan - t.expectedOutcome;
        t.periodLabel = period.label;
        return t;
    }

    // ------------------------------------------------------------------ revise

    @AuraEnabled
    public static Integer reviseForecast(Id agreementId, List<MonthChange> changes, String reason) {
        if (!FeatureManagement.checkPermission('Carlton_Revise_Agreement')) {
            throw new AuraHandledException('Agreement revisions require the Carlton agreement revision permission. Edit forecast facts from the Account forecast instead.');
        }
        SalesAgreementPlanService_CC.requirePilot();
        SalesAgreementPlanService_CC.requireEditAccess(agreementId);
        if (String.isBlank(reason)) {
            throw SalesAgreementPlanService_CC.error('Give a reason for the forecast change.');
        }
        if (changes == null || changes.isEmpty()) {
            throw SalesAgreementPlanService_CC.error('Change at least one month.');
        }
        SalesAgreement agreement = [SELECT Id, CurrencyIsoCode FROM SalesAgreement WHERE Id = :agreementId WITH USER_MODE];
        Integer decimals = SalesAgreementPlanService_CC.currencyDecimals(agreement.CurrencyIsoCode);
        Map<Id, Decimal> newById = new Map<Id, Decimal>();
        for (MonthChange change : changes) {
            if (change.monthPlanId == null || change.newForecast == null || change.newForecast < 0) {
                throw SalesAgreementPlanService_CC.error('Each changed month needs an amount of zero or more.');
            }
            newById.put(change.monthPlanId, change.newForecast.setScale(decimals, System.RoundingMode.HALF_UP));
        }
        Map<Id, Agreement_Month_Plan_CC__c> plans = new Map<Id, Agreement_Month_Plan_CC__c>([
            SELECT Id, Month_Start_CC__c, Current_Forecast_Amount_CC__c, Sales_Agreement_CC__c
            FROM Agreement_Month_Plan_CC__c WHERE Id IN :newById.keySet() WITH USER_MODE FOR UPDATE
        ]);
        String groupId = String.valueOf(Crypto.getRandomLong()).left(40);
        List<Agreement_Month_Plan_CC__c> planUpdates = new List<Agreement_Month_Plan_CC__c>();
        List<Agreement_Forecast_Revision_CC__c> revisions = new List<Agreement_Forecast_Revision_CC__c>();
        Map<Date, Decimal> deltaByMonth = new Map<Date, Decimal>();
        for (Id planId : newById.keySet()) {
            Agreement_Month_Plan_CC__c plan = plans.get(planId);
            if (plan == null || plan.Sales_Agreement_CC__c != agreementId) {
                throw SalesAgreementPlanService_CC.error('A changed month does not belong to this agreement.');
            }
            Decimal newValue = newById.get(planId);
            if (newValue == plan.Current_Forecast_Amount_CC__c) {
                continue;
            }
            revisions.add(new Agreement_Forecast_Revision_CC__c(Month_Plan_CC__c = plan.Id,
                Previous_Forecast_CC__c = plan.Current_Forecast_Amount_CC__c, New_Forecast_CC__c = newValue,
                Reason_CC__c = reason.left(255), Revision_Group_CC__c = groupId, CurrencyIsoCode = agreement.CurrencyIsoCode));
            planUpdates.add(new Agreement_Month_Plan_CC__c(Id = plan.Id, Current_Forecast_Amount_CC__c = newValue,
                Last_Revision_Reason_CC__c = reason.left(255)));
            ForecastMetrics_CC.add(deltaByMonth, plan.Month_Start_CC__c, newValue - plan.Current_Forecast_Amount_CC__c);
        }
        if (planUpdates.isEmpty()) {
            return 0;
        }
        // System mode by design: plans and revisions are read-only to users so every change carries a reason.
        Database.update(planUpdates, AccessLevel.SYSTEM_MODE);
        Database.insert(revisions, AccessLevel.SYSTEM_MODE);
        syncNativeForecast(agreementId, decimals);
        return planUpdates.size();
    }

    /** Sets each native schedule's ForecastedAmount to its share of the month's current forecast. */
    private static void syncNativeForecast(Id agreementId, Integer decimals) {
        Map<Date, Decimal> forecastByMonth = new Map<Date, Decimal>();
        for (Agreement_Month_Plan_CC__c plan : monthPlans(agreementId)) {
            ForecastMetrics_CC.add(forecastByMonth, plan.Month_Start_CC__c, plan.Current_Forecast_Amount_CC__c);
        }
        Map<Date, List<SalesAgreementProductSchedule>> schedulesByMonth = new Map<Date, List<SalesAgreementProductSchedule>>();
        for (SalesAgreementProductSchedule schedule : [
                SELECT Id, StartDate, PlannedAmount, ForecastedAmount FROM SalesAgreementProductSchedule
                WHERE SalesAgreementProduct.SalesAgreementId = :agreementId WITH USER_MODE ORDER BY StartDate, Id]) {
            if (!schedulesByMonth.containsKey(schedule.StartDate)) {
                schedulesByMonth.put(schedule.StartDate, new List<SalesAgreementProductSchedule>());
            }
            schedulesByMonth.get(schedule.StartDate).add(schedule);
        }
        List<SalesAgreementProductSchedule> updates = new List<SalesAgreementProductSchedule>();
        for (Date month : schedulesByMonth.keySet()) {
            List<SalesAgreementProductSchedule> schedules = schedulesByMonth.get(month);
            Decimal target = forecastByMonth.containsKey(month) ? forecastByMonth.get(month) : 0;
            Decimal plannedTotal = 0;
            for (SalesAgreementProductSchedule schedule : schedules) {
                plannedTotal += schedule.PlannedAmount == null ? 0 : schedule.PlannedAmount;
            }
            Decimal allocated = 0;
            for (Integer i = 0; i < schedules.size(); i++) {
                SalesAgreementProductSchedule schedule = schedules[i];
                Decimal part;
                if (i == schedules.size() - 1) {
                    part = target - allocated;
                } else if (plannedTotal == 0) {
                    part = (target / schedules.size()).setScale(decimals, System.RoundingMode.HALF_UP);
                } else {
                    part = (target * (schedule.PlannedAmount == null ? 0 : schedule.PlannedAmount) / plannedTotal)
                        .setScale(decimals, System.RoundingMode.HALF_UP);
                }
                allocated += part;
                if (schedule.ForecastedAmount != part) {
                    updates.add(new SalesAgreementProductSchedule(Id = schedule.Id, ForecastedAmount = part));
                }
            }
        }
        if (!updates.isEmpty()) {
            Database.update(updates, AccessLevel.USER_MODE);
        }
    }

    // ------------------------------------------------------------------ extend term

    /**
     * Adds months after the last planned month, one amount each (zero allowed). Repeatable (12 -> 18 -> 24) with no
     * cap. Each month gets Original Plan 0, Current Forecast = the amount and a revision carrying the reason. The native
     * ScheduleCount and EndDate are not touched (the platform refuses both once Activated).
     */
    @AuraEnabled
    public static String extendTerm(Id agreementId, List<Decimal> monthlyAmounts, String reason) {
        if (!FeatureManagement.checkPermission('Carlton_Revise_Agreement')) {
            throw new AuraHandledException('Agreement term changes require the Carlton agreement revision permission.');
        }
        SalesAgreementPlanService_CC.requirePilot();
        SalesAgreementPlanService_CC.requireEditAccess(agreementId);
        if (String.isBlank(reason)) {
            throw SalesAgreementPlanService_CC.error('Give a reason for the extension.');
        }
        if (monthlyAmounts == null || monthlyAmounts.isEmpty()) {
            throw SalesAgreementPlanService_CC.error('Enter an amount for each extension month (zero is allowed).');
        }
        SalesAgreement agreement = loadForPlan(agreementId);
        if (agreement.Status == 'Cancelled') {
            throw SalesAgreementPlanService_CC.error('A cancelled agreement cannot be extended.');
        }
        Integer decimals = SalesAgreementPlanService_CC.currencyDecimals(agreement.CurrencyIsoCode);
        List<Decimal> amounts = new List<Decimal>();
        for (Decimal amount : monthlyAmounts) {
            Decimal value = amount == null ? 0 : amount;
            if (value < 0) {
                throw SalesAgreementPlanService_CC.error('Extension amounts cannot be negative.');
            }
            if (value.scale() > decimals && value.setScale(decimals) != value) {
                throw SalesAgreementPlanService_CC.error(agreement.CurrencyIsoCode + ' amounts allow ' + decimals + ' decimal places.');
            }
            amounts.add(value.setScale(decimals));
        }
        Date lastPlanned = lastPlannedMonth(agreementId);
        if (lastPlanned == null) {
            throw SalesAgreementPlanService_CC.error('This agreement has no monthly plan to extend.');
        }
        List<Date> months = new List<Date>();
        for (Integer i = 1; i <= amounts.size(); i++) {
            months.add(lastPlanned.addMonths(i));
        }
        Savepoint sp = Database.setSavepoint();
        try {
            addPlanMonths(agreement, months, amounts, reason.trim().left(255));
        } catch (DmlException ex) {
            Database.rollback(sp);
            if (ex.getDmlType(0) == StatusCode.DUPLICATE_VALUE) {
                throw SalesAgreementPlanService_CC.error('Another change extended this agreement at the same time; nothing was saved. Reload and try again.');
            }
            throw SalesAgreementPlanService_CC.error('Nothing was saved. ' + ex.getDmlMessage(0));
        }
        return 'Extended by ' + months.size() + ' month(s): ' + ForecastMetrics_CC.label(months[0]) + ' to '
            + ForecastMetrics_CC.label(months[months.size() - 1]) + '. Original plan for these months is 0; the native term is unchanged.';
    }

    /**
     * Inserts extension months (Original Plan 0, Is_Extension_CC__c) with one revision each and moves
     * Extended_Through_CC__c. Callers check the pilot permission and edit access first. System mode by design: month
     * plans and revisions are read-only to users so every change carries a reason. A month that already exists fails
     * on the unique Plan Key (DUPLICATE_VALUE).
     */
    public static List<Agreement_Month_Plan_CC__c> addPlanMonths(SalesAgreement agreement, List<Date> months,
            List<Decimal> forecasts, String reason) {
        Id siteId = extensionSite(agreement.Id);
        List<Agreement_Month_Plan_CC__c> rows = new List<Agreement_Month_Plan_CC__c>();
        Date last;
        for (Integer i = 0; i < months.size(); i++) {
            Date month = months[i];
            last = last == null || month > last ? month : last;
            rows.add(new Agreement_Month_Plan_CC__c(
                Sales_Agreement_CC__c = agreement.Id,
                Account_CC__c = agreement.AccountId,
                Site_CC__c = siteId,
                Month_Start_CC__c = month,
                Original_Plan_Amount_CC__c = 0,
                Current_Forecast_Amount_CC__c = forecasts[i],
                Is_Extension_CC__c = true,
                Last_Revision_Reason_CC__c = reason,
                CurrencyIsoCode = agreement.CurrencyIsoCode,
                Plan_Key_CC__c = SalesAgreementPlanService_CC.planKey(agreement.Id, month, siteId)
            ));
        }
        Database.insert(rows, AccessLevel.SYSTEM_MODE);
        String groupId = String.valueOf(Crypto.getRandomLong()).left(40);
        List<Agreement_Forecast_Revision_CC__c> revisions = new List<Agreement_Forecast_Revision_CC__c>();
        for (Agreement_Month_Plan_CC__c row : rows) {
            revisions.add(new Agreement_Forecast_Revision_CC__c(Month_Plan_CC__c = row.Id, Previous_Forecast_CC__c = 0,
                New_Forecast_CC__c = row.Current_Forecast_Amount_CC__c, Reason_CC__c = reason, Revision_Group_CC__c = groupId,
                CurrencyIsoCode = agreement.CurrencyIsoCode));
        }
        Database.insert(revisions, AccessLevel.SYSTEM_MODE);
        Date through = last.addMonths(1).addDays(-1);
        SalesAgreement current = [SELECT Extended_Through_CC__c FROM SalesAgreement WHERE Id = :agreement.Id WITH SYSTEM_MODE];
        if ((agreement.EndDate == null || through > agreement.EndDate)
                && (current.Extended_Through_CC__c == null || through > current.Extended_Through_CC__c)) {
            // A custom field: the platform still accepts it on an Activated agreement (probed 10 Nov 2026).
            Database.update(new SalesAgreement(Id = agreement.Id, Extended_Through_CC__c = through), AccessLevel.SYSTEM_MODE);
        }
        return rows;
    }

    /** Extension months follow the Site split of the last planned month when it has a single row; else unallocated. */
    private static Id extensionSite(Id agreementId) {
        Date lastPlanned = lastPlannedMonth(agreementId);
        Set<Id> sites = new Set<Id>();
        for (Agreement_Month_Plan_CC__c plan : [SELECT Site_CC__c FROM Agreement_Month_Plan_CC__c
                WHERE Sales_Agreement_CC__c = :agreementId AND Month_Start_CC__c = :lastPlanned WITH SYSTEM_MODE]) {
            sites.add(plan.Site_CC__c);
        }
        return sites.size() == 1 ? new List<Id>(sites)[0] : null;
    }

    /** First day of the last planned month (original term or extension), or null when there is no plan. */
    public static Date lastPlannedMonth(Id agreementId) {
        List<Agreement_Month_Plan_CC__c> last = [SELECT Month_Start_CC__c FROM Agreement_Month_Plan_CC__c
            WHERE Sales_Agreement_CC__c = :agreementId WITH SYSTEM_MODE ORDER BY Month_Start_CC__c DESC LIMIT 1];
        return last.isEmpty() ? null : last[0].Month_Start_CC__c;
    }

    public static Boolean hasPlanMonth(Id agreementId, Date month) {
        return [SELECT COUNT() FROM Agreement_Month_Plan_CC__c WHERE Sales_Agreement_CC__c = :agreementId
                AND Month_Start_CC__c = :month WITH SYSTEM_MODE] > 0;
    }

    public static SalesAgreement loadForPlan(Id agreementId) {
        return [SELECT Id, Name, AccountId, PricebookId, CurrencyIsoCode, Status, StartDate, EndDate, Commercial_Scope_CC__c,
                       Extended_Through_CC__c
                FROM SalesAgreement WHERE Id = :agreementId WITH USER_MODE];
    }

    /** True when the date falls inside the agreement's native StartDate-EndDate (native schedules count its Orders). */
    public static Boolean isNativeDate(SalesAgreement agreement, Date d) {
        return agreement.StartDate != null && agreement.EndDate != null && d >= agreement.StartDate && d <= agreement.EndDate;
    }

    public static Boolean isNativeMonth(SalesAgreement agreement, Date month) {
        return agreement.StartDate != null && agreement.EndDate != null
            && month >= ForecastMetrics_CC.firstOfMonth(agreement.StartDate) && month <= agreement.EndDate;
    }

    // ------------------------------------------------------------------ recalculate

    @AuraEnabled
    public static String recalculateActuals(Id agreementId) {
        SalesAgreementPlanService_CC.requirePilot();
        SalesAgreementPlanService_CC.requireEditAccess(agreementId);
        // The standard refreshActualsCalculation action is not callable from Apex in this org (Invocable.Action reports
        // "isn't a valid action type"); it is callable from Flow and the REST Actions API. The autolaunched flow below
        // wraps it and is started by name; a faulted action comes back in its errorMessage output.
        Flow.Interview interview;
        try {
            interview = Flow.Interview.createInterview(RECALC_FLOW,
                new Map<String, Object>{ 'salesAgreementId' => String.valueOf(agreementId) });
        } catch (Exception ex) {
            throw SalesAgreementPlanService_CC.error('Recalculation in the app is not installed yet (flow ' + RECALC_FLOW
                + '). Native actuals still recalculate on the platform schedule; check Order Actuals last calculated.');
        }
        interview.start();
        String failure = (String) interview.getVariableValue('errorMessage');
        if (String.isNotBlank(failure)) {
            throw SalesAgreementPlanService_CC.error('Recalculation failed: ' + failure);
        }
        return 'Recalculation requested. Native actuals refresh asynchronously; reload in a minute.';
    }

    public static final String RECALC_FLOW = 'Recalculate_Sales_Agreement_Actuals_CC';

    // ------------------------------------------------------------------ shared queries

    public static List<Agreement_Month_Plan_CC__c> monthPlans(Id agreementId) {
        return [SELECT Id, Month_Start_CC__c, Site_CC__c, Site_CC__r.Name, Original_Plan_Amount_CC__c,
                       Current_Forecast_Amount_CC__c, Last_Revision_Reason_CC__c, Is_Extension_CC__c
                FROM Agreement_Month_Plan_CC__c WHERE Sales_Agreement_CC__c = :agreementId
                WITH USER_MODE ORDER BY Month_Start_CC__c, Site_CC__r.Name];
    }

    /**
     * Activated Order lines of the given agreements, ignoring Order sharing (WITH SYSTEM_MODE alone still applies the
     * class's "with sharing"; inner classes do not inherit it). Callers pass only agreements the user can see.
     */
    private without sharing class AgreementOrderLines {
        List<OrderItem> activated(Set<Id> agreementIds, Date lower, Date upper) {
            return [SELECT Order.SalesAgreementId, Order.Agreement_Extension_CC__c, Order.EffectiveDate, Order.CurrencyIsoCode,
                           Product2Id, TotalPrice
                    FROM OrderItem
                    WHERE (Order.SalesAgreementId IN :agreementIds OR Order.Agreement_Extension_CC__c IN :agreementIds)
                    AND Order.StatusCode = 'Activated' AND Order.EffectiveDate >= :lower AND Order.EffectiveDate <= :upper
                    WITH SYSTEM_MODE];
        }
    }

    /** One activated Order line counted outside an agreement's native term. */
    public class OrderActual {
        public Id agreementId;
        public Date month;
        public String productName;
        public Decimal amount;
    }

    /**
     * Activated Order lines dated outside each agreement's native StartDate-EndDate, from Orders linked natively
     * (SalesAgreementId) or by Agreement_Extension_CC__c, so an Order counts however it arrived. Agreement products in
     * the agreement's currency only (the native actuals rule); summed per record in Apex because SOQL SUM() on currency
     * fields converts to the running user's currency. Agreements need StartDate, EndDate and CurrencyIsoCode.
     * The Order lines are read in system mode, like native actuals: an agreement the user can see (the caller loads it in
     * user mode) shows all its Orders' amounts, whoever owns them. Only per-month amounts leave this method.
     */
    public static List<OrderActual> orderActualsOutsideNativeTerm(Map<Id, SalesAgreement> agreements, Date fromDate, Date toDate) {
        List<OrderActual> result = new List<OrderActual>();
        if (agreements == null || agreements.isEmpty()) {
            return result;
        }
        Set<Id> ids = agreements.keySet();
        Date lower = fromDate == null ? Date.newInstance(1900, 1, 1) : fromDate;
        Date upper = toDate == null ? Date.newInstance(4000, 12, 31) : toDate;
        Map<String, String> productNames = new Map<String, String>();
        for (SalesAgreementProduct product : [SELECT SalesAgreementId, Name, PricebookEntry.Product2Id FROM SalesAgreementProduct
                                              WHERE SalesAgreementId IN :ids WITH USER_MODE]) {
            productNames.put(product.SalesAgreementId + '|' + product.PricebookEntry.Product2Id, product.Name);
        }
        for (OrderItem item : new AgreementOrderLines().activated(ids, lower, upper)) {
            Id agreementId = item.Order.SalesAgreementId != null ? item.Order.SalesAgreementId : item.Order.Agreement_Extension_CC__c;
            SalesAgreement agreement = agreements.get(agreementId);
            String productName = productNames.get(agreementId + '|' + item.Product2Id);
            if (agreement == null || productName == null || isNativeDate(agreement, item.Order.EffectiveDate)
                    || item.Order.CurrencyIsoCode != agreement.CurrencyIsoCode) {
                continue;
            }
            OrderActual line = new OrderActual();
            line.agreementId = agreementId;
            line.month = ForecastMetrics_CC.firstOfMonth(item.Order.EffectiveDate);
            line.productName = productName;
            line.amount = item.TotalPrice == null ? 0 : item.TotalPrice;
            result.add(line);
        }
        return result;
    }

    /**
     * Native Order Actuals (schedule ActualAmount) per agreement and calendar month, in the agreement's currency.
     * Summed in Apex: SOQL SUM() on currency fields converts to the running user's currency in a multi-currency org.
     */
    public static Map<Id, Map<Date, Decimal>> nativeActualsByMonth(Set<Id> agreementIds) {
        Map<Id, Map<Date, Decimal>> result = new Map<Id, Map<Date, Decimal>>();
        for (SalesAgreementProductSchedule schedule : [
                SELECT SalesAgreementProduct.SalesAgreementId, StartDate, ActualAmount FROM SalesAgreementProductSchedule
                WHERE SalesAgreementProduct.SalesAgreementId IN :agreementIds WITH USER_MODE]) {
            Id agreementId = schedule.SalesAgreementProduct.SalesAgreementId;
            if (!result.containsKey(agreementId)) {
                result.put(agreementId, new Map<Date, Decimal>());
            }
            ForecastMetrics_CC.add(result.get(agreementId), schedule.StartDate, schedule.ActualAmount);
        }
        return result;
    }
}