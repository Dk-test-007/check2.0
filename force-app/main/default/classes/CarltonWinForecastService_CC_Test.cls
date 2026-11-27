@IsTest
private class CarltonWinForecastService_CC_Test {
    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.isolationAdmin();
        User pilot = OpportunityUi2TestData_CC.pilotUser();
        OpportunityUi2TestData_CC.assign(pilot.Id, new List<String>{'Carlton_Account_Forecast_CC',
            'ManufacturingAdvancedAccountForecastPsl'});
        System.runAs(admin) {
            Account account = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            insert new Product2(Name = 'Indicative account revenue (unallocated products)',
                ProductCode = 'CARLTON-INDICATIVE-REVENUE', IsActive = true);
            OpportunityUi2TestData_CC.standardEntry('ZZUI2 Win Product', 100, 'GBP');
            TestDmlRetry_CC.activateStandardPricebook();
            OpportunityUi2TestData_CC.newBusiness(account.Id, pilot.Id, 100, 'GBP');
        }
    }

    private static User pilot() {
        return [SELECT Id FROM User WHERE Alias = 'ui2pilot' LIMIT 1];
    }

    /** Whether the account product forecast set (AdvAccountForecastSet, deployed separately) is active in the org. */
    private static Boolean productForecastSetActive() {
        return [SELECT COUNT() FROM AdvAccountForecastSet
            WHERE DeveloperName = 'Carlton_Account_Product_Demand' AND Status = 'Active'] == 1;
    }

    private static Opportunity opportunity() {
        return [SELECT Id, Amount, Pricebook2Id FROM Opportunity WHERE Name LIKE 'ZZUI2 Win%' LIMIT 1];
    }

    private static SalesAgreementPlanService_CC.PlanRequest validRequest() {
        Id entryId = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZUI2 Win Product%' LIMIT 1].Id;
        SalesAgreementPlanService_CC.PlanRequest request = OpportunityUi2TestData_CC.request(
            opportunity().Id, Date.today().toStartOfMonth(), new List<Decimal>{100}, entryId);
        request.products[0].mode = 'Quantity';
        request.products[0].monthlyValues = new List<Decimal>{1};
        request.agreementNeeded = false;
        return request;
    }

    private static void expectRejection(SalesAgreementPlanService_CC.PlanRequest request) {
        Boolean rejected = false;
        try {
            CarltonWinForecastService_CC.completeWin(request);
        } catch (AuraHandledException ex) {
            rejected = true;
        }
        System.assert(rejected, 'Invalid forecast input must be rejected.');
    }

    @IsTest
    static void rejectsInvalidOpportunityAndStage() {
        System.runAs(pilot()) {
            SalesAgreementPlanService_CC.PlanRequest request = validRequest();
            request.opportunityId = null;
            expectRejection(request);
            request = validRequest();
            expectRejection(request);
        }
        System.assertEquals(0, [SELECT COUNT() FROM SalesAgreement]);
    }

    @IsTest
    static void rejectsInvalidTermAndProducts() {
        Opportunity opp = opportunity();
        update new Opportunity(Id = opp.Id, StageName = 'Negotiate');
        System.runAs(pilot()) {
            SalesAgreementPlanService_CC.PlanRequest request = validRequest();
            request.startMonth = Date.today().toStartOfMonth().addDays(1);
            expectRejection(request);
            request = validRequest();
            request.termMonths = 19;
            expectRejection(request);
            request = validRequest();
            request.products.clear();
            expectRejection(request);
            request = validRequest();
            request.products[0].mode = 'Invalid';
            expectRejection(request);
            request = validRequest();
            request.products[0].monthlyValues = new List<Decimal>();
            expectRejection(request);
        }
    }

    @IsTest
    static void rejectsMissingAgreementTermsAndMismatchedTotals() {
        Opportunity opp = opportunity();
        update new Opportunity(Id = opp.Id, StageName = 'Negotiate');
        System.runAs(pilot()) {
            SalesAgreementPlanService_CC.PlanRequest request = validRequest();
            request.agreementNeeded = true;
            expectRejection(request);
            request = validRequest();
            request.monthlyAmounts = new List<Decimal>{99};
            expectRejection(request);
            request = validRequest();
            request.products[0].monthlyValues = new List<Decimal>{0};
            expectRejection(request);
            request = validRequest();
            request.products[0].monthlyValues = new List<Decimal>{2};
            expectRejection(request);
        }
        System.assertEquals(0, [SELECT COUNT() FROM SalesAgreement]);
    }

    @IsTest
    static void nonAdminCompletesWinFromNegotiateInOneTransaction() {
        Opportunity opp = opportunity();
        update new Opportunity(Id = opp.Id, StageName = 'Negotiate');
        SalesAgreementPlanService_CC.PlanResult result;
        String message;
        System.runAs(pilot()) {
            try {
                result = CarltonWinForecastService_CC.completeWin(validRequest());
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
        }
        Opportunity saved = [SELECT StageName, Carlton_Monthly_Forecast_Complete_CC__c,
            Carlton_Monthly_Forecast_Plan_CC__c FROM Opportunity WHERE Id = :opp.Id];
        if (!productForecastSetActive()) {
            // The win also projects the plan onto the account forecast, which needs the product forecast set
            // (deployed separately). Without it the save is all-or-nothing: nothing is kept.
            System.assert(message != null && message.startsWith('Nothing was saved.'), message);
            System.assertEquals('Negotiate', saved.StageName, 'The stage change is rolled back.');
            System.assertEquals(false, saved.Carlton_Monthly_Forecast_Complete_CC__c);
            System.assertEquals(null, saved.Carlton_Monthly_Forecast_Plan_CC__c, 'No plan is saved.');
            return;
        }
        System.assertEquals(null, message, 'The win should be saved: ' + message);
        System.assertEquals('Saved', result.planStatus);
        System.assertEquals('Closed Won', saved.StageName);
        System.assert(saved.Carlton_Monthly_Forecast_Complete_CC__c);
        System.assertNotEquals(null, saved.Carlton_Monthly_Forecast_Plan_CC__c);
    }

    @IsTest
    static void pilotCanCompletePreviouslyClosedWinButCannotEditItAfterward() {
        Opportunity opp = opportunity();
        update new Opportunity(Id = opp.Id, StageName = 'Negotiate');
        update new Opportunity(Id = opp.Id, StageName = 'Closed Won');
        System.runAs(pilot()) {
            update new Opportunity(Id = opp.Id,
                Carlton_Monthly_Forecast_Plan_CC__c = '{"termMonths":1}',
                Carlton_Monthly_Forecast_Complete_CC__c = true);
            Database.SaveResult laterEdit = Database.update(new Opportunity(Id = opp.Id, Description = 'not allowed'), false);
            System.assertEquals(false, laterEdit.isSuccess(), 'The closed opportunity remains locked after completion.');
        }
    }

    private static void moveToNegotiate() {
        Opportunity opp = opportunity();
        update new Opportunity(Id = opp.Id, StageName = 'Negotiate');
    }

    private static String rejectionMessage(SalesAgreementPlanService_CC.PlanRequest request) {
        try {
            CarltonWinForecastService_CC.completeWin(request);
        } catch (AuraHandledException ex) {
            return ex.getMessage();
        }
        return null;
    }

    @IsTest
    static void returnsExistingPlanWithoutDuplicatingIt() {
        Opportunity opp = opportunity();
        update new Opportunity(Id = opp.Id,
            Carlton_Monthly_Forecast_Plan_CC__c = '{"termMonths":1,"agreementNeeded":false}');
        SalesAgreementPlanService_CC.PlanResult result;
        System.runAs(pilot()) {
            result = CarltonWinForecastService_CC.completeWin(validRequest());
        }
        System.assertEquals(true, result.alreadyExisted, 'A saved plan is returned rather than duplicated.');
        System.assertEquals('Saved', result.planStatus);
        System.assertEquals(null, result.salesAgreementId);
        System.assertEquals('Discover', [SELECT StageName FROM Opportunity WHERE Id = :opp.Id].StageName,
            'The Opportunity is left unchanged.');
    }

    @IsTest
    static void rejectsHorizonLongTermsAndDuplicateProducts() {
        moveToNegotiate();
        System.runAs(pilot()) {
            SalesAgreementPlanService_CC.PlanRequest request = validRequest();
            request.startMonth = Date.today().toStartOfMonth().addMonths(-1);
            System.assertEquals('The monthly plan must fit in the active 18-month account forecast horizon.',
                rejectionMessage(request));

            request = validRequest();
            request.agreementSummary = 'x'.repeat(32001);
            System.assertEquals('Agreement terms are too long.', rejectionMessage(request));

            request = validRequest();
            SalesAgreementPlanService_CC.ProductShare duplicate = new SalesAgreementPlanService_CC.ProductShare();
            duplicate.pricebookEntryId = request.products[0].pricebookEntryId;
            duplicate.mode = 'Quantity';
            duplicate.monthlyValues = new List<Decimal>{1};
            request.products.add(duplicate);
            System.assertEquals('Choose each product once.', rejectionMessage(request));
        }
    }

    @IsTest
    static void rejectsUnknownEntryLineStartNegativeValueAndMissingTotals() {
        moveToNegotiate();
        System.runAs(pilot()) {
            SalesAgreementPlanService_CC.PlanRequest request = validRequest();
            request.products[0].pricebookEntryId = UserInfo.getUserId();
            System.assertEquals('Use active products from the Opportunity price book and currency.',
                rejectionMessage(request));

            request = validRequest();
            request.products[0].startMonth = request.startMonth.addMonths(1);
            System.assertEquals('Product start month must be inside the forecast term.', rejectionMessage(request));

            request = validRequest();
            request.products[0].monthlyValues = new List<Decimal>{-1};
            System.assertEquals('Use nonnegative whole units or two-decimal values; earlier months must be zero.',
                rejectionMessage(request));

            request = validRequest();
            request.monthlyAmounts = null;
            System.assertEquals('Monthly totals are missing.', rejectionMessage(request));
        }
        System.assertEquals(0, [SELECT COUNT() FROM SalesAgreement]);
    }

    @IsTest
    static void failedAgreementSaveRollsBackEverything() {
        moveToNegotiate();
        Opportunity opp = opportunity();
        String message;
        System.runAs(pilot()) {
            SalesAgreementPlanService_CC.PlanRequest request = validRequest();
            request.agreementNeeded = true;
            request.agreementSummary = 'Agreed coverage and pricing terms.';
            request.scope = 'Not a valid scope';
            message = rejectionMessage(request);
        }
        System.assertNotEquals(null, message, 'An invalid agreement header must fail the save.');
        System.assert(message.startsWith('Nothing was saved.'), message);
        Opportunity saved = [SELECT StageName, Carlton_Monthly_Forecast_Plan_CC__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('Negotiate', saved.StageName, 'The stage change is rolled back.');
        System.assertEquals(null, saved.Carlton_Monthly_Forecast_Plan_CC__c, 'No plan is saved.');
        System.assertEquals(0, [SELECT COUNT() FROM SalesAgreement]);
    }

    @IsTest
    static void winWithAgreementSavesHeaderOrRollsBackCleanly() {
        moveToNegotiate();
        Opportunity opp = opportunity();
        SalesAgreementPlanService_CC.PlanResult result;
        String message;
        System.runAs(pilot()) {
            SalesAgreementPlanService_CC.PlanRequest request = validRequest();
            request.agreementNeeded = true;
            request.agreementSummary = 'Agreed coverage and pricing terms.';
            request.scope = null;
            try {
                result = CarltonWinForecastService_CC.completeWin(request);
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
        }
        Opportunity saved = [SELECT StageName, Carlton_Monthly_Forecast_Complete_CC__c FROM Opportunity WHERE Id = :opp.Id];
        if (result != null) {
            System.assertNotEquals(null, result.salesAgreementId, 'The draft agreement header is returned.');
            System.assertEquals(false, result.alreadyExisted);
            SalesAgreement agreement = [SELECT Source_Opportunity_CC__c, Commercial_Scope_CC__c
                FROM SalesAgreement WHERE Id = :result.salesAgreementId];
            System.assertEquals(opp.Id, agreement.Source_Opportunity_CC__c);
            System.assertEquals('Entity-wide', agreement.Commercial_Scope_CC__c);
            System.assertEquals('Closed Won', saved.StageName);
            System.assert(saved.Carlton_Monthly_Forecast_Complete_CC__c);
        } else {
            // The save is all-or-nothing: if the header cannot be created, nothing else is kept.
            System.assert(message.startsWith('Nothing was saved.'), message);
            System.assertEquals('Negotiate', saved.StageName);
            System.assertEquals(0, [SELECT COUNT() FROM SalesAgreement]);
        }
    }
}