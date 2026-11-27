/**
 * Forecast measures and revisions: attainment, shortfall, completed vs incomplete months, expected outcome, and
 * revisions that keep the original plan and won amount while recording the reason.
 */
@isTest
private class SalesAgreementForecastService_CC_Test {

    private static final Decimal MILLION = 1000000;

    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.isolationAdmin();
        User pilot = OpportunityUi2TestData_CC.pilotUser();
        System.runAs(admin) {
            Account entity = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            OpportunityUi2TestData_CC.standardEntry('ZZUI2 Wrap', 1000, 'GBP');
            OpportunityUi2TestData_CC.newBusiness(entity.Id, pilot.Id, 12 * MILLION, 'GBP');
        }
    }

    private static User pilot() {
        return [SELECT Id FROM User WHERE Alias = 'ui2pilot' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
    }

    // ------------------------------------------------------------------ pure measures

    @isTest
    static void completedMonthAt500kAgainst1m_Is50PercentWith500kShortfall() {
        Date today = Date.newInstance(2026, 10, 29);
        Assert.areEqual(50.0, ForecastMetrics_CC.attainment(500000, MILLION));
        Assert.isNull(ForecastMetrics_CC.attainment(500000, 0), 'Zero plan: attainment N/A');
        Assert.areEqual(ForecastMetrics_CC.COMPLETED, ForecastMetrics_CC.monthState(Date.newInstance(2026, 9, 1), today));
        Assert.areEqual(ForecastMetrics_CC.CURRENT, ForecastMetrics_CC.monthState(Date.newInstance(2026, 10, 1), today),
            'The current month is labelled incomplete');
        Assert.areEqual(ForecastMetrics_CC.FUTURE, ForecastMetrics_CC.monthState(Date.newInstance(2026, 11, 1), today));
    }

    @isTest
    static void sixMonths6mPlanAgainst4mActuals_Gives2mGap_AndCurrentMonthUsesForecastOnly() {
        Date today = Date.newInstance(2026, 7, 15);
        Map<Date, Decimal> plan = new Map<Date, Decimal>();
        Map<Date, Decimal> forecast = new Map<Date, Decimal>();
        Map<Date, Decimal> actuals = new Map<Date, Decimal>();
        for (Integer m = 1; m <= 12; m++) {
            plan.put(Date.newInstance(2026, m, 1), MILLION);
            forecast.put(Date.newInstance(2026, m, 1), MILLION);
        }
        List<Decimal> firstSix = new List<Decimal>{ MILLION, 500000, 700000, 600000, 600000, 600000 };
        for (Integer m = 1; m <= 6; m++) {
            actuals.put(Date.newInstance(2026, m, 1), firstSix[m - 1]);
        }
        actuals.put(Date.newInstance(2026, 7, 1), 900000); // current-month actuals must not be added on top of its forecast
        ForecastMetrics_CC.PeriodTotals t = ForecastMetrics_CC.periodTotals(plan, forecast, actuals, today);
        Assert.areEqual(6 * MILLION, t.completedPlan);
        Assert.areEqual(4 * MILLION, t.completedActuals);
        Assert.areEqual(2 * MILLION, t.completedPlan - t.completedActuals, '6m plan vs 4m actuals: 2m gap');
        Assert.areEqual(4 * MILLION + 6 * MILLION, t.expectedOutcome, 'Completed actuals + forecast for Jul-Dec');
        Assert.areEqual(12 * MILLION - t.expectedOutcome, 2 * MILLION, 'Gap to the original 12m plan');
    }

    // ------------------------------------------------------------------ revisions

    @isTest
    static void reviseRemainingMonthsDown_KeepsOriginalPlanAndWonAmount_RecordsReasonAndSyncsNativeForecast() {
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Wrap%' LIMIT 1];
        SalesAgreementActivationJob_CC.chainNextStep = false;
        Date start = OpportunityUi2TestData_CC.firstOfMonth(Date.today());
        SalesAgreementPlanService_CC.PlanResult result;
        Integer changed;
        System.runAs(pilot()) {
            result = SalesAgreementPlanService_CC.winAndPlan(
                OpportunityUi2TestData_CC.request(o.Id, start, OpportunityUi2TestData_CC.repeat(MILLION, 12), entry.Id));
            List<SalesAgreementForecastService_CC.MonthChange> changes = new List<SalesAgreementForecastService_CC.MonthChange>();
            for (Agreement_Month_Plan_CC__c plan : [SELECT Id FROM Agreement_Month_Plan_CC__c
                    WHERE Sales_Agreement_CC__c = :result.salesAgreementId AND Month_Start_CC__c >= :start.addMonths(6) WITH SYSTEM_MODE]) {
                SalesAgreementForecastService_CC.MonthChange change = new SalesAgreementForecastService_CC.MonthChange();
                change.monthPlanId = plan.Id;
                change.newForecast = 500000;
                changes.add(change);
            }
            changed = SalesAgreementForecastService_CC.reviseForecast(result.salesAgreementId, changes, 'Customer reduced H2 volumes');
        }
        Assert.areEqual(6, changed);
        Decimal original = 0;
        Decimal current = 0;
        // Summed in record currency (SOQL SUM() converts to the test user's currency).
        for (Agreement_Month_Plan_CC__c plan : [SELECT Original_Plan_Amount_CC__c, Current_Forecast_Amount_CC__c FROM Agreement_Month_Plan_CC__c
                                                WHERE Sales_Agreement_CC__c = :result.salesAgreementId WITH SYSTEM_MODE]) {
            original += plan.Original_Plan_Amount_CC__c;
            current += plan.Current_Forecast_Amount_CC__c;
        }
        Assert.areEqual(12 * MILLION, original, 'Original plan unchanged');
        Assert.areEqual(9 * MILLION, current, 'Forecast may now total less than the win');
        Assert.areEqual(12 * MILLION, [SELECT Amount FROM Opportunity WHERE Id = :o.Id].Amount, 'Won amount unchanged');
        List<Agreement_Forecast_Revision_CC__c> revisions = [SELECT Previous_Forecast_CC__c, New_Forecast_CC__c, Reason_CC__c
            FROM Agreement_Forecast_Revision_CC__c WITH SYSTEM_MODE];
        Assert.areEqual(6, revisions.size(), 'One revision per changed month');
        Assert.areEqual(MILLION, revisions[0].Previous_Forecast_CC__c);
        Assert.areEqual('Customer reduced H2 volumes', revisions[0].Reason_CC__c);
        Decimal nativeForecast = 0;
        for (SalesAgreementProductSchedule schedule : [SELECT ForecastedAmount FROM SalesAgreementProductSchedule
                WHERE SalesAgreementProduct.SalesAgreementId = :result.salesAgreementId WITH SYSTEM_MODE]) {
            nativeForecast += schedule.ForecastedAmount;
        }
        Assert.areEqual(9 * MILLION, nativeForecast, 'Native forecast kept in step');

        System.runAs(pilot()) {
            SalesAgreementForecastService_CC.AgreementView view = SalesAgreementForecastService_CC.getAgreementView(result.salesAgreementId);
            Assert.areEqual(12, view.months.size());
            Assert.areEqual(6, view.revisions.size(), 'History is visible on the agreement');
            Assert.areEqual(12 * MILLION, view.totals.originalPlan);
            Assert.areEqual(9 * MILLION, view.totals.currentForecast);
        }
    }

    // ------------------------------------------------------------------ term extension

    private static Id win12Months() {
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Wrap%' LIMIT 1];
        SalesAgreementActivationJob_CC.chainNextStep = false;
        return SalesAgreementPlanService_CC.winAndPlan(OpportunityUi2TestData_CC.request(o.Id,
            OpportunityUi2TestData_CC.firstOfMonth(Date.today()), OpportunityUi2TestData_CC.repeat(MILLION, 12), entry.Id)).salesAgreementId;
    }

    @isTest
    static void extendTerm_12To18To24AndPast36_AddsZeroPlanMonthsWithRevisions_NativeTermUnchanged() {
        Date start = OpportunityUi2TestData_CC.firstOfMonth(Date.today());
        Id agreementId;
        String lastMessage;
        SalesAgreementForecastService_CC.AgreementView view;
        System.runAs(pilot()) {
            agreementId = win12Months();
            SalesAgreementForecastService_CC.extendTerm(agreementId, OpportunityUi2TestData_CC.repeat(500000, 6), 'Customer extended to 18 months');
            SalesAgreementForecastService_CC.extendTerm(agreementId, OpportunityUi2TestData_CC.repeat(250000, 6), 'Extended again to 24 months');
            lastMessage = SalesAgreementForecastService_CC.extendTerm(agreementId, OpportunityUi2TestData_CC.repeat(100000, 13), 'Renewal past 36 months');
            view = SalesAgreementForecastService_CC.getAgreementView(agreementId);
        }
        Assert.isTrue(lastMessage.contains('13 month'), lastMessage);
        List<Agreement_Month_Plan_CC__c> plans = [SELECT Month_Start_CC__c, Original_Plan_Amount_CC__c, Current_Forecast_Amount_CC__c,
                                                         Is_Extension_CC__c, Last_Revision_Reason_CC__c
                                                  FROM Agreement_Month_Plan_CC__c WHERE Sales_Agreement_CC__c = :agreementId
                                                  WITH SYSTEM_MODE ORDER BY Month_Start_CC__c];
        Assert.areEqual(37, plans.size(), '12 + 6 + 6 + 13 months: no 36-month cap');
        for (Integer i = 0; i < plans.size(); i++) {
            Assert.areEqual(start.addMonths(i), plans[i].Month_Start_CC__c, 'Consecutive months, no gap or duplicate');
            Assert.areEqual(i >= 12, plans[i].Is_Extension_CC__c);
            Assert.areEqual(i >= 12 ? 0 : MILLION, plans[i].Original_Plan_Amount_CC__c, 'Extension months have original plan 0');
        }
        Assert.areEqual(500000, plans[12].Current_Forecast_Amount_CC__c);
        Assert.areEqual(250000, plans[18].Current_Forecast_Amount_CC__c);
        Assert.areEqual(100000, plans[36].Current_Forecast_Amount_CC__c);
        Assert.areEqual('Renewal past 36 months', plans[36].Last_Revision_Reason_CC__c);
        List<Agreement_Forecast_Revision_CC__c> revisions = [SELECT Previous_Forecast_CC__c, New_Forecast_CC__c, Reason_CC__c
            FROM Agreement_Forecast_Revision_CC__c WHERE Month_Plan_CC__r.Sales_Agreement_CC__c = :agreementId WITH SYSTEM_MODE];
        Assert.areEqual(25, revisions.size(), 'One revision per extension month');
        for (Agreement_Forecast_Revision_CC__c revision : revisions) {
            Assert.areEqual(0, revision.Previous_Forecast_CC__c);
            Assert.isNotNull(revision.Reason_CC__c);
        }
        SalesAgreement sa = [SELECT ScheduleCount, EndDate, Extended_Through_CC__c FROM SalesAgreement WHERE Id = :agreementId WITH SYSTEM_MODE];
        Assert.areEqual(12, sa.ScheduleCount, 'Native term unchanged');
        Assert.areEqual(start.addMonths(12).addDays(-1), sa.EndDate, 'Native end unchanged');
        Assert.areEqual(start.addMonths(37).addDays(-1), sa.Extended_Through_CC__c, 'Extended through the last added month');
        Assert.areEqual(12, [SELECT COUNT() FROM SalesAgreementProductSchedule WHERE SalesAgreementProduct.SalesAgreementId = :agreementId WITH SYSTEM_MODE],
            'No native schedules are added');

        Assert.areEqual(37, view.months.size());
        Assert.areEqual(25, view.extensionMonths);
        Assert.areEqual(start.addMonths(37), view.nextExtensionMonth, 'The next extension starts after the last planned month');
        Assert.areEqual(SalesAgreementForecastService_CC.EXTENSION, view.months[12].rowType);
        Assert.areEqual(SalesAgreementForecastService_CC.SOURCE_ORDERS, view.months[12].actualsSource, 'After the native term, actuals come from Orders');
        Assert.areEqual(SalesAgreementForecastService_CC.SOURCE_NATIVE, view.months[0].actualsSource);
        Assert.areEqual(12, view.totals.originalTerm.months);
        Assert.areEqual(12 * MILLION, view.totals.originalTerm.originalPlan);
        Assert.areEqual(25, view.totals.extension.months);
        Assert.areEqual(0, view.totals.extension.originalPlan);
        Assert.areEqual(5800000, view.totals.extension.currentForecast, '3m + 1.5m + 1.3m');
        Assert.areEqual(17800000, view.totals.combined.currentForecast);
        Assert.areEqual(12 * MILLION, view.totals.originalPlan, 'The original plan total is unchanged by extensions');
    }

    @isTest
    static void extendTerm_RequiresReasonAndValidAmounts_AndSavesNothingOnError() {
        Id agreementId;
        Integer refused = 0;
        System.runAs(pilot()) {
            agreementId = win12Months();
            List<List<Decimal>> invalid = new List<List<Decimal>>{ null, new List<Decimal>(), new List<Decimal>{ 100, -1 }, new List<Decimal>{ 100.001 } };
            for (List<Decimal> amounts : invalid) {
                try { SalesAgreementForecastService_CC.extendTerm(agreementId, amounts, 'Valid reason'); } catch (AuraHandledException ex) { refused++; }
            }
            try { SalesAgreementForecastService_CC.extendTerm(agreementId, new List<Decimal>{ 100 }, '  '); } catch (AuraHandledException ex) { refused++; }
        }
        Assert.areEqual(5, refused, 'Missing amounts, negative amounts, extra decimals and a blank reason are refused');
        Assert.areEqual(12, [SELECT COUNT() FROM Agreement_Month_Plan_CC__c WHERE Sales_Agreement_CC__c = :agreementId WITH SYSTEM_MODE]);
        Assert.isNull([SELECT Extended_Through_CC__c FROM SalesAgreement WHERE Id = :agreementId WITH SYSTEM_MODE].Extended_Through_CC__c);
    }

    @isTest
    static void totals_SplitOriginalTermExtensionUnplannedAndCombined() {
        Date today = Date.newInstance(2027, 3, 15);
        List<Agreement_Month_Plan_CC__c> plans = new List<Agreement_Month_Plan_CC__c>();
        Map<Date, Decimal> actuals = new Map<Date, Decimal>();
        for (Integer m = 1; m <= 12; m++) {
            plans.add(new Agreement_Month_Plan_CC__c(Month_Start_CC__c = Date.newInstance(2026, m, 1), Original_Plan_Amount_CC__c = 100,
                Current_Forecast_Amount_CC__c = 100, Is_Extension_CC__c = false));
            actuals.put(Date.newInstance(2026, m, 1), 80);
        }
        for (Integer m = 1; m <= 3; m++) {
            plans.add(new Agreement_Month_Plan_CC__c(Month_Start_CC__c = Date.newInstance(2027, m, 1), Original_Plan_Amount_CC__c = 0,
                Current_Forecast_Amount_CC__c = 50, Is_Extension_CC__c = true));
        }
        actuals.put(Date.newInstance(2027, 1, 1), 70);
        actuals.put(Date.newInstance(2027, 2, 1), 30);
        actuals.put(Date.newInstance(2025, 12, 1), 20); // Order before the start, no plan
        actuals.put(Date.newInstance(2027, 5, 1), 40);  // future Order after the plan, no plan
        Set<Date> unplanned = new Set<Date>{ Date.newInstance(2025, 12, 1), Date.newInstance(2027, 5, 1) };

        SalesAgreementForecastService_CC.Totals t = SalesAgreementForecastService_CC.totals(plans, actuals, unplanned, today);
        Assert.areEqual(1200, t.originalTerm.originalPlan);
        Assert.areEqual(960, t.originalTerm.completedActuals);
        Assert.areEqual(80.0, t.originalTerm.completedAttainmentPercent);
        Assert.areEqual(0, t.extension.originalPlan);
        Assert.areEqual(150, t.extension.currentForecast);
        Assert.areEqual(100, t.extension.actualsToDate);
        Assert.isNull(t.extension.completedAttainmentPercent, 'No original plan in the extension: attainment N/A');
        Assert.areEqual(150, t.extension.expectedOutcome, 'Jan-Feb actuals 100 + March (current) forecast 50');
        Assert.areEqual(2, t.unplanned.months);
        Assert.areEqual(60, t.unplanned.actualsToDate);
        Assert.areEqual(20, t.unplanned.completedActuals);
        Assert.areEqual(1350, t.combined.currentForecast);
        Assert.areEqual(1080, t.combined.completedActuals, '960 + 100 + 20');
        Assert.areEqual(1130, t.expectedOutcome, 'Combined: completed actuals + March forecast; future unplanned month forecast 0');
        Assert.areEqual(70, t.gapToOriginalPlan);
    }

    @isTest
    static void originalPlan_CannotBeEdited_AndReasonIsRequired() {
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Wrap%' LIMIT 1];
        SalesAgreementActivationJob_CC.chainNextStep = false;
        SalesAgreementPlanService_CC.PlanResult result;
        String message;
        System.runAs(pilot()) {
            result = SalesAgreementPlanService_CC.winAndPlan(OpportunityUi2TestData_CC.request(o.Id,
                OpportunityUi2TestData_CC.firstOfMonth(Date.today()), OpportunityUi2TestData_CC.repeat(MILLION, 12), entry.Id));
            try {
                SalesAgreementForecastService_CC.reviseForecast(result.salesAgreementId,
                    new List<SalesAgreementForecastService_CC.MonthChange>{ new SalesAgreementForecastService_CC.MonthChange() }, ' ');
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
            Agreement_Month_Plan_CC__c plan = [SELECT Id FROM Agreement_Month_Plan_CC__c WITH SYSTEM_MODE LIMIT 1];
            // A direct save by the pilot user in user mode, as the UI would do it (test code runs in system mode by default).
            Database.SaveResult direct = Database.update(new Agreement_Month_Plan_CC__c(Id = plan.Id, Current_Forecast_Amount_CC__c = 1),
                false, AccessLevel.USER_MODE);
            Assert.isFalse(direct.isSuccess(), 'Pilot users cannot edit plans directly (read-only), so every change has a reason');
        }
        Assert.isTrue(message.contains('reason'), message);
        Agreement_Month_Plan_CC__c plan = [SELECT Id FROM Agreement_Month_Plan_CC__c WITH SYSTEM_MODE LIMIT 1];
        Database.SaveResult adminEdit = Database.update(new Agreement_Month_Plan_CC__c(Id = plan.Id, Original_Plan_Amount_CC__c = 1), false);
        Assert.isFalse(adminEdit.isSuccess(), 'The original plan is immutable even for administrators');
    }
}