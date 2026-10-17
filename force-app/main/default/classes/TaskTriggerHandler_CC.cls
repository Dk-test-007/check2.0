/**
 * =============================================================================
 * Class Name    : TaskTriggerHandler_CC
 * Description   : Task trigger handler extending BaseTriggerHandler_CC.
 *                 Handles task assignment and ownership change notifications.
 * =============================================================================
 */
public without sharing class TaskTriggerHandler_CC extends BaseTriggerHandler_CC {

    protected override void afterInsert() {
        sendTaskAssignmentAlerts((List<Task>) Trigger.new);
    }

    protected override void afterUpdate() {
        List<Task> ownershipChangedTasks = new List<Task>();
        Map<Id, Task> oldMap = (Map<Id, Task>) Trigger.oldMap;
        
        for (Task t : (List<Task>) Trigger.new) {
            if (t.OwnerId != oldMap.get(t.Id).OwnerId) {
                ownershipChangedTasks.add(t);
            }
        }
        
        if (!ownershipChangedTasks.isEmpty()) {
            sendOwnershipChangeAlerts(ownershipChangedTasks, oldMap);
        }
    }

    private void sendTaskAssignmentAlerts(List<Task> tasks) {
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        String baseUrl = URL.getOrgDomainUrl().toExternalForm() + '/';
        
        for (Task t : [SELECT Id, Subject, Owner.FirstName, Owner.Email, Priority, ActivityDate, WhatId FROM Task WHERE Id IN :tasks AND Owner.Type = 'User']) {
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ t.Owner.Email });
            email.setSubject('New Task Assigned: ' + t.Subject);
            
            String body = 'Hi ' + t.Owner.FirstName + ',\n\n' +
                'A Task has been assigned to you.\n\n' +
                'Key Details:\n' +
                '• Task: ' + t.Subject + '\n' +
                '• Related Record: ' + (t.WhatId != null ? baseUrl + t.WhatId : 'None') + '\n' +
                '• Priority: ' + (t.Priority != null ? t.Priority : 'Normal') + '\n' +
                '• Due Date: ' + (t.ActivityDate != null ? String.valueOf(t.ActivityDate) : 'N/A') + '\n\n' +
                'Please review the Task in Salesforce and complete it by the due date or update it as appropriate.\n' +
                baseUrl + t.Id + '\n\n' +
                'Thank you,\nCarlton Packaging CRM';
                
            email.setPlainTextBody(body);
            emails.add(email);
        }
        
        if (!emails.isEmpty()) { 
            Messaging.sendEmail(emails, false); 
        }
    }

    private void sendOwnershipChangeAlerts(List<Task> tasks, Map<Id, Task> oldMap) {
        // 1. Gather the Old Owner IDs to query their Names
        Set<Id> oldOwnerIds = new Set<Id>();
        for (Task t : tasks) {
            oldOwnerIds.add(oldMap.get(t.Id).OwnerId);
        }
        
        // 2. Map Old Owner IDs to User Records
        Map<Id, User> oldUsersMap = new Map<Id, User>([SELECT Id, Name FROM User WHERE Id IN :oldOwnerIds]);
        
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        String baseUrl = URL.getOrgDomainUrl().toExternalForm() + '/';
        
        // 3. Query new records along with Owner.Name for the New Owner
        for (Task t : [SELECT Id, Subject, OwnerId, Owner.Name, Owner.FirstName, Owner.Email, ActivityDate, WhatId FROM Task WHERE Id IN :tasks AND Owner.Type = 'User']) {
            Id oldOwnerId = oldMap.get(t.Id).OwnerId;
            
            String previousOwnerName = oldUsersMap.containsKey(oldOwnerId) ? oldUsersMap.get(oldOwnerId).Name : String.valueOf(oldOwnerId);
            String newOwnerName = t.Owner.Name;
            
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ t.Owner.Email });
            email.setSubject('Activity Ownership Changed: ' + t.Subject);
            
            String body = 'Hi ' + t.Owner.FirstName + ',\n\n' +
                'Ownership of a customer activity has changed.\n\n' +
                'Key Details:\n' +
                '• Activity: ' + t.Subject + '\n' +
                '• Related Record: ' + (t.WhatId != null ? baseUrl + t.WhatId : 'None') + '\n' +
                '• Previous Owner: ' + previousOwnerName + '\n' +
                '• New Owner: ' + newOwnerName + '\n' +
                '• Due Date: ' + (t.ActivityDate != null ? String.valueOf(t.ActivityDate) : 'N/A') + '\n\n' +
                'Please review the activity in Salesforce and complete any required handover or continue with the next appropriate action.\n' +
                baseUrl + t.Id + '\n\n' +
                'Thank you,\nCarlton Packaging CRM';
                
            email.setPlainTextBody(body);
            emails.add(email);
        }
        
        if (!emails.isEmpty()) { 
            Messaging.sendEmail(emails, false); 
        }
    }
}