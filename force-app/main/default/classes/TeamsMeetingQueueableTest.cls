@IsTest
private class TeamsMeetingQueueableTest {

    private static final String TEST_ENTRA_ID = 'a10fb4c4-e51a-452e-91c2-74a9abb4bc65';
    private static final String TEST_MEETING_URL = 'https://teams.microsoft.com/l/meetup-join/test';

    private class TeamsMeetingMock implements HttpCalloutMock {

        public HttpResponse respond(HttpRequest req) {
            System.assertEquals('POST',req.getMethod(),'HTTP method should be POST');
            System.assert(
                req.getEndpoint().contains('/v1.0/users/' + TEST_ENTRA_ID +'/onlineMeetings'),
                'Endpoint should contain the creator Entra Object ID'
            );
            System.assertEquals('application/json',req.getHeader('Content-Type'));

            Map<String, Object> body = (Map<String, Object>)JSON.deserializeUntyped(req.getBody());
            System.assertEquals('Salesforce Meeting',(String) body.get('subject'));
            System.assertNotEquals(null,body.get('startDateTime'));
            System.assertNotEquals(null,body.get('endDateTime'));

            HttpResponse response = new HttpResponse();
            response.setStatusCode(201);
            response.setHeader('Content-Type','application/json');
            response.setBody(JSON.serialize(
                    new Map<String, Object>{
                        'id' => 'meeting123',
                        'subject' => 'Salesforce Meeting',
                        'startDateTime' => body.get('startDateTime'),
                        'endDateTime' => body.get('endDateTime'),
                        'joinWebUrl' => TEST_MEETING_URL
                    }
                )
            );
            return response;
        }
    }

    @IsTest
    static void testTeamsMeetingCreation() {

        User currentUser = [
            SELECT Id, Entra_User_Object_ID__c FROM User WHERE Id = :UserInfo.getUserId() WITH SYSTEM_MODE
        ];

        currentUser.Entra_User_Object_ID__c = TEST_ENTRA_ID;
        Database.update(currentUser, AccessLevel.SYSTEM_MODE);

        Test.setMock(
            HttpCalloutMock.class,
            new TeamsMeetingMock()
        );

        // Subject_CC__c is the custom subject the Event trigger copies into Subject; set both so the
        // standard Subject survives whichever version of the trigger is active in the org.
        Event evt = new Event(
            Subject = 'Salesforce Meeting',
            Subject_CC__c = 'Salesforce Meeting',
            StartDateTime = System.now().addDays(1),
            EndDateTime = System.now().addDays(1).addHours(1)
        );

        Test.startTest();
        System.runAs(currentUser) {
            insert evt;
            System.enqueueJob(new TeamsMeetingQueueable(new List<Id>{ evt.Id }));
        }
        Test.stopTest();

        Event savedEvent = [
            SELECT Id, Description FROM Event WHERE Id = :evt.Id
        ];

        System.assertNotEquals(
            null,
            savedEvent.Description,
            'Event Description should not be empty'
        );

        System.assert(
            savedEvent.Description.contains(TEST_MEETING_URL),
            'Teams meeting URL should be saved in Description'
        );
    }

    @IsTest
    static void testMissingEntraObjectId() {

        User currentUser = [
            SELECT Id, Entra_User_Object_ID__c FROM User WHERE Id = :UserInfo.getUserId() WITH SYSTEM_MODE
        ];

        currentUser.Entra_User_Object_ID__c = null;
        Database.update(currentUser, AccessLevel.SYSTEM_MODE);

        Event evt = new Event(
            Subject = 'Meeting Without Entra Mapping',
            StartDateTime = System.now().addDays(1),
            EndDateTime = System.now().addDays(1).addHours(1)
        );

        Test.startTest();
        System.runAs(currentUser) {
            insert evt;
        }
        Test.stopTest();

        Event savedEvent = [
            SELECT Id, Description FROM Event WHERE Id = :evt.Id
        ];

        System.assertEquals(
            null,
            savedEvent.Description,
            'No meeting URL should be saved when Entra mapping is missing'
        );
    }
}