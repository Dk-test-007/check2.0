/**
* =============================================================================
* Class Name    : EventTriggerHandler_CC
* Description   : Event trigger handler. Extends BaseTriggerHandler_CC and
*                 overrides contexts for appointment retention, activity
*                 notifications and Microsoft Teams meeting link creation.
* =============================================================================
*/
public without sharing class EventTriggerHandler_CC extends BaseTriggerHandler_CC {
    
    // API value of the Meeting_Format_CC__c picklist that requires a Teams link
    private static final String MEETING_FORMAT_TEAMS = 'Teams';
    
    public override void beforeInsert() {
        syncCustomSubject((List<Event>) Trigger.new);
    }
    
    public override void beforeDelete() {
        AppointmentArchiveService_CC.archiveDeletedEvents((List<Event>) Trigger.old);
    }
    
    public override void afterInsert() {
        sendMeetingInvitations((List<Event>) Trigger.new);
        updateLeadFirstAppointment((List<Event>) Trigger.new);
        createTeamsMeetings((List<Event>) Trigger.new);
    }
    
    public override void afterUpdate() {
        List<Event> ownershipChangedEvents = new List<Event>();
        Map<Id, Event> oldMap = (Map<Id, Event>) Trigger.oldMap;
        
        for (Event ev : (List<Event>) Trigger.new) {
            if (ev.OwnerId != oldMap.get(ev.Id).OwnerId) {
                ownershipChangedEvents.add(ev);
            }
        }
        
        if (!ownershipChangedEvents.isEmpty()) {
            sendOwnershipChangeAlerts(ownershipChangedEvents, oldMap);
        }
    }
    
    public static void syncCustomSubject(List<Event> newEvents) {
        for (Event evt : newEvents) {
            if (String.isNotBlank(evt.Subject_CC__c)) {
                evt.Subject = evt.Subject_CC__c;
            }
        }
    }
    
    /**
    * Queues creation of a Microsoft Teams meeting link for Events whose
    * Meeting_Format_CC__c is set to 'Teams' and which have a start time,
    * end time and subject. Events with any other meeting format are ignored.
    */
    public static void createTeamsMeetings(List<Event> newEvents) {
        List<Id> teamsEventIds = new List<Id>();
        
        for (Event evt : newEvents) {
            if (evt.Meeting_Format_CC__c == MEETING_FORMAT_TEAMS
                && evt.StartDateTime != null
                && evt.EndDateTime != null
                ) {
                teamsEventIds.add(evt.Id);
            }
        }
        
        if (!teamsEventIds.isEmpty()) {
            System.enqueueJob(new TeamsMeetingQueueable(teamsEventIds));
        }
    }
    
    public static void updateLeadFirstAppointment(List<Event> newEvents) {
        Set<Id> leadIds = new Set<Id>();
        Map<Id, Event> leadIdToEventMap = new Map<Id, Event>();
        
        // 1. Identify which inserted Events are linked to Leads
        for (Event evt : newEvents) {
            // '00Q' is the standard prefix for the Lead object
            if (evt.WhoId != null && String.valueOf(evt.WhoId).startsWith('00Q')) {
                leadIds.add(evt.WhoId);
                // Store the first encountered event for this lead in the current transaction
                if (!leadIdToEventMap.containsKey(evt.WhoId)) {
                    leadIdToEventMap.put(evt.WhoId, evt);
                }
            }
        }
        
        if (leadIds.isEmpty()) return;
        
        // 2. Query Leads that haven't had their first appointment booked yet
        List<Lead> leadsToUpdate = new List<Lead>();
        
        // Updated SOQL to check for 'No' or null picklist values
        for (Lead targetLead : [
            SELECT Id, Sales_Appointment_Booked_CC__c 
            FROM Lead 
            WHERE Id IN :leadIds 
            AND (Sales_Appointment_Booked_CC__c = 'No' OR Sales_Appointment_Booked_CC__c = null)
        ]) {
            Event relatedEvent = leadIdToEventMap.get(targetLead.Id);
            
            // Set the target picklist field to 'Yes'
            targetLead.Sales_Appointment_Booked_CC__c = 'Yes';
            
            // Uses the Event's StartDateTime, or current time if null
            targetLead.First_Sales_Appointment_Date_CC__c = relatedEvent.StartDateTime != null ? relatedEvent.StartDateTime : System.now();
            
            leadsToUpdate.add(targetLead);
        }
        
        // 3. Update the Lead records
        if (!leadsToUpdate.isEmpty()) {
            update leadsToUpdate;
        }
    }
    
    private void sendMeetingInvitations(List<Event> events) {
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        String baseUrl = URL.getOrgDomainUrl().toExternalForm() + '/';
        
        for (Event ev : [SELECT Id, Subject, Owner.Name, Owner.FirstName, Owner.Email, StartDateTime, Location, WhatId FROM Event WHERE Id IN :events AND Owner.Type = 'User']) {
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ ev.Owner.Email });
            email.setSubject('Meeting Scheduled: ' + ev.Subject);
            
            String body = 'Hi ' + ev.Owner.FirstName + ',\n\n' +
                'A customer meeting has been scheduled or updated.\n\n' +
                'Key Details:\n' +
                '• Meeting: ' + ev.Subject + '\n' +
                '• Related Record: ' + (ev.WhatId != null ? baseUrl + ev.WhatId : 'None') + '\n' +
                '• Date & Time: ' + ev.StartDateTime + '\n' +
                '• Organiser: ' + ev.Owner.Name + '\n' +
                '• Location / Meeting Link: ' + (ev.Location != null ? ev.Location : 'N/A') + '\n\n' +
                'Please review the meeting details and attend as scheduled.\n\n' +
                baseUrl + ev.Id + '\n\n' +
                'Thank you,\nCarlton Packaging CRM';
            
            email.setPlainTextBody(body);
            emails.add(email);
        }
        
        if (!emails.isEmpty()) { 
            Messaging.sendEmail(emails, false); 
        }
    }
    
    private void sendOwnershipChangeAlerts(List<Event> events, Map<Id, Event> oldMap) {
        // 1. Gather the Old Owner IDs to query their Names
        Set<Id> oldOwnerIds = new Set<Id>();
        for (Event ev : events) {
            oldOwnerIds.add(oldMap.get(ev.Id).OwnerId);
        }
        
        // 2. Map Old Owner IDs to User Records
        Map<Id, User> oldUsersMap = new Map<Id, User>([SELECT Id, Name FROM User WHERE Id IN :oldOwnerIds]);
        
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        String baseUrl = URL.getOrgDomainUrl().toExternalForm() + '/';
        
        // 3. Query new records along with Owner.Name for the New Owner
        for (Event ev : [SELECT Id, Subject, OwnerId, Owner.Name, Owner.FirstName, Owner.Email, ActivityDate, WhatId FROM Event WHERE Id IN :events AND Owner.Type = 'User']) {
            Id oldOwnerId = oldMap.get(ev.Id).OwnerId;
            
            String previousOwnerName = oldUsersMap.containsKey(oldOwnerId) ? oldUsersMap.get(oldOwnerId).Name : String.valueOf(oldOwnerId);
            String newOwnerName = ev.Owner.Name;
            
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ ev.Owner.Email });
            email.setSubject('Activity Ownership Changed: ' + ev.Subject);
            
            String body = 'Hi ' + ev.Owner.FirstName + ',\n\n' +
                'Ownership of a customer activity has changed.\n\n' +
                'Key Details:\n' +
                '• Activity: ' + ev.Subject + '\n' +
                '• Related Record: ' + (ev.WhatId != null ? baseUrl + ev.WhatId : 'None') + '\n' +
                '• Previous Owner: ' + previousOwnerName + '\n' +
                '• New Owner: ' + newOwnerName + '\n' +
                '• Due Date: ' + (ev.ActivityDate != null ? String.valueOf(ev.ActivityDate) : 'N/A') + '\n\n' +
                'Please review the activity in Salesforce and complete any required handover or continue with the next appropriate action.\n' +
                baseUrl + ev.Id + '\n\n' +
                'Thank you,\nCarlton Packaging CRM';
            
            email.setPlainTextBody(body);
            emails.add(email);
        }
        
        if (!emails.isEmpty()) { 
            Messaging.sendEmail(emails, false); 
        }
    }
}