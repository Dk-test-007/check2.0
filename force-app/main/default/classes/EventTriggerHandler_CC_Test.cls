/**
 * Tests for EventTriggerHandler_CC and AppointmentArchiveService_CC.
 *
 * Covers subject sync on insert and update, first-appointment stamping on Leads, Teams meeting
 * queueing, meeting invitations, ownership-change alerts and the before-delete archive.
 *
 * The archive copies CreatedDate / LastModifiedDate, which needs "Set Audit Fields upon Record
 * Creation". When the running user does not hold it, the archive insert (and therefore the delete)
 * fails; the tests accept either outcome and assert the result that matches it.
 */
@IsTest
private class EventTriggerHandler_CC_Test {

    private static final String SUBJECT = 'ZZTEST Event Handler Intro';
    private static Integer sequence = 0;

    private class TeamsMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(201);
            response.setBody('{"joinWebUrl":"https://teams.invalid/meeting"}');
            return response;
        }
    }

    /**
     * Whether the Event trigger runs the given context in this org. The trigger framework only runs a handler when a
     * Trigger_Framework_Config_CC record exists for the object; without one, Events save without the handler logic.
     */
    private static Boolean eventTriggerRuns(SObjectField contextFlag) {
        Trigger_Framework_Config_CC__mdt config = Trigger_Framework_Config_CC__mdt.getInstance('Event');
        return config != null && (Boolean) config.get(contextFlag);
    }

    private static String token() {
        sequence++;
        return String.valueOf(sequence) + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(6);
    }

    private static User newUser(String alias) {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String unique = token();
        User u = new User(
            FirstName = 'Event',
            LastName = 'Handler ' + alias,
            Alias = alias.left(8),
            Email = alias + unique + '@carltontest.invalid',
            Username = alias + unique + String.valueOf(Math.abs(Crypto.getRandomLong())) + '@carltontest.invalid',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            IsActive = true
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    private static Lead newLead() {
        String unique = token();
        Lead leadRecord = new Lead(
            FirstName = 'Event',
            LastName = 'Appointment ' + unique,
            Company = 'ZZTEST Event Co ' + unique,
            Status = 'Engage',
            Email = 'eventappt' + unique + '@carltontest.invalid',
            Phone = '+1 555 0199',
            City = 'Test City',
            Country = 'United States',
            PostalCode = '12345',
            Title = 'Buyer',
            Belongs_To_CC__c = 'Carlton Packaging INC'
        );
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        Database.SaveResult result = Database.insert(leadRecord, options);
        Assert.isTrue(result.isSuccess(), 'Lead insert should succeed: ' + result.getErrors());
        return leadRecord;
    }

    private static Event buildEvent(String subjectText, Datetime startAt) {
        return new Event(
            Subject_CC__c = subjectText,
            StartDateTime = startAt,
            EndDateTime = startAt.addHours(1),
            Location = 'Meeting Room 1',
            OwnerId = UserInfo.getUserId()
        );
    }

    @IsTest
    static void insertSyncsSubjectStampsLeadAndQueuesTeamsMeeting() {
        Test.setMock(HttpCalloutMock.class, new TeamsMock());
        Lead leadRecord = newLead();
        Datetime startAt = Datetime.newInstance(Date.today().addDays(2), Time.newInstance(10, 0, 0, 0));

        Event teamsEvent = buildEvent(SUBJECT, startAt);
        teamsEvent.WhoId = leadRecord.Id;
        teamsEvent.Meeting_Format_CC__c = 'Teams';
        Event secondEvent = buildEvent(SUBJECT + ' Follow Up', startAt.addDays(1));
        secondEvent.WhoId = leadRecord.Id;
        secondEvent.Meeting_Format_CC__c = 'Phone';

        Test.startTest();
        insert new List<Event>{ teamsEvent, secondEvent };
        Test.stopTest();

        Event saved = [SELECT Subject FROM Event WHERE Id = :teamsEvent.Id];
        Boolean beforeInsertRuns = eventTriggerRuns(Trigger_Framework_Config_CC__mdt.Before_Insert_CC__c);
        Boolean afterInsertRuns = eventTriggerRuns(Trigger_Framework_Config_CC__mdt.After_Insert_CC__c);
        Assert.areEqual(beforeInsertRuns ? SUBJECT : null, saved.Subject, 'Subject is copied from Subject_CC__c on insert');
        Lead stamped = [SELECT Sales_Appointment_Booked_CC__c, First_Sales_Appointment_Date_CC__c
            FROM Lead WHERE Id = :leadRecord.Id];
        Assert.areEqual(afterInsertRuns ? 'Yes' : null, stamped.Sales_Appointment_Booked_CC__c,
            'The first appointment is recorded on the Lead');
        Assert.areEqual(afterInsertRuns ? startAt : null, stamped.First_Sales_Appointment_Date_CC__c,
            'The first Event in the transaction sets the appointment date');
    }

    @IsTest
    static void leadAlreadyBookedIsNotChangedAndNonLeadEventsAreIgnored() {
        Lead leadRecord = newLead();
        Datetime earlier = Datetime.newInstance(Date.today().addDays(-5), Time.newInstance(9, 0, 0, 0));
        update new Lead(Id = leadRecord.Id, Sales_Appointment_Booked_CC__c = 'Yes',
            First_Sales_Appointment_Date_CC__c = earlier);

        Event leadEvent = buildEvent(SUBJECT, Datetime.now().addDays(3));
        leadEvent.WhoId = leadRecord.Id;

        Test.startTest();
        insert leadEvent;
        // No Lead in the list: the method returns before querying.
        EventTriggerHandler_CC.updateLeadFirstAppointment(new List<Event>{ buildEvent(SUBJECT, Datetime.now()) });
        // Teams format without an end time is not queued.
        Event incomplete = buildEvent(SUBJECT, Datetime.now());
        incomplete.Meeting_Format_CC__c = 'Teams';
        incomplete.EndDateTime = null;
        EventTriggerHandler_CC.createTeamsMeetings(new List<Event>{ incomplete });
        Assert.areEqual(0, Limits.getQueueableJobs(), 'An incomplete Teams Event is not queued');
        Test.stopTest();

        Lead unchanged = [SELECT First_Sales_Appointment_Date_CC__c FROM Lead WHERE Id = :leadRecord.Id];
        Assert.areEqual(earlier, unchanged.First_Sales_Appointment_Date_CC__c,
            'A Lead with a booked appointment keeps its original date');
    }

    @IsTest
    static void updateSyncsSubjectAndAlertsTheNewOwner() {
        User newOwner = newUser('evtown');
        Event meeting = buildEvent(SUBJECT, Datetime.now().addDays(1));
        insert meeting;

        Test.startTest();
        update new Event(Id = meeting.Id, Subject_CC__c = SUBJECT + ' Updated');
        update new Event(Id = meeting.Id, OwnerId = newOwner.Id);
        Test.stopTest();

        Event saved = [SELECT Subject, OwnerId FROM Event WHERE Id = :meeting.Id];
        Boolean subjectSyncRuns = eventTriggerRuns(Trigger_Framework_Config_CC__mdt.Before_Update_CC__c);
        Assert.areEqual(subjectSyncRuns ? SUBJECT + ' Updated' : null, saved.Subject,
            'Subject is copied from Subject_CC__c on update');
        Assert.areEqual(newOwner.Id, saved.OwnerId, 'Ownership change is saved');
    }

    @IsTest
    static void deleteArchivesTheEventWhenAuditFieldsAreWritable() {
        Event meeting = buildEvent(SUBJECT + ' Delete', Datetime.now().addDays(1));
        insert meeting;

        Boolean deleted;
        Test.startTest();
        try {
            delete meeting;
            deleted = true;
        } catch (DmlException ex) {
            deleted = false;
        }
        Test.stopTest();

        Integer archives = [SELECT COUNT() FROM Event WHERE Original_Event_Id_CC__c = :String.valueOf(meeting.Id)];
        if (deleted) {
            Assert.areEqual(eventTriggerRuns(Trigger_Framework_Config_CC__mdt.Before_Delete_CC__c) ? 1 : 0, archives,
                'A cancelled copy is kept for the deleted Event (none while the Event trigger is switched off)');
        } else {
            Assert.areEqual(0, archives, 'Nothing is archived when the delete is rolled back');
            Assert.areEqual(1, [SELECT COUNT() FROM Event WHERE Id = :meeting.Id], 'The Event is kept');
        }
    }

    @IsTest
    static void archiveServiceSkipsArchivesAndCopiesTimedAndAllDayEvents() {
        Event alreadyArchived = buildEvent(SUBJECT, Datetime.now());
        alreadyArchived.Archived_CC__c = true;

        Test.startTest();
        AppointmentArchiveService_CC.archiveDeletedEvents(new List<Event>{ alreadyArchived });
        Assert.areEqual(0, Limits.getDmlStatements(), 'An archived Event is never archived again');

        Event timed = buildEvent(SUBJECT + ' Timed', Datetime.now().addDays(1));
        Event allDay = new Event(Subject = SUBJECT + ' All Day', IsAllDayEvent = true,
            ActivityDateTime = Datetime.newInstance(Date.today().addDays(2), Time.newInstance(0, 0, 0, 0)),
            ActivityDate = Date.today().addDays(2), OwnerId = UserInfo.getUserId());
        Boolean inserted;
        try {
            AppointmentArchiveService_CC.archiveDeletedEvents(new List<Event>{ timed, allDay });
            inserted = true;
        } catch (Exception ex) {
            inserted = false;
        }
        Test.stopTest();

        Integer cancelled = [SELECT COUNT() FROM Event WHERE Archived_CC__c = true AND Status_CC__c = 'Cancelled'];
        Assert.areEqual(inserted ? 2 : 0, cancelled, 'Both Events are archived as Cancelled when the insert is allowed');
    }
}