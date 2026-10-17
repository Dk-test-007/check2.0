/**
 * =============================================================================
 * Class Name    : CaseTriggerHandler_CC
 * Description   : Trigger handler for Case object
 *
 * Author        : Nipun Jain
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Central trigger handler for Case object.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */
public class CaseTriggerHandler_CC extends BaseTriggerHandler_CC {

    private static final String NO_REPLY_OWA = 'noreplysandbox@carltonpackaging.com';
    private static final String RFQ_ASSIGNED_EMAIL_TEMPLATE = 'RFQ_Moved_to_Awaiting_Information_Status';
    private static final String RFQ_CLOSURE_EMAIL_TEMPLATE = 'RFQ_Moved_to_Closed_Statuses';
    private static final String RFQ_CREATED_NOTIFICATION = 'New_RFQ';
    private static final String RFQ_ASSIGNED_NOTIFICATION = 'RFQ_Assigned_Notification';
    private static final String RFQ_CLOSURE_NOTIFICATION = 'RFQ_Closure_Notification';
    private static final String RFQ_OWNER_CHANGE_NOTIFICATION = 'RFQ_Closure_Notification';
    private static final String RFQ_OWNER_CHANGE_EMAIL_TEMPLATE = 'RFQ_Ownership_Change_Notification';
    private static final String RFQ_AWAITIING_INFO_NOTIFICATION_BODY = 'Action Required: Additional Information Needed - RFQ {0}';
    private static final String RFQ_CLOSED_NOTIFICATION_BODY = 'RFQ {1}: {0}';
    private static final String RFQ_OWNER_CHANGE_NOTIFICATION_BODY = 'RFQ Ownership Changed: {0}';
    private static final String RFQ_CREATED_NOTIFICATION_BODY = 'New RFQ Assigned: {0}';
    private static final String CPT_POOL_QUEUE = 'CPT_Pool';
    private static final String CPT_POOL_ID = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName =: CPT_POOL_QUEUE WITH SYSTEM_MODE]?.Id;

    public void run() {
        super.run(this, 'Case');
    }

    public override void beforeInsert() {
        syncCaseAccountWithOpp((List<Case>) Trigger.new);
    }
    
    public override void afterInsert() {
        sendBellNotification((List<Case>) Trigger.new);
    }

    public override void beforeUpdate() {
        handleBeforeUpdate((List<Case>) Trigger.new, (Map<Id, Case>) Trigger.oldMap);
    }

    public override void afterUpdate() {
        handleStatusNotifications((List<Case>) Trigger.new,(Map<Id, Case>) Trigger.oldMap);
    }
    
    public static void sendBellNotification(List<Case> newCases) {
        Id rfqCreationNotificationTemplate = [SELECT Id FROM CustomNotificationType WHERE DeveloperName =: RFQ_CREATED_NOTIFICATION WITH SYSTEM_MODE]?.Id;
        Id rfqRecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('RFQ').getRecordTypeId();

        for(Case newCase: newCases) {

            if(newCase.RecordTypeId == rfqRecordTypeId) {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setTitle('New RFQ Assigned');
                notification.setBody(String.format(RFQ_CREATED_NOTIFICATION_BODY, new List<Object>{newCase.CaseNumber}));
                notification.setNotificationTypeId(rfqCreationNotificationTemplate);
                notification.setTargetId(newCase.Id);
                
                notification.send(new Set<String>{ String.valueOf(CPT_POOL_ID) });

            }
        }
    }

    public static void handleBeforeUpdate(List<Case> newCases,Map<Id, Case> oldCaseMap) {
        for (Case newCase : newCases) {
            Case oldCase = oldCaseMap.get(newCase.Id);
            if (isUser(newCase.OwnerId) && isCptQueue(oldCase.OwnerId) && newCase.Status == 'Submitted') {
                newCase.Status = 'Assigned';
            }
        }
    }

    public static void syncCaseAccountWithOpp(List<Case> newCases) {
        Set<Id> opportunityIds = new Set<Id>();

        for (Case newCase : newCases) {
            if (newCase.Opportunity__c != null) {
                opportunityIds.add(newCase.Opportunity__c);
            }
        }

        Map<Id, Opportunity> opportunitiesById = new Map<Id, Opportunity>([SELECT Id, AccountId FROM Opportunity WHERE Id IN :opportunityIds WITH SYSTEM_MODE]);

        for (Case newCase : newCases) {
            if (newCase.Opportunity__c != null && opportunitiesById.containsKey(newCase.Opportunity__c)) {
                newCase.AccountId = opportunitiesById.get(newCase.Opportunity__c).AccountId;
            }
        }
    }

    public static void handleStatusNotifications(List<Case> newCases, Map<Id, Case> oldCaseMap) {
        Set<Id> awaitingInformationCaseIds = new Set<Id>();
        Set<Id> closureCaseIds = new Set<Id>();
        Map<Id, Id> caseToPreviousOwnerMap = new Map<Id, Id>();

        for (Case newCase : newCases) {
            Case oldCase = oldCaseMap.get(newCase.Id);

            if(newCase.OwnerId != oldCase.OwnerId && newCase.Status != 'Submitted' ) {
                caseToPreviousOwnerMap.put(newCase.Id, oldCase.OwnerId);
            }
            if (newCase.Status != oldCase.Status && newCase.Status == 'Awaiting Information') {
                awaitingInformationCaseIds.add(newCase.Id);
            }
            else if (newCase.Status != oldCase.Status && (newCase.Status == 'Completed' || newCase.Status == 'Rejected' || newCase.Status == 'Cancelled')) {
                closureCaseIds.add(newCase.Id);
            } 
        }

        if (!awaitingInformationCaseIds.isEmpty() || !closureCaseIds.isEmpty() || !caseToPreviousOwnerMap.isEmpty()) {
            sendStatusNotifications(awaitingInformationCaseIds, closureCaseIds, caseToPreviousOwnerMap, newCases);
        }

    }

    public static void sendStatusNotifications(Set<Id> awaitingInformationCaseIds, Set<Id> closureCaseIds, Map<Id, Id> caseToPreviousOwnerMap, List<Case> newCases) {
        Set<Id> caseIds = new Set<Id>();
        caseIds.addAll(awaitingInformationCaseIds);
        caseIds.addAll(closureCaseIds);
        caseIds.addAll(caseToPreviousOwnerMap.keyset());

        Map<Id, Case> casesById = new Map<Id, Case>(newCases);

        Set<String> templateDeveloperNames = new Set<String>();
        Set<String> notificationDeveloperNames = new Set<String>();

        if (!awaitingInformationCaseIds.isEmpty()) {
            templateDeveloperNames.add(RFQ_ASSIGNED_EMAIL_TEMPLATE);
            notificationDeveloperNames.add(RFQ_ASSIGNED_NOTIFICATION);
        }

        if (!closureCaseIds.isEmpty()) {
            templateDeveloperNames.add(RFQ_CLOSURE_EMAIL_TEMPLATE);
            notificationDeveloperNames.add(RFQ_CLOSURE_NOTIFICATION);
        }
        
        if(!caseToPreviousOwnerMap.isEmpty()) {
            templateDeveloperNames.add(RFQ_OWNER_CHANGE_EMAIL_TEMPLATE);
            notificationDeveloperNames.add(RFQ_OWNER_CHANGE_NOTIFICATION);
        }

        Map<String, Id> templateIdsByDeveloperName = new Map<String, Id>();

        if (!templateDeveloperNames.isEmpty()) {
            for (EmailTemplate template : [SELECT Id, DeveloperName FROM EmailTemplate WHERE DeveloperName IN :templateDeveloperNames WITH SYSTEM_MODE]) {
                templateIdsByDeveloperName.put(template.DeveloperName, template.Id);
            }
        }

        Map<String, Id> notificationIdsByDeveloperName = new Map<String, Id>();

        if (!notificationDeveloperNames.isEmpty()) {
            for (CustomNotificationType notification : [SELECT Id, DeveloperName FROM CustomNotificationType WHERE DeveloperName IN :notificationDeveloperNames WITH SYSTEM_MODE]) {
                notificationIdsByDeveloperName.put(notification.DeveloperName, notification.Id);
            }
        }

        Set<Id> creatorIds = new Set<Id>();
        Set<Id> previousOwnerUserIds = new Set<Id>();
        Set<Id> previousOwnerGroupIds = new Set<Id>();

        for (Id caseId : caseIds) {
            creatorIds.add(casesById.get(caseId).CreatedById);
            if(caseToPreviousOwnerMap.containsKey(caseId)) {
                if(String.valueOf(caseToPreviousOwnerMap.get(caseId)).startsWith('005')) {
                    previousOwnerUserIds.add(caseToPreviousOwnerMap.get(caseId));
                }
                else if(String.valueOf(caseToPreviousOwnerMap.get(caseId)).startsWith('00G')) {
                    previousOwnerGroupIds.add(caseToPreviousOwnerMap.get(caseId));
                }
            }
        }

        Map<Id, User> creatorsById = new Map<Id, User>();

        if (!creatorIds.isEmpty()) {
            creatorsById = new Map<Id, User>([SELECT Id, Name, FirstName, Email FROM User WHERE Id IN :creatorIds WITH SYSTEM_MODE]);
        }

        Map<Id, User> previousOwnersById = new Map<Id, User>();
        Map<Id, Group> previousOwnerGroupsById = new Map<Id, Group>();

        if (!previousOwnerUserIds.isEmpty()) {
            previousOwnersById = new Map<Id, User>([SELECT Id, Name, Email FROM User WHERE Id IN :previousOwnerUserIds WITH SYSTEM_MODE]);
        }

        if (!previousOwnerGroupIds.isEmpty()) {
            previousOwnerGroupsById = new Map<Id, Group>([SELECT Id, Name FROM Group WHERE Type = 'Queue' AND Id IN :previousOwnerGroupIds WITH SYSTEM_MODE]);
        }

        Id orgWideEmailAddressId;

        if (!templateIdsByDeveloperName.isEmpty()) {
            orgWideEmailAddressId = [SELECT Id FROM OrgWideEmailAddress WHERE Address = :NO_REPLY_OWA WITH SYSTEM_MODE LIMIT 1]?.Id;
        }

        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (Id caseId : caseIds) {
            Case currentCase = casesById.get(caseId);
            Boolean isAwaitingInformation = awaitingInformationCaseIds.contains(caseId);
            Boolean isOwnerUpdateRFQ = caseToPreviousOwnerMap.containsKey(caseId);

            String templateDeveloperName = isAwaitingInformation 
                							? RFQ_ASSIGNED_EMAIL_TEMPLATE 
                							: isOwnerUpdateRFQ
                                                ? RFQ_OWNER_CHANGE_EMAIL_TEMPLATE
             									: RFQ_CLOSURE_EMAIL_TEMPLATE;

            String notificationDeveloperName = isAwaitingInformation 
                								? RFQ_ASSIGNED_NOTIFICATION 
                								: isOwnerUpdateRFQ 
                                                    ? RFQ_OWNER_CHANGE_NOTIFICATION
                                                    : RFQ_CLOSURE_NOTIFICATION;
            
            Id templateId = templateIdsByDeveloperName.get(templateDeveloperName);
            Id notificationId = notificationIdsByDeveloperName.containsKey(notificationDeveloperName) ? notificationIdsByDeveloperName.get(notificationDeveloperName) : NULL;
            User caseCreator = creatorsById.get(currentCase.CreatedById);

            if (templateId != null) {
                String emailReceipientId = isOwnerUpdateRFQ && isUser(currentCase.OwnerId) ? currentCase.OwnerId : caseCreator.Id;
                Messaging.SingleEmailMessage renderedEmail = Messaging.renderStoredEmailTemplate(templateId, emailReceipientId, currentCase.Id);
                
                Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                mail.setToAddresses(new String [] {caseCreator.Email});
                mail.setSubject(renderedEmail.getSubject());
                
                String previousOwnerName = isOwnerUpdateRFQ ? getOwnerName(caseToPreviousOwnerMap.get(currentCase.Id), previousOwnersById, previousOwnerGroupsById) : NULL;
                String finalHtmlBody = isOwnerUpdateRFQ ? renderedEmail.getHtmlBody().replace('##PREVIOUS_OWNER##', previousOwnerName) : renderedEmail.getHtmlBody();
                String finalTextBody = isOwnerUpdateRFQ ? renderedEmail.getPlainTextBody().replace('##PREVIOUS_OWNER##', previousOwnerName) : renderedEmail.getPlainTextBody();

                if (isOwnerUpdateRFQ && isCptQueue(currentCase.OwnerId)) {
                    finalHtmlBody = finalHtmlBody.replace('Hi ' + caseCreator.FirstName + ',', 'Hi Team,');
                    finalTextBody = finalTextBody.replace('Hi ' + caseCreator.FirstName + ',', 'Hi Team,');
                }

                mail.setHtmlBody(finalHtmlBody);
                mail.setPlainTextBody(finalTextBody);
                
                mail.setOrgWideEmailAddressId(orgWideEmailAddressId);
    
                emails.add(mail);
                
                if(isOwnerUpdateRFQ) {
                    Id previousOwnerId = caseToPreviousOwnerMap.get(currentCase.Id);
                    Id previousOwnerRecipientId = isUser(previousOwnerId) ? previousOwnerId : caseCreator.Id;

                    Messaging.SingleEmailMessage renderedEmail1 = Messaging.renderStoredEmailTemplate(templateId, previousOwnerRecipientId, currentCase.Id);
                    
                    Messaging.SingleEmailMessage mail1 = new Messaging.SingleEmailMessage();
                    mail1.setToAddresses(new String [] {caseCreator.Email});
                    mail1.setSubject(renderedEmail1.getSubject());

                    String finalHtmlBody1 = renderedEmail1.getHtmlBody().replace('##PREVIOUS_OWNER##', previousOwnerName);
                    String finalTextBody1 = renderedEmail1.getPlainTextBody().replace('##PREVIOUS_OWNER##', previousOwnerName);

                    if (isCptQueue(previousOwnerId)) {
                        finalHtmlBody1 = finalHtmlBody1.replace('Hi ' + caseCreator.FirstName + ',', 'Hi Team,');
                        finalTextBody1 = finalTextBody1.replace('Hi ' + caseCreator.FirstName + ',', 'Hi Team,');
                    }

                    mail1.setHtmlBody(finalHtmlBody1);
                    mail1.setPlainTextBody(finalTextBody1);
                    mail1.setOrgWideEmailAddressId(orgWideEmailAddressId);
                    
                    emails.add(mail1);
                }
            }
            if (notificationId != null) {
                String notificationBody = isAwaitingInformation ? RFQ_AWAITIING_INFO_NOTIFICATION_BODY : isOwnerUpdateRFQ ? RFQ_OWNER_CHANGE_NOTIFICATION_BODY : RFQ_CLOSED_NOTIFICATION_BODY;
                
                Messaging.CustomNotification notification = new Messaging.CustomNotification();

                notification.setTitle('RFQ Updated');
                notification.setBody(String.format(notificationBody,new List<Object>{currentCase.CaseNumber,currentCase.RFQ_Outcome__c})
                );

                notification.setNotificationTypeId(notificationId);
                notification.setTargetId(currentCase.Id);

                notification.send(new Set<String>{String.valueOf(isOwnerUpdateRFQ ? currentCase.OwnerId : currentCase.CreatedById)});
            }
        }

        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails);
        }
    }
    
    public static String getOwnerName(Id ownerId, Map<Id, User> ownersById, Map<Id, Group> groupsById) {
        return isUser(ownerId) ? ownersById.get(ownerId)?.Name : isCptQueue(ownerId) ? groupsById.get(ownerId)?.Name : NULL;
    }

    public static Boolean isUser(Id ownerId) {
        return ownerId != null && String.valueOf(ownerId).startsWith('005');
    }

    public static Boolean isCptQueue(Id ownerId) {
        return ownerId != null && ownerId == CPT_POOL_ID;
    }
}