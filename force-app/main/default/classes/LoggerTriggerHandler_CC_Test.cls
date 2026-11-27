/**
 * =============================================================================
 * Class Name    : LoggerTriggerHandler_CC_Test
 * Description   : Unit tests for LoggerTrigger_CC / LoggerTriggerHandler_CC. An ERROR log
 *                 from an Integration copies the integration error message onto the related
 *                 Account or Order records; every other log is left alone.
 * =============================================================================
 */
@IsTest
private class LoggerTriggerHandler_CC_Test {

    private static final String ACCOUNT_NAME = 'Logger Sync Test Account';

    @TestSetup
    static void setup() {
        insert new Account(Name = ACCOUNT_NAME);
    }

    private static Account account() {
        return [SELECT Id, BC_Sync_Status_CC__c, Business_Central_Customer_Sync_Error_CC__c
                FROM Account WHERE Name = :ACCOUNT_NAME LIMIT 1];
    }

    private static Logger_CC__c integrationError(String rootCause, String relatedIds) {
        return new Logger_CC__c(
            Log_Level_CC__c = 'ERROR',
            Source_Type_CC__c = 'Integration',
            Message_CC__c = 'Business Central callout failed',
            Root_Cause_CC__c = rootCause,
            Related_Record_Ids_CC__c = relatedIds
        );
    }

    /** A syntactically valid Id for an Order that does not exist. */
    private static String missingOrderId() {
        return Order.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
    }

    @IsTest
    static void nestedErrorMessageIsCopiedToAccount() {
        Account acc = account();

        insert integrationError('{"error":{"code":"BadRequest","message":"Customer number already exists"}}',
            ' ' + acc.Id + ' ');

        Account saved = account();
        Assert.areEqual('Callout Failed', saved.BC_Sync_Status_CC__c, 'The Account is marked as failed');
        Assert.areEqual('Customer number already exists', saved.Business_Central_Customer_Sync_Error_CC__c,
            'The nested error message is copied to the Account');
    }

    @IsTest
    static void topLevelMessageIsUsedWhenThereIsNoErrorNode() {
        Account acc = account();

        insert integrationError('{"message":"Service unavailable"}', acc.Id + ';' + UserInfo.getUserId());

        Account saved = account();
        Assert.areEqual('Callout Failed', saved.BC_Sync_Status_CC__c, 'The Account is marked as failed');
        Assert.areEqual('Service unavailable', saved.Business_Central_Customer_Sync_Error_CC__c,
            'The top-level message is used when the response has no error node');
    }

    @IsTest
    static void orderIdsAreHandledAndUpdateFailuresDoNotBlockTheLog() {
        // The Order does not exist, so the update fails; the framework swallows errors raised
        // inside the logging trigger so the log itself is still saved.
        Logger_CC__c log = integrationError('{"error":{"message":"Order rejected"}}',
            missingOrderId() + ';not-an-id;;' + UserInfo.getUserId());

        insert log;

        Assert.areEqual(1, [SELECT COUNT() FROM Logger_CC__c WHERE Id = :log.Id], 'The log is saved');
    }

    @IsTest
    static void unusableLogsAreIgnored() {
        Account acc = account();
        List<Logger_CC__c> logs = new List<Logger_CC__c>{
            integrationError('this is not json', acc.Id),
            integrationError(null, acc.Id),
            integrationError('[1, 2, 3]', acc.Id),
            integrationError('{"status":400}', acc.Id),
            integrationError('{"message":"No related records"}', null),
            new Logger_CC__c(Log_Level_CC__c = 'ERROR', Source_Type_CC__c = 'Apex',
                Root_Cause_CC__c = '{"message":"Not an integration"}', Related_Record_Ids_CC__c = acc.Id),
            new Logger_CC__c(Log_Level_CC__c = 'INFO', Source_Type_CC__c = 'Integration',
                Root_Cause_CC__c = '{"message":"Informational"}', Related_Record_Ids_CC__c = acc.Id)
        };

        insert logs;

        Assert.areEqual(logs.size(), [SELECT COUNT() FROM Logger_CC__c WHERE Id IN :logs], 'Every log is saved');
        Account saved = account();
        Assert.areNotEqual('Callout Failed', saved.BC_Sync_Status_CC__c, 'The Account is not changed');
        Assert.isNull(saved.Business_Central_Customer_Sync_Error_CC__c, 'No error message is copied');
    }
}