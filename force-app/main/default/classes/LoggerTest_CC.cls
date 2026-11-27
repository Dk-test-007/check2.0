@isTest
private class LoggerTest_CC {

    private static Exception buildWrappedException() {
        Exception result;
        try {
            try {
                throw new Logger_CC.LoggerException('Root cause failure');
            } catch (Exception rootEx) {
                throw new Logger_CC.LoggerException('Wrapper failure', rootEx);
            }
        } catch (Exception wrapperEx) {
            result = wrapperEx;
        }
        return result;
    }

    private static Exception buildRuntimeException() {
        Exception result;
        try {
            Integer parsed = Integer.valueOf('not-a-number');
        } catch (Exception parseEx) {
            result = parseEx;
        }
        return result;
    }

    private static Logger_CC.LogInput buildInput(String level, String message, String sourceType, String originLocation) {
        Logger_CC.LogInput input = new Logger_CC.LogInput();
        input.level = level;
        input.message = message;
        input.sourceType = sourceType;
        input.originLocation = originLocation;
        return input;
    }

    @isTest
    static void testApexOverloads() {
        List<Id> recordIds = new List<Id>{UserInfo.getUserId(), UserInfo.getProfileId()};
        Exception runtimeEx = buildRuntimeException();
        Exception wrappedEx = buildWrappedException();
        Test.startTest();
        Logger_CC.log(Logger_CC.INFO, 'Simple info message');
        Logger_CC.log(Logger_CC.SUCCESS, 'Message with comments', 'Additional context supplied by the caller');
        Logger_CC.log(Logger_CC.ERROR, 'Message with exception', runtimeEx);
        Logger_CC.log(Logger_CC.INFO, 'Message with record ids', recordIds);
        Logger_CC.log(Logger_CC.ERROR, 'Message with exception and record ids', wrappedEx, recordIds);
        Logger_CC.log(Logger_CC.ERROR, '', runtimeEx);
        Logger_CC.log(runtimeEx);
        Test.stopTest();
    }

    @isTest
    static void testNullAndEmptyInputs() {
        Test.startTest();
        Logger_CC.log((Logger_CC.LogInput) null);
        Logger_CC.log((List<Logger_CC.LogInput>) null);
        Logger_CC.log(new List<Logger_CC.LogInput>());
        Logger_CC.log(new List<Logger_CC.LogInput>{null, null});
        Logger_CC.log((Exception) null);
        Logger_CC.log(Logger_CC.INFO, 'Null record id list', (List<Id>) null);
        Logger_CC.log(Logger_CC.INFO, 'Empty record id list', new List<Id>());
        Logger_CC.log(Logger_CC.INFO, 'Record id list holding nulls', new List<Id>{null});
        Logger_CC.log(Logger_CC.ERROR, 'Null exception reference', (Exception) null);
        Test.stopTest();
    }

    @isTest
    static void testLevelNormalization() {
        List<Logger_CC.LogInput> inputs = new List<Logger_CC.LogInput>{
            buildInput('DEBUG', 'Debug maps to info', null, null),
            buildInput('warning', 'Warning maps to error', null, null),
            buildInput('Fatal', 'Fatal maps to error', null, null),
            buildInput('  error  ', 'Padded level is trimmed', null, null),
            buildInput('SUCCESS', 'Success is retained', null, null),
            buildInput('INFO', 'Info is retained', null, null),
            buildInput('UNRECOGNISED', 'Unknown level falls back to info', null, null),
            buildInput('', 'Blank level falls back to info', null, null),
            buildInput(null, 'Null level falls back to info', null, null)
        };
        Test.startTest();
        Logger_CC.log(inputs);
        Test.stopTest();
    }

    @isTest
    static void testSourceTypeNormalization() {
        List<Logger_CC.LogInput> inputs = new List<Logger_CC.LogInput>();
        for (String sourceType : new List<String>{'APEX', 'trigger', 'Batch', 'FLOW', 'LWC', 'aura', 'Integration', 'OTHER', 'Unmapped Value', '', null}) {
            inputs.add(buildInput(Logger_CC.INFO, 'Source type ' + sourceType, sourceType, 'Class.OrderService_CC.sync: line 42, column 1'));
        }
        Logger_CC.LogInput integrationInput = buildInput(Logger_CC.SUCCESS, 'Integration name drives the source type', null, null);
        integrationInput.integrationName = 'Carlton Payment Gateway';
        inputs.add(integrationInput);
        Test.startTest();
        Logger_CC.log(inputs);
        Test.stopTest();
    }

    @isTest
    static void testOriginAndClassDerivation() {
        List<Logger_CC.LogInput> inputs = new List<Logger_CC.LogInput>{
            buildInput(Logger_CC.INFO, 'Class frame with method', null, 'Class.OrderService_CC.sync: line 42, column 1'),
            buildInput(Logger_CC.INFO, 'Class frame without method', null, 'Class.OrderService_CC: line 42, column 1'),
            buildInput(Logger_CC.ERROR, 'Trigger frame', null, 'Trigger.LeadTrigger_CC: line 7, column 1'),
            buildInput(Logger_CC.INFO, 'Anonymous frame', null, 'AnonymousBlock: line 1, column 1'),
            buildInput(Logger_CC.INFO, 'Derived origin from stack trace', 'Apex', null)
        };
        Logger_CC.LogInput explicitClass = buildInput(Logger_CC.INFO, 'Explicit source class wins', 'Apex', 'Class.OrderService_CC.sync: line 42, column 1');
        explicitClass.sourceClass = 'ManuallyProvidedClass_CC';
        inputs.add(explicitClass);
        Test.startTest();
        Logger_CC.log(inputs);
        Test.stopTest();
    }

    @isTest
    static void testFieldTruncation() {
        Logger_CC.LogInput input = buildInput(Logger_CC.ERROR, 'x'.repeat(30500), 'Apex', 'Class.' + 'y'.repeat(400));
        input.sourceClass = 'z'.repeat(400);
        input.integrationName = 'i'.repeat(400);
        input.comments = 'c'.repeat(30500);
        input.relatedRecordIds = 'r'.repeat(30500);
        Test.startTest();
        Logger_CC.log(input);
        Test.stopTest();
    }

    @isTest
    static void testFlowEntryPoint() {
        Logger_CC.LogInput blankSource = buildInput(Logger_CC.SUCCESS, 'Flow log without source type', null, null);
        Logger_CC.LogInput presetSource = buildInput(Logger_CC.ERROR, 'Flow log with preset source type', 'Integration', null);
        Test.startTest();
        Logger_CC.logFromFlow(null);
        Logger_CC.logFromFlow(new List<Logger_CC.LogInput>{blankSource, presetSource, null});
        Test.stopTest();
    }

    @isTest
    static void testComponentEntryPoint() {
        Test.startTest();
        Logger_CC.logFromComponent(Logger_CC.ERROR, 'Component failure', 'leadCaptureForm', String.valueOf(UserInfo.getUserId()), 'Raised from the LWC error boundary');
        Logger_CC.logFromComponent(null, 'Component failure without level', null, null, null);
        Test.stopTest();
    }

    @isTest
    static void testLoggingDisabledByConfig() {
        Logger_CC.CONFIG = new Logger_Config_CC__mdt(Is_Enabled_CC__c = false);
        Test.startTest();
        Logger_CC.log(Logger_CC.ERROR, 'Suppressed because logging is disabled');
        Logger_CC.log(new List<Logger_CC.LogInput>{new Logger_CC.LogInput(Logger_CC.INFO, 'Also suppressed')});
        Test.stopTest();
    }

    @isTest
    static void testLoggingEnabledByConfig() {
        Logger_CC.CONFIG = new Logger_Config_CC__mdt(Is_Enabled_CC__c = true);
        Test.startTest();
        Logger_CC.log(Logger_CC.SUCCESS, 'Published because logging is explicitly enabled');
        Test.stopTest();
    }
}