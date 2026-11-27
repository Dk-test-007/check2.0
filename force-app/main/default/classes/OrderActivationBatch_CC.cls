/**
 * =============================================================================
 * Class Name    : OrderActivationBatch_CC
 * Description   : Activates Draft Orders created by the Integration User.
 * =============================================================================
 * Usage:
 * Schedule from Anonymous Apex, as an admin user (NOT the Integration User),
 * to run every 30 minutes at :00 and :30:
 *     System.schedule('Order Activation Batch :00', '0 0 * * * ?', new OrderActivationBatch_CC());
 *     System.schedule('Order Activation Batch :30', '0 30 * * * ?', new OrderActivationBatch_CC());
 *
 * Eligible Orders:
 *  - Created by the Integration User and still in Draft
 *  - Have at least one Order Product (Salesforce can't activate an Order without one)
 *  - Older than MINIMUM_ORDER_AGE_MINUTES, so the integration has finished loading products
 *
 * Activation is a normal update, so validation rules, flows and Order triggers
 * (including the Business Central publish) run as usual. Orders that fail stay in
 * Draft, are logged via Logger_CC and are retried on the next run.
 * =============================================================================
 */
public without sharing class OrderActivationBatch_CC implements Database.Batchable<SObject>, Schedulable {

    private static final String INTEGRATION_USER_NAME = 'Integration User';
    private static final String STATUS_DRAFT = 'Draft';
    private static final String STATUS_ACTIVATED = 'Activated';
    private static final Integer BATCH_SIZE = 50;
    private static final Integer MINIMUM_ORDER_AGE_MINUTES = 15;
    private static final Set<String> ACTIVE_JOB_STATUSES = new Set<String>{ 'Holding', 'Queued', 'Preparing', 'Processing' };

    @TestVisible private static String targetStatus = STATUS_ACTIVATED;

    // Scheduled entry point
    public void execute(SchedulableContext context) {
        run();
    }

    // Submits the batch when there is work and no run is already in progress. Returns the job Id, or null when nothing was submitted
    public static Id run() {
        // The Order trigger skips the Business Central publish for the Integration User, so the batch must not run as it
        if (UserInfo.getName() == INTEGRATION_USER_NAME) {
            Logger_CC.log(Logger_CC.ERROR, 'OrderActivationBatch_CC must not run as the Integration User, as Orders would be activated without being sent to Business Central. Reschedule it as another admin user.');
            return null;
        }
        if (isAlreadyRunning() || !hasEligibleOrders()) return null;

        return Database.executeBatch(new OrderActivationBatch_CC(), BATCH_SIZE);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Datetime createdBefore = Datetime.now().addMinutes(-MINIMUM_ORDER_AGE_MINUTES);
        return Database.getQueryLocator([
            SELECT Id FROM Order
            WHERE CreatedBy.Name = :INTEGRATION_USER_NAME
            AND Status = :STATUS_DRAFT
            AND CreatedDate <= :createdBefore
            AND Id IN (SELECT OrderId FROM OrderItem)
            ORDER BY CreatedDate
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Order> scope) {
        activateOrders(scope);
    }

    public void finish(Database.BatchableContext bc) {
        List<AsyncApexJob> jobs = [SELECT NumberOfErrors, JobItemsProcessed, ExtendedStatus FROM AsyncApexJob WHERE Id = :bc.getJobId() WITH SYSTEM_MODE];
        if (!jobs.isEmpty() && jobs[0].NumberOfErrors > 0) {
            Logger_CC.log(Logger_CC.ERROR, 'OrderActivationBatch_CC: ' + jobs[0].NumberOfErrors + ' of ' + jobs[0].JobItemsProcessed
                          + ' batch(es) failed with an unhandled error: ' + jobs[0].ExtendedStatus);
        }
    }

    // Activates the given Orders with partial success, so one failed Order doesn't block the others
    public static void activateOrders(List<Order> scope) {
        if (scope == null || scope.isEmpty()) return;

        List<Order> ordersToActivate = new List<Order>();
        for (Order ord : scope) {
            ordersToActivate.add(new Order(Id = ord.Id, Status = targetStatus));
        }

        List<Database.SaveResult> results = Database.update(ordersToActivate, false);

        String attemptTime = Datetime.now().formatGmt('yyyy-MM-dd HH:mm:ss') + ' GMT';
        List<Id> failedIds = new List<Id>();
        List<String> errors = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) continue;
            failedIds.add(ordersToActivate[i].Id);
            errors.add(ordersToActivate[i].Id + ' (' + attemptTime + '): ' + describeErrors(results[i].getErrors()));
        }

        if (!failedIds.isEmpty()) {
            Logger_CC.log(Logger_CC.ERROR, 'OrderActivationBatch_CC failed to activate ' + failedIds.size() + ' order(s): ' + String.join(errors, '; '), failedIds);
        }
    }

    @TestVisible
    private static Boolean hasEligibleOrders() {
        Datetime createdBefore = Datetime.now().addMinutes(-MINIMUM_ORDER_AGE_MINUTES);
        return ![SELECT Id FROM Order
                 WHERE CreatedBy.Name = :INTEGRATION_USER_NAME
                 AND Status = :STATUS_DRAFT
                 AND CreatedDate <= :createdBefore
                 AND Id IN (SELECT OrderId FROM OrderItem)
                 WITH SYSTEM_MODE LIMIT 1].isEmpty();
    }

    private static Boolean isAlreadyRunning() {
        return [SELECT COUNT() FROM AsyncApexJob
                WHERE JobType = 'BatchApex' AND ApexClass.Name = 'OrderActivationBatch_CC' AND Status IN :ACTIVE_JOB_STATUSES
                WITH SYSTEM_MODE] > 0;
    }

    private static String describeErrors(List<Database.Error> dbErrors) {
        List<String> messages = new List<String>();
        for (Database.Error dbError : dbErrors) {
            String fields = dbError.getFields() == null || dbError.getFields().isEmpty() ? '' : ' [' + String.join(dbError.getFields(), ', ') + ']';
            messages.add(dbError.getStatusCode() + ': ' + dbError.getMessage() + fields);
        }
        return String.join(messages, ' | ');
    }
}