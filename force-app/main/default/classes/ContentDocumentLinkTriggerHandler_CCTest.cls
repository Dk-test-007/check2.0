/**
 * =============================================================================
 * Class Name    : ContentDocumentLinkTriggerHandler_CCTest
 * Description   : Unit test class for ContentDocumentLinkTriggerHandler_CC.
 *                 Covers file upload validation for closed Cases and allows
 *                 file uploads for open Cases and non-Case records.
 *
 * Author        : Nipun Jain
 * Created Date  :
 * =============================================================================
 */

@IsTest
private class ContentDocumentLinkTriggerHandler_CCTest {

    @TestSetup
    static void setupData() {
        Case openCase = new Case(
            Subject = 'Open Case',
            Status = 'New',
            Origin = 'Phone'
        );

        Case closedCase = new Case(
            Subject = 'Closed Case',
            Status = 'Closed',
            Origin = 'Phone'
        );

        insert new List<Case>{openCase, closedCase};

        ContentVersion contentVersion = new ContentVersion(
            Title = 'Test File',
            PathOnClient = 'TestFile.txt',
            VersionData = Blob.valueOf('Test file content')
        );

        insert contentVersion;
    }

    @IsTest
    static void testFileUploadToClosedCase() {
        Case closedCase = [
            SELECT Id, IsClosed
            FROM Case
            WHERE Subject = 'Closed Case'
            LIMIT 1
        ];

        ContentVersion contentVersion = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Title = 'Test File'
            LIMIT 1
        ];

        ContentDocumentLink cdl = new ContentDocumentLink(
            ContentDocumentId = contentVersion.ContentDocumentId,
            LinkedEntityId = closedCase.Id,
            ShareType = 'V'
        );

        Test.startTest();

        Database.SaveResult result = Database.insert(cdl, false);

        Test.stopTest();

        System.assertEquals(false, result.isSuccess());
        System.assertEquals(
            'You cannot upload a file to a closed Case.',
            result.getErrors()[0].getMessage()
        );
    }

    @IsTest
    static void testFileUploadToOpenCase() {
        Case openCase = [
            SELECT Id, IsClosed
            FROM Case
            WHERE Subject = 'Open Case'
            LIMIT 1
        ];

        ContentVersion contentVersion = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Title = 'Test File'
            LIMIT 1
        ];

        ContentDocumentLink cdl = new ContentDocumentLink(
            ContentDocumentId = contentVersion.ContentDocumentId,
            LinkedEntityId = openCase.Id,
            ShareType = 'V'
        );

        Test.startTest();

        Database.SaveResult result = Database.insert(cdl, false);

        Test.stopTest();

        System.assertEquals(true, result.isSuccess());
    }

    @IsTest
    static void testFileUploadToNonCaseRecord() {
        Account account = new Account(
            Name = 'Test Account'
        );
        insert account;

        ContentVersion contentVersion = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Title = 'Test File'
            LIMIT 1
        ];

        ContentDocumentLink cdl = new ContentDocumentLink(
            ContentDocumentId = contentVersion.ContentDocumentId,
            LinkedEntityId = account.Id,
            ShareType = 'V'
        );

        Test.startTest();

        Database.SaveResult result = Database.insert(cdl, false);

        Test.stopTest();

        System.assertEquals(true, result.isSuccess());
    }
}