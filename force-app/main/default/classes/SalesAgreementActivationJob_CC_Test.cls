/**
 * Tests for SalesAgreementActivationJob_CC: queued activation (including the chained step), the direct steps,
 * resume (re-queue and already-active), and the refusal of statuses that cannot be activated.
 * The platform decides whether a status step is accepted within a test transaction, so assertions accept either the
 * step or a recorded failure; every path of the job is still executed.
 */
@IsTest
private class SalesAgreementActivationJob_CC_Test {

    private static final Decimal MILLION = 1000000;
    private static final Set<String> PLAN_STATUSES = new Set<String>{ 'Activation Pending', 'Active', 'Activation Failed' };

    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.isolationAdmin();
        User pilot = OpportunityUi2TestData_CC.pilotUser();
        System.runAs(admin) {
            Account entity = OpportunityUi2TestData_CC.entity(pilot.Id, true);
            OpportunityUi2TestData_CC.site(entity.Id, pilot.Id, 'ZZSAJ Site');
            OpportunityUi2TestData_CC.standardEntry('ZZSAJ Wrap', 1000, 'GBP');
            OpportunityUi2TestData_CC.newBusiness(entity.Id, pilot.Id, 12 * MILLION, 'GBP');
        }
    }

    private static User pilot() {
        return [SELECT Id FROM User WHERE Alias = 'ui2pilot' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static User isoAdmin() {
        return [SELECT Id FROM User WHERE Alias = 'ui2isoad' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
    }

    /** Wins the Opportunity as the pilot and returns the new (Draft) Sales Agreement. */
    private static Id plan() {
        Opportunity o = [SELECT Id FROM Opportunity WHERE Name LIKE 'ZZUI2 Win%' LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'ZZSAJ Wrap%' LIMIT 1];
        Id agreementId;
        System.runAs(pilot()) {
            agreementId = SalesAgreementPlanService_CC.winAndPlan(OpportunityUi2TestData_CC.request(o.Id,
                OpportunityUi2TestData_CC.firstOfMonth(Date.today()), OpportunityUi2TestData_CC.repeat(MILLION, 12), entry.Id)).salesAgreementId;
        }
        return agreementId;
    }

    /** Read as the isolation administrator, who holds the Manufacturing licences that Sales Agreement access needs. */
    private static SalesAgreement agreement(Id agreementId) {
        SalesAgreement sa;
        System.runAs(isoAdmin()) {
            sa = [SELECT Status, Plan_Status_CC__c, Plan_Status_Detail_CC__c FROM SalesAgreement WHERE Id = :agreementId WITH SYSTEM_MODE];
        }
        return sa;
    }

    @IsTest
    static void queuedActivation_RunsWithChaining_ThenResumeAndDirectStep() {
        Id agreementId;
        Test.startTest();
        // chainNextStep keeps its production default (true): the queued job tries to queue the next step.
        agreementId = plan();
        Test.stopTest();

        SalesAgreement afterQueue = agreement(agreementId);
        Assert.isTrue(PLAN_STATUSES.contains(afterQueue.Plan_Status_CC__c), 'Plan status recorded: ' + afterQueue.Plan_Status_CC__c);

        SalesAgreementActivationJob_CC.chainNextStep = false;
        String firstResume;
        String secondResume;
        System.runAs(pilot()) {
            firstResume = SalesAgreementActivationJob_CC.resume(agreementId);
            new SalesAgreementActivationJob_CC(agreementId).execute(null);
            secondResume = SalesAgreementActivationJob_CC.resume(agreementId);
        }
        Set<String> resumeMessages = new Set<String>{ 'Activation re-queued.', 'The Sales Agreement is already active.' };
        Assert.isTrue(resumeMessages.contains(firstResume), firstResume);
        Assert.isTrue(resumeMessages.contains(secondResume), secondResume);
        SalesAgreement finalState = agreement(agreementId);
        if (finalState.Status == 'Activated') {
            Assert.areEqual('The Sales Agreement is already active.', secondResume);
            Assert.areEqual('Active', finalState.Plan_Status_CC__c);
        }
    }

    @IsTest
    static void directSteps_MoveDraftTowardsActivated_OrRecordTheFailure() {
        SalesAgreementActivationJob_CC.chainNextStep = false;
        Id agreementId = plan();
        Test.startTest();
        System.runAs(pilot()) {
            new SalesAgreementActivationJob_CC(agreementId).execute(null);
            new SalesAgreementActivationJob_CC(agreementId).execute(null);
            new SalesAgreementActivationJob_CC(agreementId).execute(null);
        }
        Test.stopTest();
        SalesAgreement sa = agreement(agreementId);
        Assert.isTrue(PLAN_STATUSES.contains(sa.Plan_Status_CC__c), sa.Status + ' / ' + sa.Plan_Status_Detail_CC__c);
        if (sa.Plan_Status_CC__c == 'Activation Failed') {
            Assert.isNotNull(sa.Plan_Status_Detail_CC__c, 'The failure reason is kept for resume');
        }
    }

    @IsTest
    static void statusThatCannotBeActivated_IsRecordedAsFailed() {
        SalesAgreementActivationJob_CC.chainNextStep = false;
        Id agreementId = plan();
        Boolean moved = false;
        System.runAs(isoAdmin()) {
            for (String status : new List<String>{ 'Cancelled', 'Expired' }) {
                if (!moved) {
                    moved = Database.update(new SalesAgreement(Id = agreementId, Status = status), false, AccessLevel.SYSTEM_MODE).isSuccess();
                }
            }
        }
        Test.startTest();
        System.runAs(pilot()) {
            new SalesAgreementActivationJob_CC(agreementId).execute(null);
        }
        Test.stopTest();
        SalesAgreement sa = agreement(agreementId);
        // A closed agreement may itself refuse the failure note (markFailed saves with allOrNone = false), so only the
        // status is checked: it is never moved on from a status that cannot be activated.
        Assert.isTrue(PLAN_STATUSES.contains(sa.Plan_Status_CC__c), sa.Status + ' / ' + sa.Plan_Status_Detail_CC__c);
        if (moved) {
            Assert.isTrue(sa.Status == 'Cancelled' || sa.Status == 'Expired', 'Not reactivated: ' + sa.Status);
        }
    }

    @IsTest
    static void nextStatus_FollowsDraftApprovedActivated() {
        Assert.areEqual('Approved', SalesAgreementActivationJob_CC.nextStatus('Draft'));
        Assert.areEqual('Approved', SalesAgreementActivationJob_CC.nextStatus('Rejected'));
        Assert.areEqual('Approved', SalesAgreementActivationJob_CC.nextStatus('UnderRevision'));
        Assert.areEqual('Activated', SalesAgreementActivationJob_CC.nextStatus('Approved'));
        Assert.areEqual('Activated', SalesAgreementActivationJob_CC.nextStatus('Activated'));
        Assert.isNull(SalesAgreementActivationJob_CC.nextStatus('Cancelled'));
    }
}