public without sharing class OpportunityStageReminderService_CC {
    public static void sendReminders(List<Opportunity> opportunities) {
        if (opportunities == null || opportunities.isEmpty()) return;
        Integer thresholdDays;
        try {
            thresholdDays = Integer.valueOf(System.Label.Opportunity_Stage_Reminder_Days_CC);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Invalid Opportunity_Stage_Reminder_Days custom label: ' + e.getMessage());
            return;
        }
        List<Opportunity> eligible = new List<Opportunity>();
        Set<Id> ownerIds = new Set<Id>();
        Date today = Date.today();
        for (Opportunity opp : opportunities) {
            if (opp.OwnerId == null) continue;
            Date stageStartDate = getStageStartDate(opp);
            if (stageStartDate > today) continue;
            Integer daysInStage = stageStartDate.daysBetween(today);
            if (daysInStage < thresholdDays) continue;
            if (opp.Stage_Reminder_Sent_Date_CC__c != null && opp.Stage_Reminder_Sent_Date_CC__c >= stageStartDate) continue;
            eligible.add(opp);
            ownerIds.add(opp.OwnerId);
        }
        if (eligible.isEmpty()) return;
        Map<Id, User> owners = new Map<Id, User>([
            SELECT Id, FirstName, Email, IsActive
            FROM User
            WHERE Id IN :ownerIds
            WITH SYSTEM_MODE
        ]);
        Id templateId = getActiveTemplateId('Opportunity_Stage_Reminder_CC');
        if (templateId != null) {
            List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
            for (Opportunity opp : eligible) {
                User owner = owners.get(opp.OwnerId);
                if (owner == null || String.isBlank(owner.Email)) {
                    System.debug(LoggingLevel.WARN, 'Skipping email for ' + opp.Id + ' - owner has no usable email address.');
                    continue;
                }
                Messaging.SingleEmailMessage msg = Messaging.renderStoredEmailTemplate(templateId, null, opp.Id);
                msg.setToAddresses(new List<String>{ owner.Email });
                msg.setSaveAsActivity(false);
                messages.add(msg);
            }
            sendInBatches(messages);
        } else {
            System.debug(LoggingLevel.ERROR, 'Email template Opportunity_Stage_Reminder_CC not found or inactive.');
        }
        sendStageReminderNotifications(eligible, owners);
        List<Opportunity> opportunitiesToUpdate = new List<Opportunity>();
        for (Opportunity opp : eligible) {
            opportunitiesToUpdate.add(new Opportunity(Id = opp.Id, Stage_Reminder_Sent_Date_CC__c = today));
        }
        if (!opportunitiesToUpdate.isEmpty()) update opportunitiesToUpdate;
    }
    private static Date getStageStartDate(Opportunity opp) {
        if (opp.BAU_Opportunity_CC__c == true && String.isNotBlank(opp.BAU_Month_CC__c)) {
            Integer bauMonth = getMonthNumber(opp.BAU_Month_CC__c);
            if (bauMonth != null) return Date.newInstance(Date.today().year(), bauMonth, 1);
        }
        return opp.LastStageChangeDate != null ? opp.LastStageChangeDate.date() : opp.CreatedDate.date();
    }
    private static Integer getMonthNumber(String monthName) {
        List<String> monthNames = new List<String>{
            'January', 'February', 'March', 'April', 'May', 'June',
            'July', 'August', 'September', 'October', 'November', 'December'
        };
        for (Integer i = 0; i < monthNames.size(); i++) {
            if (monthNames[i].equalsIgnoreCase(monthName.trim())) return i + 1;
        }
        return null;
    }
    private static void sendStageReminderNotifications(List<Opportunity> eligible, Map<Id, User> owners) {
        List<CustomNotificationType> notificationTypes = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = 'Opportunity_Stage_Reminder'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (notificationTypes.isEmpty()) return;
        Id notificationTypeId = notificationTypes[0].Id;
        for (Opportunity opp : eligible) {
            User owner = owners.get(opp.OwnerId);
            if (owner == null) continue;
            Date stageStartDate = getStageStartDate(opp);
            Integer daysInStage = stageStartDate.daysBetween(Date.today());
            String firstName = String.isNotBlank(owner.FirstName) ? owner.FirstName : 'there';
            String amount = opp.Amount == null ? '' : String.valueOf(opp.Amount);
            String body = 'Hi ' + firstName + ',\n\n' + 'An Opportunity assigned to you has remained in the same sales stage longer than the agreed business threshold.\n\n' + 'Key Details:\n' + '- Opportunity: ' + opp.Name + '\n' + '- Customer: ' + (opp.Account != null ? opp.Account.Name : '') + '\n' + '- Current Stage: ' + opp.StageName + '\n' + '- Days in Current Stage: ' + daysInStage + '\n' + '- Opportunity Value: ' + amount + '\n\n' + 'Please review the Opportunity in Salesforce and either progress it to the next stage or update it with the current status.';
            if (body.length() > 750) body = body.substring(0, 747) + '...';
            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(notificationTypeId);
            notification.setTargetId(opp.Id);
            notification.setTitle('Action Required: Opportunity Awaiting Progress - ' + opp.Name);
            notification.setBody(body);
            try {
                notification.send(new Set<String>{ String.valueOf(opp.OwnerId) });
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Custom notification failed for ' + opp.Id + ': ' + e.getMessage());
            }
        }
    }
    private static Id getActiveTemplateId(String developerName) {
        List<EmailTemplate> templates = [
            SELECT Id
            FROM EmailTemplate
            WHERE DeveloperName = :developerName
            AND IsActive = true
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return templates.isEmpty() ? null : templates[0].Id;
    }
    private static void sendInBatches(List<Messaging.SingleEmailMessage> messages) {
        if (messages == null || messages.isEmpty()) return;
        for (Integer i = 0; i < messages.size(); i += 100) {
            Integer endIdx = Math.min(i + 100, messages.size());
            List<Messaging.SingleEmailMessage> batch = new List<Messaging.SingleEmailMessage>();
            for (Integer j = i; j < endIdx; j++) batch.add(messages[j]);
            List<Messaging.SendEmailResult> results = Messaging.sendEmail(batch, false);
            logEmailFailures(results);
        }
    }
    private static void logEmailFailures(List<Messaging.SendEmailResult> results) {
        for (Messaging.SendEmailResult result : results) {
            if (result.isSuccess()) continue;
            for (Messaging.SendEmailError error : result.getErrors()) {
                System.debug(LoggingLevel.ERROR, 'Email send failed [' + error.getStatusCode() + ']: ' + error.getMessage() + ' | Fields: ' + error.getFields());
            }
        }
    }
}