global class QuoteExpirationNotificationBatch implements Schedulable, Database.Batchable<SObject> {

    global static final String EXPIRATION_REMINDER_TEMPLATE = 'Quote_Expiration_Reminder';
    global static final String EXPIRED_TEMPLATE = 'Quote_Expired';
    global static final String CUSTOM_NOTIFICATION_TYPE = 'Quote_Expiration_Notification';

    global Id expirationReminderTemplateId;
    global Id expiredTemplateId;
    global Id notificationTypeId;

    global QuoteExpirationNotificationBatch() {
        Map<String, Id> templateIdsByDeveloperName = new Map<String, Id>();

        for (EmailTemplate template : [SELECT Id, DeveloperName FROM EmailTemplate WHERE DeveloperName IN :new Set<String>{ EXPIRATION_REMINDER_TEMPLATE, EXPIRED_TEMPLATE }]) {
            templateIdsByDeveloperName.put(template.DeveloperName, template.Id);
        }

        expirationReminderTemplateId = templateIdsByDeveloperName.get(EXPIRATION_REMINDER_TEMPLATE);
        expiredTemplateId = templateIdsByDeveloperName.get(EXPIRED_TEMPLATE);
        notificationTypeId = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = :CUSTOM_NOTIFICATION_TYPE LIMIT 1].Id;
    }

    global void execute(SchedulableContext sc) {
        Database.executeBatch(new QuoteExpirationNotificationBatch(), 200);
    }

    global Database.QueryLocator start(Database.BatchableContext bc) {
        Date reminderDate = Date.today().addDays(7);
        Date expiredDate = Date.today().addDays(-1);

        return Database.getQueryLocator([SELECT Id, QuoteNumber, Account.Name, OwnerId, Owner.Email, ExpirationDate FROM Quote WHERE Status NOT IN ('Accepted', 'Rejected', 'Cancelled', 'Expired') AND (ExpirationDate = :reminderDate OR ExpirationDate = :expiredDate)]);
    }

    global void execute(Database.BatchableContext bc, List<Quote> quotes) {
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        List<Quote> expiredQuotes = new List<Quote>();

        Date reminderDate = Date.today().addDays(7);
        Date expiredDate = Date.today().addDays(-1);

        for (Quote quote : quotes) {
            Id templateId;
            String notificationTitle;
            String notificationBody;

            if (quote.ExpirationDate == reminderDate) {
                templateId = expirationReminderTemplateId;
                notificationTitle = 'Quote Expiring Soon';
                notificationBody = 'Quote Expiring Soon: ' + quote.QuoteNumber;
            } else if (quote.ExpirationDate == expiredDate) {
                templateId = expiredTemplateId;
                notificationTitle = 'Quote Expired';
                notificationBody = 'Quote Expired: ' + quote.QuoteNumber;
                
                Quote qt = new Quote();
                qt.Id = quote.Id;
                qt.Status = 'Expired';
                expiredQuotes.add(qt);
            }

            if (templateId != null && quote.OwnerId != null) {
                Messaging.SingleEmailMessage renderedEmail = Messaging.renderStoredEmailTemplate(templateId, quote.OwnerId, quote.Id);
                String htmlBody = renderedEmail.getHtmlBody();

                String plainTextBody = renderedEmail.getPlainTextBody();
                htmlBody = htmlBody.replace('{!Quote.Account}', quote.Account.Name);
                plainTextBody = plainTextBody.replace('{!Quote.Account}', quote.Account.Name);
                
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setToAddresses(new List<String>{ quote.Owner.Email });
                email.setSubject(renderedEmail.getSubject());
                email.setHtmlBody(htmlBody);
                email.setPlainTextBody(plainTextBody);
                emails.add(email);
            }

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(notificationTypeId);
            notification.setTitle(notificationTitle);
            notification.setBody(notificationBody);
            notification.setTargetId(quote.Id);
            notification.send(new Set<String>{ quote.OwnerId });
        }

        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails);
        }
        
        if(!expiredQuotes.isEmpty()) {
            Database.update(expiredQuotes);
        }
    }

    global void finish(Database.BatchableContext bc) {
        
    }
}