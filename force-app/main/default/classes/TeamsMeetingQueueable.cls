public class TeamsMeetingQueueable implements Queueable, Database.AllowsCallouts {

    private List<Id> eventIds;
    private static final String NAMED_CREDENTIAL = 'MS_Teams';
    private static final Integer BATCH_SIZE = 10;

    public TeamsMeetingQueueable(List<Id> eventIds) {
        this.eventIds = eventIds;
    }

    public void execute(QueueableContext context) {
        if (eventIds == null || eventIds.isEmpty()) {
            return;
        }

        // Process a maximum of 10 Events per transaction.
        List<Id> currentBatch = new List<Id>();
        for (Integer i = 0; i < eventIds.size() && i < BATCH_SIZE; i++) {
            currentBatch.add(eventIds[i]);
        }

        List<Event> eventRecords = [
            SELECT Id, Subject, StartDateTime, EndDateTime,CreatedById, Description FROM Event WHERE Id IN :currentBatch
        ];

        // Collect Event creator IDs.
        Set<Id> creatorIds = new Set<Id>();
        for (Event evt : eventRecords) {
            creatorIds.add(evt.CreatedById);
        }

        // Retrieve Entra Object IDs from Salesforce User records.
        Map<Id, User> userMap = new Map<Id, User>([
            SELECT Id, Name, Entra_User_Object_ID__c FROM User WHERE Id IN :creatorIds WITH SYSTEM_MODE
        ]);

        Http http = new Http();
        List<Event> eventsToUpdate = new List<Event>();
        for (Event evt : eventRecords) {
            User creator = userMap.get(evt.CreatedById);
            if (creator == null || String.isBlank(creator.Entra_User_Object_ID__c)) {
                System.debug(LoggingLevel.ERROR, 'Entra Object ID missing for Event: ' + evt.Id);
                continue;
            }

            try {
                String entraUserId = EncodingUtil.urlEncode(creator.Entra_User_Object_ID__c, 'UTF-8');
                
                // Dynamic Microsoft Graph endpoint.
                String endpoint ='callout:' + NAMED_CREDENTIAL +'/v1.0/users/' + entraUserId +'/onlineMeetings';

                // Prepare request body.
                Map<String, Object> requestBody = new Map<String, Object>();
                requestBody.put('subject', evt.Subject);
                requestBody.put('startDateTime',evt.StartDateTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
                requestBody.put('endDateTime',evt.EndDateTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
                HttpRequest req = new HttpRequest();

                req.setEndpoint(endpoint);
                req.setMethod('POST');
                req.setHeader('Content-Type','application/json');
                req.setHeader('Accept','application/json');
                req.setTimeout(10000);
                req.setBody(JSON.serialize(requestBody));

                // Execute Microsoft Graph API callout.
                HttpResponse res = http.send(req);

                System.debug(
                    'Event ID: ' + evt.Id +', Creator: ' + creator.Name +', Status: ' + res.getStatusCode()
                );
                if (res.getStatusCode() == 201 || res.getStatusCode() == 200) {
                    
                    Map<String, Object> responseData = (Map<String, Object>)JSON.deserializeUntyped(res.getBody());
		 			
                    String meetingUrl = (String) responseData.get('joinWebUrl');

                    if (String.isNotBlank(meetingUrl)) {
                        String existingDescription = evt.Description == null ? '' : evt.Description;

                        // Avoid appending duplicate meeting URLs.
                        String updatedDescription = existingDescription;

                        if (!existingDescription.contains(meetingUrl)) {
                            updatedDescription = String.isBlank(existingDescription) ? 'Teams Meeting: ' + meetingUrl : existingDescription + '\nTeams Meeting: ' + meetingUrl;
                        }

                        if (updatedDescription.length() > 32000) {
                            System.debug(LoggingLevel.ERROR, 'Description limit exceeded for Event: ' + evt.Id);
                            continue;
                        }

                        eventsToUpdate.add(new Event(
                                Id = evt.Id,
                                Description = updatedDescription
                            )
                        );

                    } else {
                        System.debug(LoggingLevel.ERROR,'joinWebUrl missing in Graph response for Event: ' + evt.Id);
                    }

                } else {
                    System.debug(LoggingLevel.ERROR, 'Graph API failed for Event ' + evt.Id + '. HTTP Status: ' + res.getStatusCode() + '. Response: ' + res.getBody());
                }
            } 
            catch (Exception ex) {
                System.debug(LoggingLevel.ERROR,'Exception for Event ' + evt.Id + ': ' + ex.getMessage() + ', Line: ' + ex.getLineNumber());
            }
        }

        // Update Events only after all HTTP callouts.
        if (!eventsToUpdate.isEmpty()) {
            Database.SaveResult[] results = Database.update(eventsToUpdate, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    for (Database.Error err : results[i].getErrors()) {
                        System.debug(LoggingLevel.ERROR, 'Event update failed: ' + eventsToUpdate[i].Id + '. Error: ' + err.getMessage());
                    }
                }
            }
        }

        // Process remaining Events in another Queueable transaction.
        if (eventIds.size() > BATCH_SIZE) {
            List<Id> remainingIds = new List<Id>();
            for (Integer i = BATCH_SIZE; i < eventIds.size(); i++) {
                remainingIds.add(eventIds[i]);
            }
            System.enqueueJob(new TeamsMeetingQueueable(remainingIds));
        }
    }
}