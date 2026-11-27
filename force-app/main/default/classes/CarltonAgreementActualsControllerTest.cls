@IsTest
private class CarltonAgreementActualsControllerTest {
    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.isolationAdmin();
        User pilot = OpportunityUi2TestData_CC.pilotUser();
        System.runAs(admin) {
            Account account = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            OpportunityUi2TestData_CC.standardEntry('ZZTEST Agreement Product', 100, 'GBP');
            OpportunityUi2TestData_CC.newBusiness(account.Id, pilot.Id, 100, 'GBP');
        }
    }

    private static User pilot() {
        return [SELECT Id FROM User WHERE Alias = 'ui2pilot' AND IsActive = true LIMIT 1];
    }

    private static Opportunity opportunity() {
        return [SELECT Id, AccountId FROM Opportunity WHERE Name LIKE 'ZZUI2 Win%' LIMIT 1];
    }

    private static Id makeAgreement() {
        Opportunity opp = opportunity();
        PricebookEntry entry = [SELECT Id FROM PricebookEntry
            WHERE Product2.Name LIKE 'ZZTEST Agreement Product%' LIMIT 1];
        Date startMonth = Date.today().toStartOfMonth();
        SalesAgreementActivationJob_CC.chainNextStep = false;
        SalesAgreementPlanService_CC.PlanResult result;
        System.runAs(pilot()) {
            result = SalesAgreementPlanService_CC.winAndPlan(
                OpportunityUi2TestData_CC.request(opp.Id, startMonth, new List<Decimal>{ 100 }, entry.Id));
        }
        return result.salesAgreementId;
    }

    private static SalesAgreementProductSchedule schedule(Id agreementId) {
        return [SELECT Id, ActualAmount, ForecastedQuantityValue, SalesPrice
            FROM SalesAgreementProductSchedule
            WHERE SalesAgreementProduct.SalesAgreementId = :agreementId LIMIT 1];
    }

    @IsTest
    static void overviewShowsAgreementScheduleAndSourceValues() {
        System.assertEquals(0, CarltonAgreementActualsController.getOverview(null).rows.size());
        Id agreementId = makeAgreement();
        CarltonAgreementActualsController.Overview view =
            CarltonAgreementActualsController.getOverview(opportunity().AccountId);
        System.assertEquals(1, view.agreements.size());
        System.assertEquals(agreementId, view.agreements[0].id);
        System.assertEquals(1, view.rows.size());
        System.assertEquals(100, view.rows[0].forecastRevenueBasis);
        System.assertEquals(false, view.rows[0].hasOverride);
        System.assertEquals(view.rows[0].sourceActual, view.rows[0].effectiveActual);
    }

    @IsTest
    static void actualOverrideAndRestoreKeepTheSourceSchedule() {
        Id agreementId = makeAgreement();
        Opportunity opp = opportunity();
        SalesAgreementProductSchedule before = schedule(agreementId);
        Id overrideId = CarltonAgreementActualsController.saveActual(
            opp.AccountId, before.Id, 75, false, '  Manager review  ');
        System.assertNotEquals(null, overrideId);
        CarltonAgreementActualsController.ActualRow overridden =
            CarltonAgreementActualsController.getOverview(opp.AccountId).rows[0];
        System.assert(overridden.hasOverride);
        System.assertEquals(75, overridden.effectiveActual);
        System.assertEquals('Manager review', overridden.lastReason);
        CarltonAgreementActualsController.saveActual(opp.AccountId, before.Id, null, true, 'Use source');
        CarltonAgreementActualsController.ActualRow restored =
            CarltonAgreementActualsController.getOverview(opp.AccountId).rows[0];
        System.assertEquals(false, restored.hasOverride);
        System.assertEquals(restored.sourceActual, restored.effectiveActual);
        System.assertEquals(before.ActualAmount, schedule(agreementId).ActualAmount,
            'An Account override must not rewrite Salesforce Order actuals.');
    }

    @IsTest
    static void forecastEditUpdatesScheduleAndWritesAuditRecord() {
        Id agreementId = makeAgreement();
        SalesAgreementProductSchedule before = schedule(agreementId);
        Id changeId = CarltonAgreementActualsController.saveForecast(
            opportunity().AccountId, before.Id, 2, 'Demand changed');
        SalesAgreementProductSchedule afterEdit = schedule(agreementId);
        System.assertEquals(2, afterEdit.ForecastedQuantityValue);
        CarltonAgreementForecastChange__c audit = [SELECT PreviousQuantity__c, NewQuantity__c,
            PreviousRevenueBasis__c, NewRevenueBasis__c, Reason__c
            FROM CarltonAgreementForecastChange__c WHERE Id = :changeId];
        System.assertEquals(before.ForecastedQuantityValue, audit.PreviousQuantity__c);
        System.assertEquals(2, audit.NewQuantity__c);
        System.assertEquals(200, audit.NewRevenueBasis__c);
        System.assertEquals('Demand changed', audit.Reason__c);
    }
}