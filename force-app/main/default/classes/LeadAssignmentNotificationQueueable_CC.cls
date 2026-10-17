public without sharing class LeadAssignmentNotificationQueueable_CC implements Queueable {
    private static final String ORG_WIDE_ADDRESS_NAME='Carlton No Reply';
    private static final String POOL_TEMPLATE='Lead_Pool_Assignment_Notification_CC';
    private static final String CONSOLIDATED_TEMPLATE='Consolidated_Lead_Assignment_Notification_CC';
    private static final String SALES_POOL_TEMPLATE='Sales_Handover_Notification_Sales_Pool_CC';
    private static final String POOL_NOTIFICATION='Lead_Pool_Assignment_Notification_CC';
    private static final String CONSOLIDATED_NOTIFICATION='Consolidated_Lead_Assignment_Notification_CC';
    private static final String SALES_POOL_NOTIFICATION='Sales_Handover_Notification_Sales_Pool_CC';
    private static final Set<String> TARGET_QUEUES=new Set<String>{'UK_Marketing_Pool','US_Marketing_Pool','UK_Sales_Pool','US_Sales_Pool'};
    private static final Set<String> SALES_QUEUES=new Set<String>{'UK_Sales_Pool','US_Sales_Pool'};
    private Set<Id> leadIds;
    private String batchJobId;
    private Boolean bulkImport;
    private Boolean insertAssignment;

    private class RecipientData {
        Map<Id,Set<String>> emails=new Map<Id,Set<String>>();
        Map<Id,Set<String>> userIds=new Map<Id,Set<String>>();
    }

    public LeadAssignmentNotificationQueueable_CC(Set<Id> leadIds){
        this(leadIds,null,false,false);
    }

    public LeadAssignmentNotificationQueueable_CC(Set<Id> leadIds,String batchJobId,Boolean bulkImport,Boolean insertAssignment){
        this.leadIds=leadIds;
        this.batchJobId=batchJobId;
        this.bulkImport=bulkImport;
        this.insertAssignment=insertAssignment;
    }

    public void execute(QueueableContext context){
        try{
            if(leadIds==null||leadIds.isEmpty()) return;
            String effectiveBatchJobId=String.isNotBlank(batchJobId)?batchJobId:context.getJobId();

            List<Lead> leads=[SELECT Id,Name,Company,LeadSource,Status,OwnerId,Belongs_To_CC__c,Product_Category_Text_CC__c FROM Lead WHERE Id IN :leadIds WITH SYSTEM_MODE];
            if(leads.isEmpty()) return;

            Map<String,Id> templates=getTemplates();
            Map<String,Id> notifications=getNotificationTypes();
            Id orgWideEmailId=getOrgWideEmailId();
            RecipientData recipientData=resolveRecipients(leads);

            if(recipientData.emails.isEmpty()&&recipientData.userIds.isEmpty()) return;

            Map<Id,List<Lead>> ownerToLeads=groupLeadsByOwner(leads);
            Set<Id> directlyMappedLeads=getDirectlyMappedLeadIds(leads);
            Map<Id,Group> ownerQueues=getOwnerQueues(ownerToLeads.keySet());

            buildAndSend(ownerToLeads,recipientData,templates,notifications,orgWideEmailId,ownerQueues,directlyMappedLeads,effectiveBatchJobId);
        }catch(Exception ex){
            System.debug(LoggingLevel.ERROR,'LeadAssignmentNotificationQueueable_CC: '+ex.getMessage()+'\n'+ex.getStackTraceString());
        }
    }

    private Map<String,Id> getTemplates(){
        Map<String,Id> result=new Map<String,Id>();
        for(EmailTemplate t:[SELECT Id,DeveloperName FROM EmailTemplate WHERE DeveloperName IN (:POOL_TEMPLATE,:CONSOLIDATED_TEMPLATE,:SALES_POOL_TEMPLATE) WITH SYSTEM_MODE]) result.put(t.DeveloperName,t.Id);
        return result;
    }

    private Map<String,Id> getNotificationTypes(){
        Map<String,Id> result=new Map<String,Id>();
        for(CustomNotificationType n:[SELECT Id,DeveloperName FROM CustomNotificationType WHERE DeveloperName IN (:POOL_NOTIFICATION,:CONSOLIDATED_NOTIFICATION,:SALES_POOL_NOTIFICATION) WITH SYSTEM_MODE]) result.put(n.DeveloperName,n.Id);
        return result;
    }

    private Id getOrgWideEmailId(){
        List<OrgWideEmailAddress> addresses=[SELECT Id FROM OrgWideEmailAddress WHERE DisplayName=:ORG_WIDE_ADDRESS_NAME WITH SYSTEM_MODE LIMIT 1];
        return addresses.isEmpty()?null:addresses[0].Id;
    }

    private Set<Id> getDirectlyMappedLeadIds(List<Lead> leads){
        Set<String> mappedCompanies=new Set<String>();
        for(Lead_Company_Owner_Mapping_CC__mdt mapping:[SELECT Company_Name_CC__c FROM Lead_Company_Owner_Mapping_CC__mdt WHERE Active_CC__c=true AND Company_Name_CC__c!=null AND Owner_Id_CC__c!=null WITH SYSTEM_MODE]) mappedCompanies.add(mapping.Company_Name_CC__c);

        Set<Id> result=new Set<Id>();
        for(Lead ld:leads) if(String.isNotBlank(ld.Company)&&mappedCompanies.contains(ld.Company)) result.add(ld.Id);
        return result;
    }

    private RecipientData resolveRecipients(List<Lead> leads){
        RecipientData data=new RecipientData();
        Set<Id> ownerIds=new Set<Id>();

        for(Lead ld:leads) if(ld.OwnerId!=null) ownerIds.add(ld.OwnerId);
        if(ownerIds.isEmpty()) return data;

        Map<Id,Group> queues=new Map<Id,Group>([SELECT Id,DeveloperName FROM Group WHERE Id IN :ownerIds AND Type='Queue' AND DeveloperName IN :TARGET_QUEUES WITH SYSTEM_MODE]);

        if(queues.isEmpty()) return data;

        Map<Id,Set<Id>> queueUsers=new Map<Id,Set<Id>>();
        Set<Id> memberIds=new Set<Id>();

        for(GroupMember gm:[SELECT GroupId,UserOrGroupId FROM GroupMember WHERE GroupId IN :queues.keySet() WITH SYSTEM_MODE]){
            if(gm.UserOrGroupId!=null&&gm.UserOrGroupId.getSObjectType()==User.SObjectType){
                if(!queueUsers.containsKey(gm.GroupId)) queueUsers.put(gm.GroupId,new Set<Id>());
                queueUsers.get(gm.GroupId).add(gm.UserOrGroupId);
                memberIds.add(gm.UserOrGroupId);
            }
        }

        if(memberIds.isEmpty()) return data;

        Map<Id,User> members=new Map<Id,User>([SELECT Id,Email FROM User WHERE Id IN :memberIds AND IsActive=true WITH SYSTEM_MODE]);

        for(Id queueId:queueUsers.keySet()){
            Set<String> emailSet=new Set<String>();
            Set<String> userSet=new Set<String>();

            for(Id userId:queueUsers.get(queueId)){
                User u=members.get(userId);
                if(u==null) continue;
                userSet.add(String.valueOf(u.Id));
                if(String.isNotBlank(u.Email)) emailSet.add(u.Email);
            }

            if(!userSet.isEmpty()) data.userIds.put(queueId,userSet);
            if(!emailSet.isEmpty()) data.emails.put(queueId,emailSet);
        }

        return data;
    }

    private Map<Id,List<Lead>> groupLeadsByOwner(List<Lead> leads){
        Map<Id,List<Lead>> result=new Map<Id,List<Lead>>();
        for(Lead ld:leads){
            if(ld.OwnerId==null) continue;
            if(!result.containsKey(ld.OwnerId)) result.put(ld.OwnerId,new List<Lead>());
            result.get(ld.OwnerId).add(ld);
        }
        return result;
    }

    private Map<Id,Group> getOwnerQueues(Set<Id> ownerIds){
        Map<Id,Group> result=new Map<Id,Group>();
        if(ownerIds.isEmpty()) return result;
        for(Group g:[SELECT Id,DeveloperName FROM Group WHERE Id IN :ownerIds AND Type='Queue' AND DeveloperName IN :TARGET_QUEUES WITH SYSTEM_MODE]) result.put(g.Id,g);
        return result;
    }

    private void buildAndSend(Map<Id,List<Lead>> ownerToLeads,RecipientData recipientData,Map<String,Id> templates,Map<String,Id> notifications,Id orgWideEmailId,Map<Id,Group> ownerQueues,Set<Id> directlyMappedLeads,String batchJobId){
        List<Messaging.SingleEmailMessage> emails=new List<Messaging.SingleEmailMessage>();

        for(Id ownerId:ownerToLeads.keySet()){
            if(!ownerQueues.containsKey(ownerId)||!recipientData.emails.containsKey(ownerId)) continue;

            List<Lead> assignedLeads=ownerToLeads.get(ownerId);
            if(assignedLeads==null||assignedLeads.isEmpty()) continue;

            Lead firstLead=assignedLeads[0];
            Boolean consolidated=bulkImport||assignedLeads.size()>1;

            if(!consolidated&&insertAssignment&&directlyMappedLeads.contains(firstLead.Id)) continue;

            Boolean salesPool=SALES_QUEUES.contains(ownerQueues.get(ownerId).DeveloperName);
            String templateName=consolidated?CONSOLIDATED_TEMPLATE:salesPool?SALES_POOL_TEMPLATE:POOL_TEMPLATE;
            String notificationName=consolidated?CONSOLIDATED_NOTIFICATION:salesPool?SALES_POOL_NOTIFICATION:POOL_NOTIFICATION;
            Id templateId=templates.get(templateName);
            Id notificationTypeId=notifications.get(notificationName);

            if(templateId!=null){
                Messaging.SingleEmailMessage rendered=Messaging.renderStoredEmailTemplate(templateId,firstLead.Id,null);
                Messaging.SingleEmailMessage email=new Messaging.SingleEmailMessage();

                if(orgWideEmailId!=null) email.setOrgWideEmailAddressId(orgWideEmailId);
                email.setToAddresses(new List<String>(recipientData.emails.get(ownerId)));
                email.setSaveAsActivity(false);

                String subject=rendered.getSubject();
                String body=rendered.getPlainTextBody();

                if(consolidated){
                    subject=assignedLeads.size()+' New Leads Assigned';
                    body=replaceBulkValues(body,assignedLeads,batchJobId);
                }

                email.setSubject(subject);
                email.setPlainTextBody(body);

                if(String.isNotBlank(rendered.getHtmlBody())){
                    String htmlBody=rendered.getHtmlBody();
                    if(consolidated) htmlBody=replaceBulkValues(htmlBody,assignedLeads,batchJobId);
                    email.setHtmlBody(htmlBody);
                }

                emails.add(email);
            }

            if(notificationTypeId!=null&&recipientData.userIds.containsKey(ownerId)&&!recipientData.userIds.get(ownerId).isEmpty()){
                sendCustomNotification(notificationTypeId,notificationName,firstLead,assignedLeads,recipientData.userIds.get(ownerId),batchJobId);
            }
        }

        if(!emails.isEmpty()) Messaging.sendEmail(emails,false);
    }

    private void sendCustomNotification(Id notificationTypeId,String notificationName,Lead firstLead,List<Lead> assignedLeads,Set<String> recipientIds,String batchJobId){
        String company=String.isNotBlank(firstLead.Company)?firstLead.Company:'Lead';
        String title;
        String body;

        if(notificationName==CONSOLIDATED_NOTIFICATION){
            title=assignedLeads.size()+' New Leads Assigned';
            body='Hi Team,\n\nA batch of new Leads has been assigned to you through a bulk import.\n\nKey Details:\n'+
                '• Total Leads Assigned: '+assignedLeads.size()+'\n'+
                '• Import Batch: '+valueOrDefault(batchJobId)+'\n'+
                '• Entity: '+getEntities(assignedLeads)+'\n\nPlease review your assigned Leads in Salesforce and begin the qualification process.\n\nThank you,\nCarlton Packaging CRM';
        }else if(notificationName==SALES_POOL_NOTIFICATION){
            title='New Qualified Lead Available: '+company;
            body='Hi Team,\n\nA qualified Lead has been assigned to your Sales pool.\n\nKey Details:\n'+
                '• Company: '+company+'\n'+
                '• Product Category: '+valueOrDefault(firstLead.Product_Category_Text_CC__c)+'\n'+
                '• Entity: '+valueOrDefault(firstLead.Belongs_To_CC__c)+'\n\nPlease review the Lead in Salesforce, claim ownership and begin customer engagement.\n\nThank you,\nCarlton Packaging CRM';
        }else{
            title='New Lead Added to Your Pool: '+company;
            body='Hi Team,\n\nA new Lead has been added to your Marketing pool.\n\nKey Details:\n'+
                '• Company: '+company+'\n'+
                '• Lead Source: '+valueOrDefault(firstLead.LeadSource)+'\n'+
                '• Product Category: '+valueOrDefault(firstLead.Product_Category_Text_CC__c)+'\n'+
                '• Entity: '+valueOrDefault(firstLead.Belongs_To_CC__c)+'\n\nPlease review the Lead in Salesforce and claim ownership for follow-up.\n\nThank you,\nCarlton Packaging CRM';
        }

        Messaging.CustomNotification notification=new Messaging.CustomNotification();
        notification.setNotificationTypeId(notificationTypeId);
        notification.setTitle(title);
        notification.setBody(body);
        notification.setTargetId(firstLead.Id);
        notification.send(recipientIds);
    }

    private String replaceBulkValues(String body,List<Lead> leads,String batchJobId){
        if(body==null) return '';
        body=body.replace('[Number of Leads]',String.valueOf(leads.size()));
        body=body.replace('[Recipient First Name]','Team');
        body=body.replace('[Batch Job ID]',batchJobId);
        body=body.replace('[Batch Name or Reference]',batchJobId);
        body=body.replace('[Entity]',getEntities(leads));
        body=body.replace('[Salesforce Record/List Link]',buildLeadDetails(leads));
        return body;
    }

    private String getEntities(List<Lead> leads){
        Set<String> entities=new Set<String>();
        for(Lead ld:leads) if(String.isNotBlank(ld.Belongs_To_CC__c)) entities.add(ld.Belongs_To_CC__c);
        if(entities.isEmpty()) return 'Not Provided';
        List<String> values=new List<String>(entities);
        values.sort();
        return String.join(values,', ');
    }

    private String buildLeadDetails(List<Lead> leads){
        String url=URL.getOrgDomainUrl().toExternalForm();
        String body='';
        for(Lead ld:leads) body+='Company: '+(String.isNotBlank(ld.Company)?ld.Company:'Not Provided')+'\nLead Name: '+(String.isNotBlank(ld.Name)?ld.Name:'Unknown')+'\nLead Link: '+url+'/'+ld.Id+'\n\n';
        return body;
    }

    private String valueOrDefault(Object value){
        return value==null||String.isBlank(String.valueOf(value))?'Not Provided':String.valueOf(value);
    }
}