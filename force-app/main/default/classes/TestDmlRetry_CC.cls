/**
 * Test-only helper for DML on records that many test classes share, such as the standard price book
 * and queue memberships.
 *
 * When Apex tests run in parallel (Run All Tests, RunLocalTests deployments), two test classes can
 * try to write the same row at once. The second one waits about 10 seconds and then fails with
 * UNABLE_TO_LOCK_ROW. These methods retry such writes a few times, which gives the other test time
 * to finish, and fail the test with the real errors for anything else.
 */
@IsTest
public class TestDmlRetry_CC {

    private static final Integer MAX_ATTEMPTS = 4;
    private static final String LOCK_ERROR = 'UNABLE_TO_LOCK_ROW';

    /** Activates the standard price book, which makes it visible to SOQL inside the test. */
    public static void activateStandardPricebook() {
        updateWithRetry(new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true));
    }

    /** Updates one record, retrying while the only error is a row lock held by another test. */
    public static void updateWithRetry(SObject record) {
        List<Database.Error> errors;
        for (Integer attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            Database.SaveResult result = Database.update(record, false);
            if (result.isSuccess()) {
                return;
            }
            errors = result.getErrors();
            if (!isLockOnly(errors)) {
                break;
            }
        }
        Assert.fail('Update failed: ' + errors);
    }

    /** Inserts records, retrying only those that failed because of a row lock held by another test. */
    public static void insertWithRetry(List<SObject> records) {
        List<SObject> pending = records;
        List<Database.Error> errors;
        for (Integer attempt = 1; attempt <= MAX_ATTEMPTS && !pending.isEmpty(); attempt++) {
            List<Database.SaveResult> results = Database.insert(pending, false);
            List<SObject> locked = new List<SObject>();
            errors = new List<Database.Error>();
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    continue;
                }
                if (!isLockOnly(results[i].getErrors())) {
                    Assert.fail('Insert failed: ' + results[i].getErrors());
                }
                locked.add(pending[i]);
                errors.addAll(results[i].getErrors());
            }
            pending = locked;
        }
        if (!pending.isEmpty()) {
            Assert.fail('Insert failed: ' + errors);
        }
    }

    private static Boolean isLockOnly(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return false;
        }
        for (Database.Error error : errors) {
            if (String.valueOf(error.getStatusCode()) != LOCK_ERROR) {
                return false;
            }
        }
        return true;
    }
}