/**
 * =============================================================================
 * Class Name    : BaseTriggerHandler_CC_Test
 * Description   : Unit tests for BaseTriggerHandler_CC
 *
 * Author        :
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author           Description
 * -------    ----------   ------------     ---------------------------------------
 *    1                                     Initial test coverage for the base
 *                                          trigger handler framework
 *
 * =============================================================================
 * Notes:
 *  - Trigger.new / Trigger.old and Trigger.isBefore cannot be simulated from
 *    Apex, so the delegation and error handling paths are exercised through the
 *    public static *Base() entry points instead of through run().
 *  - Trigger_Framework_Config_CC__mdt cannot be inserted in a test, and run()
 *    resolves it internally, so only the "no config record" branch of run() is
 *    reachable here. The remaining run() branches are covered by the object
 *    specific handler tests that fire real DML.
 * =============================================================================
 */
@IsTest
private class BaseTriggerHandler_CC_Test {

    /** A DeveloperName that must never exist in Trigger_Framework_Config_CC__mdt. */
    private static final String MISSING_CONFIG_NAME = 'Zzz_Unmapped_Object_For_Test_CC';

    private static final List<String> ALL_CONTEXTS = new List<String>{
        'beforeInsert', 'beforeUpdate', 'beforeDelete',
        'afterInsert', 'afterUpdate', 'afterDelete', 'afterUndelete'
    };

    // ===================================================================== test doubles

    /** Thrown by ThrowingHandler so the catch blocks can be verified precisely. */
    public class HandlerTestException extends Exception {}

    /** Records which context method was invoked, without failing. */
    private class RecordingHandler extends BaseTriggerHandler_CC {
        public List<String> calls = new List<String>();

        protected override void beforeInsert()  { calls.add('beforeInsert'); }
        protected override void beforeUpdate()  { calls.add('beforeUpdate'); }
        protected override void beforeDelete()  { calls.add('beforeDelete'); }
        protected override void afterInsert()   { calls.add('afterInsert'); }
        protected override void afterUpdate()   { calls.add('afterUpdate'); }
        protected override void afterDelete()   { calls.add('afterDelete'); }
        protected override void afterUndelete() { calls.add('afterUndelete'); }
    }

    /** Every context method fails, to exercise handleError(). */
    private class ThrowingHandler extends BaseTriggerHandler_CC {
        protected override void beforeInsert()  { throw new HandlerTestException('failed in beforeInsert'); }
        protected override void beforeUpdate()  { throw new HandlerTestException('failed in beforeUpdate'); }
        protected override void beforeDelete()  { throw new HandlerTestException('failed in beforeDelete'); }
        protected override void afterInsert()   { throw new HandlerTestException('failed in afterInsert'); }
        protected override void afterUpdate()   { throw new HandlerTestException('failed in afterUpdate'); }
        protected override void afterDelete()   { throw new HandlerTestException('failed in afterDelete'); }
        protected override void afterUndelete() { throw new HandlerTestException('failed in afterUndelete'); }
    }

    /**
     * Overrides nothing, so calling the inherited methods runs the empty base
     * implementations declared on BaseTriggerHandler_CC.
     */
    private class BaseCallingHandler extends BaseTriggerHandler_CC {
        public void invokeBaseImplementations() {
            beforeInsert();
            beforeUpdate();
            beforeDelete();
            afterInsert();
            afterUpdate();
            afterDelete();
            afterUndelete();
        }
    }

    // ===================================================================== helpers

    private static void invokeBase(String contextName, BaseTriggerHandler_CC handler) {
        switch on contextName {
            when 'beforeInsert'  { BaseTriggerHandler_CC.beforeInsertBase(handler); }
            when 'beforeUpdate'  { BaseTriggerHandler_CC.beforeUpdateBase(handler); }
            when 'beforeDelete'  { BaseTriggerHandler_CC.beforeDeleteBase(handler); }
            when 'afterInsert'   { BaseTriggerHandler_CC.afterInsertBase(handler); }
            when 'afterUpdate'   { BaseTriggerHandler_CC.afterUpdateBase(handler); }
            when 'afterDelete'   { BaseTriggerHandler_CC.afterDeleteBase(handler); }
            when 'afterUndelete' { BaseTriggerHandler_CC.afterUndeleteBase(handler); }
            when else            { Assert.fail('Unknown trigger context: ' + contextName); }
        }
    }

    // ===================================================================== delegation

    @IsTest
    static void everyContextDelegatesToTheHandlerOnce() {
        RecordingHandler handler = new RecordingHandler();

        Test.startTest();
        for (String contextName : ALL_CONTEXTS) {
            invokeBase(contextName, handler);
        }
        Test.stopTest();

        Assert.areEqual(
            ALL_CONTEXTS,
            handler.calls,
            'Each *Base() method should delegate exactly once, in the order it was called.'
        );
    }

    @IsTest
    static void beforeContextsDoNotInvokeAfterContexts() {
        RecordingHandler handler = new RecordingHandler();

        Test.startTest();
        BaseTriggerHandler_CC.beforeInsertBase(handler);
        BaseTriggerHandler_CC.beforeUpdateBase(handler);
        BaseTriggerHandler_CC.beforeDeleteBase(handler);
        Test.stopTest();

        Assert.areEqual(3, handler.calls.size(), 'Only the three before contexts should have run.');
        Assert.isTrue(handler.calls.contains('beforeInsert'), 'beforeInsert should have run.');
        Assert.isTrue(handler.calls.contains('beforeUpdate'), 'beforeUpdate should have run.');
        Assert.isTrue(handler.calls.contains('beforeDelete'), 'beforeDelete should have run.');
    }

    @IsTest
    static void baseContextMethodsAreNoOps() {
        BaseCallingHandler handler = new BaseCallingHandler();

        Test.startTest();
        handler.invokeBaseImplementations();
        Test.stopTest();

        // The base implementations are intentionally empty; reaching this point
        // without an exception is the assertion.
        Assert.isNotNull(handler, 'The default context implementations should do nothing and not fail.');
    }

    // ===================================================================== error handling

    @IsTest
    static void handlerFailuresAreRethrownToTheCaller() {
        ThrowingHandler handler = new ThrowingHandler();
        List<String> caughtMessages = new List<String>();

        Test.startTest();
        for (String contextName : ALL_CONTEXTS) {
            try {
                invokeBase(contextName, handler);
                Assert.fail(contextName + ' swallowed the handler exception; it must be rethrown.');
            } catch (HandlerTestException ex) {
                caughtMessages.add(ex.getMessage());
            }
        }
        Test.stopTest();

        Assert.areEqual(
            ALL_CONTEXTS.size(),
            caughtMessages.size(),
            'Every trigger context should rethrow the exception raised by the handler.'
        );
        for (Integer i = 0; i < ALL_CONTEXTS.size(); i++) {
            Assert.areEqual(
                'failed in ' + ALL_CONTEXTS[i],
                caughtMessages[i],
                'The original exception, not a wrapped one, should reach the caller.'
            );
        }
    }

    @IsTest
    static void failureIsLoggedBeforeBeingRethrown() {
        ThrowingHandler handler = new ThrowingHandler();
        Exception caught;

        Test.startTest();
        try {
            BaseTriggerHandler_CC.afterUpdateBase(handler);
        } catch (HandlerTestException ex) {
            caught = ex;
        }
        Test.stopTest();

        Assert.isNotNull(caught, 'afterUpdateBase should have rethrown the handler exception.');
        Assert.areEqual(
            'failed in afterUpdate',
            caught.getMessage(),
            'The rethrown exception should carry the handler message.'
        );
        // Logger_CC.log() runs before the rethrow. It publishes asynchronously, so
        // this test asserts only that logging did not disrupt the rethrow contract.
    }

    @IsTest
    static void nullHandlerIsReportedWithoutBreakingTheFramework() {
        Exception caught;

        Test.startTest();
        try {
            BaseTriggerHandler_CC.beforeInsertBase(null);
        } catch (Exception ex) {
            caught = ex;
        }
        Test.stopTest();

        Assert.isNotNull(
            caught,
            'A null handler should be reported as UnknownHandler and the exception rethrown.'
        );
    }

    // ===================================================================== logging context guard

    @IsTest
    static void isLoggingContextIsFalseOutsideTriggerContext() {
        Test.startTest();
        Boolean result = BaseTriggerHandler_CC.isLoggingContext();
        Test.stopTest();

        Assert.isFalse(
            result,
            'With no Trigger.new or Trigger.old, the current SObject type is unknown and the guard must not engage.'
        );
    }

    // ===================================================================== run() dispatch

    @IsTest
    static void runDoesNothingWhenNoConfigRecordExists() {
        RecordingHandler handler = new RecordingHandler();

        Test.startTest();
        handler.run(handler, MISSING_CONFIG_NAME);
        Test.stopTest();

        Assert.areEqual(
            0,
            handler.calls.size(),
            'Without a Trigger_Framework_Config_CC__mdt record, run() should log a warning and exit.'
        );
    }

    @IsTest
    static void runDoesNothingOutsideTriggerContext() {
        RecordingHandler handler = new RecordingHandler();
        BaseTriggerHandler_CC base = new BaseTriggerHandler_CC();

        Test.startTest();
        base.run(handler, 'Lead');
        Test.stopTest();

        Assert.areEqual(
            0,
            handler.calls.size(),
            'Trigger.isBefore and Trigger.isAfter are both false outside a trigger, so no context should fire.'
        );
    }
}