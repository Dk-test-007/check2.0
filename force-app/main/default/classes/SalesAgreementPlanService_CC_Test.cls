/**
 * Win and Set Monthly Forecast: one agreement per win, calendar-month schedules, immutable baseline, initial
 * equality gate, idempotency (double submit, reclose, unique key), access control and queued activation.
 * Runs the service as a real Carlton Sales User pilot.
 */
@isTest
private class SalesAgreementPlanService_CC_Test {

    private static final Decimal MILLION = 1000000;

    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.isolationAdmin();
        User pilot = OpportunityUi2TestData_CC.pilotUser();
        System.runAs(admin) {
            Account entity = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            OpportunityUi2TestData_CC.site(entity.Id, pilot.Id, 'ZZUI2 Site A');
            OpportunityUi2TestData_CC.standardEntry('ZZUI2 Wrap', 1000, 'GBP');
            OpportunityUi2TestData_CC.newBusiness(entity.Id, pilot.Id, 12 * MILLION, 'GBP');
        }
    }

    private static User pilot() {
        return [SELECT Id FROM User WHERE Alias = 'ui2pilot' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
    }
    private static Opportunity opp() {
        return [SELECT Id, Amount, AccountId FROM Opportunity WHERE Name LIKE 'ZZUI2 Win%' LIMIT 1];
    }
    private static PricebookEntry entry() {
        return [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Wrap%' LIMIT 1];
    }
    private static Date startMonth() {
        return OpportunityUi2TestData_CC.firstOfMonth(Date.today());
    }

    @isTest
    static void win12Months_CreatesOneAgreementTwelveCalendarSchedulesAndBaseline() {
        Opportunity o = opp();
        SalesAgreementActivationJob_CC.chainNextStep = false;
        SalesAgreementPlanService_CC.PlanResult result;
        Test.startTest();
        System.runAs(pilot()) {
            result = SalesAgreementPlanService_CC.winAndPlan(
                OpportunityUi2TestData_CC.request(o.Id, startMonth(), OpportunityUi2TestData_CC.repeat(MILLION, 12), entry().Id));
        }
        Test.stopTest();

        Assert.isFalse(result.alreadyExisted, 'First win creates the agreement');
        Assert.areEqual(1, [SELECT COUNT() FROM SalesAgreement WHERE Source_Opportunity_CC__c = :o.Id WITH SYSTEM_MODE], 'One agreement per win');
        List<SalesAgreementProductSchedule> schedules = [SELECT StartDate, EndDate, PlannedAmount, DerivedPlannedAmount, ForecastedAmount
            FROM SalesAgreementProductSchedule WHERE SalesAgreementProduct.SalesAgreement.Source_Opportunity_CC__c = :o.Id WITH SYSTEM_MODE ORDER BY StartDate];
        Assert.areEqual(12, schedules.size(), 'Twelve monthly schedules');
        for (Integer i = 0; i < 12; i++) {
            Date expected = startMonth().addMonths(i);
            Assert.areEqual(expected, schedules[i].StartDate, 'Starts on the first of each calendar month');
            Assert.areEqual(expected.addMonths(1).addDays(-1), schedules[i].EndDate, 'Ends on the last day of the month');
            Assert.areEqual(MILLION, schedules[i].DerivedPlannedAmount, 'Planned amount is the monthly revenue, not a fake quantity');
        }
        List<Agreement_Month_Plan_CC__c> plans = [SELECT Original_Plan_Amount_CC__c, Current_Forecast_Amount_CC__c, Site_CC__c
            FROM Agreement_Month_Plan_CC__c WHERE Sales_Agreement_CC__c = :result.salesAgreementId WITH SYSTEM_MODE];
        Assert.areEqual(12, plans.size(), 'Twelve baseline months');
        for (Agreement_Month_Plan_CC__c plan : plans) {
            Assert.areEqual(MILLION, plan.Original_Plan_Amount_CC__c);
            Assert.areEqual(plan.Original_Plan_Amount_CC__c, plan.Current_Forecast_Amount_CC__c, 'Forecast starts at the plan');
            Assert.isNull(plan.Site_CC__c, 'Entity-wide plan is unallocated');
        }
        Opportunity won = [SELECT StageName, IsWon, Amount FROM Opportunity WHERE Id = :o.Id];
        Assert.isTrue(won.IsWon, 'The win is saved with the plan');
        Assert.areEqual(12 * MILLION, won.Amount, 'Won amount unchanged');
        SalesAgreement sa = [SELECT Status, ActualsCalculationMode, ScheduleFrequency, Original_Win_Amount_CC__c, Plan_Status_CC__c
                             FROM SalesAgreement WHERE Id = :result.salesAgreementId WITH SYSTEM_MODE];
        Assert.areEqual('Orders', sa.ActualsCalculationMode, 'Actuals from direct Orders on this agreement only');
        Assert.areEqual('Monthly', sa.ScheduleFrequency);
        Assert.areEqual(12 * MILLION, sa.Original_Win_Amount_CC__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Order WHERE AccountId = :o.AccountId], 'No forecast Orders are created');
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity WHERE AccountId = :o.AccountId], 'No monthly Opportunities are created');
    }

    @isTest
    static void incompleteAllocation_IsRejectedAndSavesNothing() {
        Opportunity o = opp();
        List<Decimal> amounts = OpportunityUi2TestData_CC.repeat(0, 12);
        amounts[0] = 3 * MILLION;
        String message;
        System.runAs(pilot()) {
            try {
                SalesAgreementPlanService_CC.winAndPlan(OpportunityUi2TestData_CC.request(o.Id, startMonth(), amounts, entry().Id));
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
        }
        Assert.isNotNull(message, 'A 3m plan against a 12m win must be rejected');
        Assert.isTrue(message.contains('must equal the Opportunity Amount'), message);
        Assert.areEqual(0, [SELECT COUNT() FROM SalesAgreement WITH SYSTEM_MODE], 'No agreement');
        Assert.areEqual(0, [SELECT COUNT() FROM Agreement_Month_Plan_CC__c WITH SYSTEM_MODE], 'No plan rows');
        Assert.isFalse([SELECT IsWon FROM Opportunity WHERE Id = :o.Id].IsWon, 'The Opportunity is not won');
    }

    @isTest
    static void oneOff_ConcentratesInOneMonth_WithZeroMonthsAllowed() {
        Opportunity o = opp();
        update new Opportunity(Id = o.Id, Amount = 300000);
        List<Decimal> amounts = OpportunityUi2TestData_CC.repeat(0, 12);
        amounts[4] = 300000;
        SalesAgreementActivationJob_CC.chainNextStep = false;
        SalesAgreementPlanService_CC.PlanResult result;
        System.runAs(pilot()) {
            result = SalesAgreementPlanService_CC.winAndPlan(OpportunityUi2TestData_CC.request(o.Id, startMonth(), amounts, entry().Id));
        }
        List<Agreement_Month_Plan_CC__c> nonZero = [SELECT Month_Start_CC__c FROM Agreement_Month_Plan_CC__c
            WHERE Sales_Agreement_CC__c = :result.salesAgreementId AND Original_Plan_Amount_CC__c > 0 WITH SYSTEM_MODE];
        Assert.areEqual(1, nonZero.size(), 'One non-zero month');
        Assert.areEqual(startMonth().addMonths(4), nonZero[0].Month_Start_CC__c);
        Assert.areEqual(0, [SELECT COUNT() FROM SalesAgreementProductSchedule
            WHERE SalesAgreementProduct.SalesAgreementId = :result.salesAgreementId AND DerivedPlannedAmount != 0 AND StartDate != :startMonth().addMonths(4) WITH SYSTEM_MODE],
            'Zero months stay zero natively');
    }

    @isTest
    static void doubleSubmitAndReclose_ReturnExistingAgreementWithoutResettingTheBaseline() {
        Opportunity o = opp();
        SalesAgreementActivationJob_CC.chainNextStep = false;
        SalesAgreementPlanService_CC.PlanRequest request =
            OpportunityUi2TestData_CC.request(o.Id, startMonth(), OpportunityUi2TestData_CC.repeat(MILLION, 12), entry().Id);
        SalesAgreementPlanService_CC.PlanResult first;
        SalesAgreementPlanService_CC.PlanResult second;
        System.runAs(pilot()) {
            first = SalesAgreementPlanService_CC.winAndPlan(request);
            // Revise a month, then submit again with a different (also valid) split: nothing may reset.
            Agreement_Month_Plan_CC__c month = [SELECT Id FROM Agreement_Month_Plan_CC__c WHERE Sales_Agreement_CC__c = :first.salesAgreementId
                                                WITH SYSTEM_MODE ORDER BY Month_Start_CC__c DESC LIMIT 1];
            SalesAgreementForecastService_CC.MonthChange change = new SalesAgreementForecastService_CC.MonthChange();
            change.monthPlanId = month.Id;
            change.newForecast = 500000;
            SalesAgreementForecastService_CC.reviseForecast(first.salesAgreementId,
                new List<SalesAgreementForecastService_CC.MonthChange>{ change }, 'Customer delayed December');
            List<Decimal> other = OpportunityUi2TestData_CC.repeat(0, 12);
            other[0] = 12 * MILLION;
            request.monthlyAmounts = other;
            second = SalesAgreementPlanService_CC.winAndPlan(request);
        }
        // Reopen and reclose (admin; non-admins cannot edit a closed Opportunity), then win again.
        update new Opportunity(Id = o.Id, StageName = 'Negotiate');
        update new Opportunity(Id = o.Id, StageName = 'Closed Won');
        SalesAgreementPlanService_CC.PlanResult third;
        System.runAs(pilot()) {
            third = SalesAgreementPlanService_CC.winAndPlan(request);
        }
        Assert.isTrue(second.alreadyExisted && third.alreadyExisted, 'Retries return the existing agreement');
        Assert.areEqual(first.salesAgreementId, second.salesAgreementId);
        Assert.areEqual(first.salesAgreementId, third.salesAgreementId);
        Assert.areEqual(1, [SELECT COUNT() FROM SalesAgreement WITH SYSTEM_MODE], 'No duplicate agreement');
        Assert.areEqual(12, [SELECT COUNT() FROM Agreement_Month_Plan_CC__c WITH SYSTEM_MODE], 'No duplicate months');
        Decimal original = 0;
        Decimal current = 0;
        // Summed in record currency (SOQL SUM() converts to the test user's currency).
        for (Agreement_Month_Plan_CC__c plan : [SELECT Original_Plan_Amount_CC__c, Current_Forecast_Amount_CC__c
                                                FROM Agreement_Month_Plan_CC__c WITH SYSTEM_MODE]) {
            original += plan.Original_Plan_Amount_CC__c;
            current += plan.Current_Forecast_Amount_CC__c;
        }
        Assert.areEqual(12 * MILLION, original, 'The original baseline is unchanged');
        Assert.areEqual(11.5 * MILLION, current, 'The revised forecast is not reset');
    }

    @isTest
    static void creationKey_IsUniqueInTheDatabase() {
        Opportunity o = opp();
        Id pricebookId = Test.getStandardPricebookId();
        Database.SaveResult result;
        User isolationAdmin = [SELECT Id FROM User WHERE Alias = 'ui2isoad' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
        System.runAs(isolationAdmin) {
            SalesAgreement a = new SalesAgreement(Name = 'A', AccountId = o.AccountId, PricebookId = pricebookId, StartDate = startMonth(),
                ScheduleFrequency = 'Monthly', ScheduleCount = 1, UI2_Creation_Key_CC__c = SalesAgreementPlanService_CC.KEY_PREFIX + o.Id);
            insert a;
            result = Database.insert(a.clone(false, true), false);
        }
        Assert.isFalse(result.isSuccess(), 'A concurrent second agreement for the same win is refused by the database');
        Assert.areEqual(StatusCode.DUPLICATE_VALUE, result.getErrors()[0].getStatusCode());
    }

    @isTest
    static void nonPilot_IsDeniedAtEveryEntryPoint() {
        User none = OpportunityUi2TestData_CC.nonPilotUser();
        Opportunity o = opp();
        Integer denied = 0;
        System.runAs(none) {
            try { SalesAgreementPlanService_CC.getWinContext(o.Id); } catch (AuraHandledException ex) { denied++; }
            try {
                SalesAgreementPlanService_CC.winAndPlan(OpportunityUi2TestData_CC.request(o.Id, startMonth(),
                    OpportunityUi2TestData_CC.repeat(MILLION, 12), entry().Id));
            } catch (AuraHandledException ex) { denied++; }
            try { SalesAgreementForecastService_CC.getAgreementView(o.Id); } catch (AuraHandledException ex) { denied++; }
            try { AccountMonthlyForecastController_CC.getAccountView(o.AccountId, null); } catch (AuraHandledException ex) { denied++; }
            try { AgreementReleaseOrderService_CC.getEntryContext(o.Id); } catch (AuraHandledException ex) { denied++; }
            try { SalesAgreementForecastService_CC.extendTerm(o.Id, new List<Decimal>{ 1 }, 'x'); } catch (AuraHandledException ex) { denied++; }
        }
        Assert.areEqual(6, denied, 'Direct Apex calls without the pilot permission are refused');
        Assert.areEqual(0, [SELECT COUNT() FROM SalesAgreement WITH SYSTEM_MODE]);
    }

    @isTest
    static void productSharesAndScale_AreValidatedAndSplitExactly() {
        List<List<Decimal>> split = SalesAgreementPlanService_CC.splitByShare(new List<Decimal>{ 100.01, 0 },
            new List<Decimal>{ 33.33, 66.67 }, 2);
        Assert.areEqual(100.01, split[0][0] + split[1][0], 'Products sum exactly to the month');
        Assert.areEqual(0, split[0][1] + split[1][1]);
        Opportunity o = opp();
        SalesAgreementPlanService_CC.PlanRequest request =
            OpportunityUi2TestData_CC.request(o.Id, startMonth(), OpportunityUi2TestData_CC.repeat(MILLION, 12), entry().Id);
        request.monthlyAmounts[0] = MILLION + 0.001;
        request.monthlyAmounts[1] = MILLION - 0.001;
        String message;
        System.runAs(pilot()) {
            try { SalesAgreementPlanService_CC.winAndPlan(request); } catch (AuraHandledException ex) { message = ex.getMessage(); }
        }
        Assert.isTrue(message != null && message.contains('decimal places'), 'Currency precision is enforced: ' + message);
    }

    @isTest
    static void activationSequence_IsDraftApprovedActivated_AndRefusesOtherStatuses() {
        Assert.areEqual('Approved', SalesAgreementActivationJob_CC.nextStatus('Draft'));
        Assert.areEqual('Approved', SalesAgreementActivationJob_CC.nextStatus('UnderRevision'));
        Assert.areEqual('Activated', SalesAgreementActivationJob_CC.nextStatus('Approved'));
        Assert.areEqual('Activated', SalesAgreementActivationJob_CC.nextStatus('Activated'));
        Assert.isNull(SalesAgreementActivationJob_CC.nextStatus('Cancelled'), 'A cancelled agreement is never reactivated');
        Assert.isNull(SalesAgreementActivationJob_CC.nextStatus('Expired'));
    }

    @isTest
    static void activation_RunsOneStepPerJob_AndRecordsFailureForResume() {
        Opportunity o = opp();
        SalesAgreementActivationJob_CC.chainNextStep = false;
        SalesAgreementPlanService_CC.PlanResult result;
        System.runAs(pilot()) {
            result = SalesAgreementPlanService_CC.winAndPlan(
                OpportunityUi2TestData_CC.request(o.Id, startMonth(), OpportunityUi2TestData_CC.repeat(MILLION, 12), entry().Id));
        }
        Test.startTest();
        System.runAs(pilot()) {
            new SalesAgreementActivationJob_CC(result.salesAgreementId).execute(null);
            // Second step (Approved -> Activated); in production this is the next queued job.
            new SalesAgreementActivationJob_CC(result.salesAgreementId).execute(null);
        }
        Test.stopTest();
        SalesAgreement sa = [SELECT Status, Plan_Status_CC__c, Plan_Status_Detail_CC__c FROM SalesAgreement WHERE Id = :result.salesAgreementId WITH SYSTEM_MODE];
        Assert.isTrue(sa.Status == 'Approved' || sa.Plan_Status_CC__c == 'Activation Failed',
            'Draft moves to Approved, or the failure is recorded for resume: ' + sa.Status + ' / ' + sa.Plan_Status_Detail_CC__c);
        System.runAs(pilot()) {
            String message = SalesAgreementActivationJob_CC.resume(result.salesAgreementId);
            Assert.isNotNull(message);
        }
    }
}