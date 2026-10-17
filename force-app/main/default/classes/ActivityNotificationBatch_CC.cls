public class ActivityNotificationBatch_CC implements Database.Batchable<sObject>, Schedulable {
    private String objectType; 
    
    // Default constructor required for the Salesforce UI 'Schedule Apex' page
    public ActivityNotificationBatch_CC() {
        this.objectType = 'Event'; // Defaults to Event if scheduled via UI
    }
    
    public ActivityNotificationBatch_CC(String objType) {
        this.objectType = objType;
    }

    // --- Schedulable Interface ---
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ActivityNotificationBatch_CC(this.objectType), 200);
    }

    // --- Batchable Interface ---
    public Database.QueryLocator start(Database.BatchableContext bc) {
        DateTime now = System.now();
        String query = '';
        
        if (objectType == 'Event') {
            String nowStr = now.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            String nextHourStr = now.addHours(1).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            String lastHourStr = now.addHours(-1).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            
            query = 'SELECT Id, Subject, OwnerId, Owner.FirstName, Owner.Email, StartDateTime, EndDateTime, ActivityDate, WhatId ' + 
                    'FROM Event ' +
                    'WHERE Owner.Type = \'User\' AND ' +
                    '((StartDateTime >= ' + nowStr + ' AND StartDateTime <= ' + nextHourStr + ') OR ' + 
                    '(EndDateTime <= ' + nowStr + ' AND EndDateTime >= ' + lastHourStr + '))';          
                    
        } else if (objectType == 'Task') {
            String todayStr = String.valueOf(Date.today());
            query = 'SELECT Id, Subject, OwnerId, Owner.FirstName, Owner.Email, ActivityDate, Priority, WhatId ' + 
                    'FROM Task ' +
                    'WHERE IsClosed = false AND Owner.Type = \'User\' AND ' +
                    '(ActivityDate = ' + todayStr + ' OR ActivityDate < ' + todayStr + ')';
        }
        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<sObject> scope) {
        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
        String baseUrl = URL.getOrgDomainUrl().toExternalForm() + '/';
        DateTime now = System.now();

        for (sObject record : scope) {
            String subject = (String) record.get('Subject');
            String ownerFirstName = (String) record.getSObject('Owner').get('FirstName');
            String ownerEmail = (String) record.getSObject('Owner').get('Email');
            String relatedRecordId = (String) record.get('WhatId');
            
            Boolean isOverdue = false;
            String dueDateStr = 'N/A';
            Integer daysOverdue = 0;
            String priority = 'Normal'; 
            
            if (objectType == 'Event') {
                Datetime endDt = (Datetime) record.get('EndDateTime');
                Datetime startDt = (Datetime) record.get('StartDateTime');
                if (endDt != null && endDt < now) {
                    isOverdue = true;
                    dueDateStr = String.valueOf(endDt);
                    daysOverdue = Date.valueOf(endDt).daysBetween(Date.today());
                } else {
                    dueDateStr = String.valueOf(startDt);
                }
            } else if (objectType == 'Task') {
                Date actDate = (Date) record.get('ActivityDate');
                priority = (String) record.get('Priority');
                if (actDate != null) {
                    dueDateStr = String.valueOf(actDate);
                    if (actDate < Date.today()) {
                        isOverdue = true;
                        daysOverdue = actDate.daysBetween(Date.today());
                    }
                }
            }

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ ownerEmail });
            
            if (isOverdue) {
                email.setSubject('Overdue Activity: ' + subject);
                email.setPlainTextBody(
                    'Hi ' + ownerFirstName + ',\n\n' +
                    'One of your customer activities is now overdue.\n\n' +
                    'Key Details:\n' +
                    '• Activity: ' + subject + '\n' +
                    '• Activity Type: ' + objectType + '\n' +
                    '• Related Record: ' + (relatedRecordId != null ? baseUrl + relatedRecordId : 'None') + '\n' +
                    '• Original Due Date: ' + dueDateStr + '\n' +
                    '• Days Overdue: ' + daysOverdue + '\n\n' +
                    'Please review the activity in Salesforce and either complete it or update it with the latest progress.\n' +
                    baseUrl + record.get('Id') + '\n\n' +
                    'Thank you,\nCarlton Packaging CRM'
                );
            } else {
                email.setSubject('Reminder: ' + subject + ' Due on ' + dueDateStr);
                email.setPlainTextBody(
                    'Hi ' + ownerFirstName + ',\n\n' +
                    'This is a reminder that one of your scheduled customer activities is approaching its due date.\n\n' +
                    'Key Details:\n' +
                    '• Activity: ' + subject + '\n' +
                    '• Activity Type: ' + objectType + '\n' +
                    '• Related Record: ' + (relatedRecordId != null ? baseUrl + relatedRecordId : 'None') + '\n' +
                    '• Due Date: ' + dueDateStr + '\n' +
                    '• Priority: ' + priority + '\n\n' +
                    'Please review the activity in Salesforce and complete it as planned or update it if changes are required.\n' +
                    baseUrl + record.get('Id') + '\n\n' +
                    'Thank you,\nCarlton Packaging CRM'
                );
            }
            emailsToSend.add(email);
        }

        if (!emailsToSend.isEmpty()) {
            Messaging.sendEmail(emailsToSend, false);
        }
    }

    public void finish(Database.BatchableContext bc) {}
}