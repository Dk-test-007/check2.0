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

    // ------------------------------------------------------------------ Notes on activities

    /**
     * Whether the ContentDocumentLink trigger runs its after-insert context (sharing Notes from activities to their
     * related records) in this org. It is switched per org in Trigger_Framework_Config_CC.
     */
    private static Boolean noteSharingRuns() {
        Trigger_Framework_Config_CC__mdt config = Trigger_Framework_Config_CC__mdt.getInstance('ContentDocumentLink');
        return config != null && config.After_Insert_CC__c;
    }

    private static Id createNote(String title) {
        ContentNote note = new ContentNote(Title = title, Content = Blob.valueOf('Meeting notes body'));
        insert note;
        return note.Id;
    }

    private static ContentDocumentLink activityLink(Id documentId, Id activityId) {
        return new ContentDocumentLink(
            ContentDocumentId = documentId,
            LinkedEntityId = activityId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
    }

    private static Set<Id> linkedEntityIds(Id documentId) {
        Set<Id> entityIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :documentId
        ]) {
            entityIds.add(link.LinkedEntityId);
        }
        return entityIds;
    }

    @IsTest
    static void testNoteOnTaskAndEventIsSharedToRelatedRecords() {
        Account account = new Account(Name = 'Note Test Account');
        insert account;

        Contact contact = new Contact(
            FirstName = 'Note',
            LastName = 'Contact',
            Email = 'note.contact@carltontest.invalid',
            Phone = '01234567890',
            AccountId = account.Id
        );
        insert contact;

        Case openCase = [SELECT Id FROM Case WHERE Subject = 'Open Case' LIMIT 1];

        Task task = new Task(
            Subject = 'Call with notes',
            OwnerId = UserInfo.getUserId(),
            WhatId = account.Id,
            WhoId = contact.Id
        );
        insert task;

        Event meeting = new Event(
            Subject = 'Meeting with notes',
            OwnerId = UserInfo.getUserId(),
            WhatId = openCase.Id,
            StartDateTime = System.now().addDays(1),
            EndDateTime = System.now().addDays(1).addHours(1)
        );
        insert meeting;

        Id noteId = createNote('Activity Note');

        List<Database.SaveResult> results = Database.insert(new List<ContentDocumentLink>{
            activityLink(noteId, task.Id),
            activityLink(noteId, meeting.Id)
        }, false);

        for (Database.SaveResult result : results) {
            System.assert(result.isSuccess(), String.valueOf(result.getErrors()));
        }

        Set<Id> linked = linkedEntityIds(noteId);
        if (!noteSharingRuns()) {
            // The after-insert sharing is switched off in this org's trigger configuration: the Note stays on the activities.
            System.assert(!linked.contains(account.Id) && !linked.contains(openCase.Id),
                'Without the after-insert trigger context the Note is not shared to related records');
            return;
        }
        System.assert(linked.contains(account.Id), 'The Note is shared to the Task\'s related record');
        System.assert(linked.contains(contact.Id), 'The Note is shared to the Task\'s contact');
        System.assert(linked.contains(openCase.Id), 'The Note is shared to the Event\'s related record');
    }

    @IsTest
    static void testNoteIsNotSharedToClosedCase() {
        Case closedCase = [SELECT Id FROM Case WHERE Subject = 'Closed Case' LIMIT 1];

        Task task = new Task(
            Subject = 'Follow up on closed case',
            OwnerId = UserInfo.getUserId(),
            WhatId = closedCase.Id
        );
        insert task;

        Id noteId = createNote('Closed Case Note');

        // The Note can still be put on the Task; only the automatic link to the closed Case is refused
        Database.SaveResult result = Database.insert(activityLink(noteId, task.Id), false);

        System.assert(result.isSuccess(), String.valueOf(result.getErrors()));
        Set<Id> linked = linkedEntityIds(noteId);
        System.assert(linked.contains(task.Id), 'The Note stays on the Task');
        System.assert(!linked.contains(closedCase.Id), 'The Note is not added to the closed Case');
    }

    @IsTest
    static void testRegularFileOnTaskIsNotShared() {
        Case openCase = [SELECT Id FROM Case WHERE Subject = 'Open Case' LIMIT 1];

        Task task = new Task(
            Subject = 'Task with a file',
            OwnerId = UserInfo.getUserId(),
            WhatId = openCase.Id
        );
        insert task;

        ContentVersion contentVersion = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Title = 'Test File'
            LIMIT 1
        ];

        Database.SaveResult result = Database.insert(activityLink(contentVersion.ContentDocumentId, task.Id), false);

        System.assert(result.isSuccess(), String.valueOf(result.getErrors()));
        System.assert(!linkedEntityIds(contentVersion.ContentDocumentId).contains(openCase.Id),
            'Only Notes are copied to the activity\'s related records');
    }

    @IsTest
    static void testAfterDeleteRequiresTriggerContext() {
        // The trigger does not subscribe to after delete; outside a trigger there is no Trigger.old to read
        Boolean failed = false;
        try {
            new ContentDocumentLinkTriggerHandler_CC().afterDelete();
        } catch (Exception ex) {
            failed = true;
        }
        System.assert(failed, 'afterDelete needs the deleted links from the trigger context');
    }
}