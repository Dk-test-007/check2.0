/**
 * =============================================================================
 * Class Name    : EventTriggerHandler_CC
 * Description   : Event trigger handler. Extends BaseTriggerHandler_CC and
 *                 overrides contexts for appointment retention and activity 
 *                 notifications.
 * =============================================================================
 */
public without sharing class EventTriggerHandler_CC extends BaseTriggerHandler_CC {

    protected override void beforeDelete() {
        AppointmentArchiveService_CC.archiveDeletedEvents((List<Event>) Trigger.old);
    }

    protected override void afterInsert() {
        sendMeetingInvitations((List<Event>) Trigger.new);
    }

    protected override void afterUpdate() {
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