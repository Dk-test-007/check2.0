public without sharing class LeadDirectAssignmentNotification_CC {
    private static final String ORG_WIDE_ADDRESS_NAME='Carlton No Reply';
    private static final String DIRECT_TEMPLATE='Direct_Lead_Assignment_Notification_CC';
    private static final String SALES_USER_TEMPLATE='Sales_Handover_Notification_Specific_User_CC';
    private static final String DIRECT_NOTIFICATION='Direct_Lead_Assignment_Notification_CC';
    private static final String SALES_USER_NOTIFICATION='Sales_Handover_Notification_Specific_User_CC';
    private static final String MODE_DIRECT='DIRECT';
    private static final String MODE_SALES_USER='SALES_USER';

    public Set<Id> leadIds;
    public String mode;

    public LeadDirectAssignmentNotification_CC(Set<Id> leadIds,String mode){
        this.leadIds=leadIds;
        this.mode=mode;
    }

    public void execute(){
        try{
            if(leadIds==null||leadIds.isEmpty()) return;

            List<Lead> leads=[SELECT Id,Name,Company,LeadSource,Status,OwnerId,Belongs_To_CC__c,Product_Category_Text_CC__c,Last_Marketing_Owner_Id_CC__c,Qualified_Date_CC__c FROM Lead WHERE Id IN :leadIds WITH SYSTEM_MODE];
            if(leads.isEmpty()) return;

            Map<String,Id> templates=getTemplates();
            Map<String,Id> notifications=getNotificationTypes();
            Id orgWideEmailId=getOrgWideEmailId();
            Map<Id,User> owners=getOwners(leads);
            Map<Id,User> marketingOwners=getMarketingOwners(leads);
            Set<Id> directLeadIds=mode==MODE_DIRECT?getDirectlyMappedLeadIds(leads):new Set<Id>();
            List<Messaging.SingleEmailMessage> emails=new List<Messaging.SingleEmailMessage>();

            for(Lead ld:leads){
                if(!owners.containsKey(ld.OwnerId)) continue;

                User owner=owners.get(ld.OwnerId);

                if(mode==MODE_DIRECT){
                    if(!directLeadIds.contains(ld.Id)) continue;
                }else if(mode==MODE_SALES_USER){
                    if(owner.Profile.Name!='Carlton Sales User') continue;
                }else{
                    continue;
                }

                String templateName=mode==MODE_DIRECT?DIRECT_TEMPLATE:SALES_USER_TEMPLATE;
                String notificationName=mode==MODE_DIRECT?DIRECT_NOTIFICATION:SALES_USER_NOTIFICATION;
                Id templateId=templates.get(templateName);
                Id notificationTypeId=notifications.get(notificationName);

                if(templateId!=null&&String.isNotBlank(owner.Email)){
                    Messaging.SingleEmailMessage rendered=Messaging.renderStoredEmailTemplate(templateId,ld.Id,null);
                    Messaging.SingleEmailMessage email=new Messaging.SingleEmailMessage();

                    if(orgWideEmailId!=null) email.setOrgWideEmailAddressId(orgWideEmailId);

                    String body=replaceMergeFields(rendered.getPlainTextBody(),ld,owner,marketingOwners.get(getMarketingOwnerId(ld)));
                    String htmlBody=replaceMergeFields(rendered.getHtmlBody(),ld,owner,marketingOwners.get(getMarketingOwnerId(ld)));

                    if(String.isNotBlank(body)) email.setPlainTextBody(body);
                    if(String.isNotBlank(htmlBody)) email.setHtmlBody(htmlBody);

                    email.setToAddresses(new List<String>{owner.Email});
                    email.setSaveAsActivity(false);
                    email.setSubject(rendered.getSubject());
                    emails.add(email);
                }

                if(notificationTypeId!=null) sendCustomNotification(notificationTypeId,notificationName,ld,owner,marketingOwners.get(getMarketingOwnerId(ld)));
            }

            if(!emails.isEmpty()) Messaging.sendEmail(emails,false);
        }catch(Exception ex){
            System.debug(LoggingLevel.ERROR,'LeadDirectAssignmentNotification_CC: '+ex.getMessage()+'\n'+ex.getStackTraceString());
        }
    }

    public Map<String,Id> getTemplates(){
        Map<String,Id> result=new Map<String,Id>();
        for(EmailTemplate template:[SELECT Id,DeveloperName FROM EmailTemplate WHERE DeveloperName IN (:DIRECT_TEMPLATE,:SALES_USER_TEMPLATE) WITH SYSTEM_MODE]) result.put(template.DeveloperName,template.Id);
        return result;
    }

    public Map<String,Id> getNotificationTypes(){
        Map<String,Id> result=new Map<String,Id>();
        for(CustomNotificationType notification:[SELECT Id,DeveloperName FROM CustomNotificationType WHERE DeveloperName IN (:DIRECT_NOTIFICATION,:SALES_USER_NOTIFICATION) WITH SYSTEM_MODE]) result.put(notification.DeveloperName,notification.Id);
        return result;
    }

    public Id getOrgWideEmailId(){
        List<OrgWideEmailAddress> addresses=[SELECT Id FROM OrgWideEmailAddress WHERE DisplayName=:ORG_WIDE_ADDRESS_NAME WITH SYSTEM_MODE LIMIT 1];
        return addresses.isEmpty()?null:addresses[0].Id;
    }

    public Map<Id,User> getOwners(List<Lead> leads){
        Set<Id> ownerIds=new Set<Id>();

        for(Lead ld:leads){
            if(ld.OwnerId!=null&&ld.OwnerId.getSObjectType()==User.SObjectType) ownerIds.add(ld.OwnerId);
        }

        Map<Id,User> result=new Map<Id,User>();
        if(ownerIds.isEmpty()) return result;

        for(User owner:[SELECT Id,FirstName,Name,Email,Profile.Name FROM User WHERE Id IN :ownerIds AND IsActive=true WITH SYSTEM_MODE]) result.put(owner.Id,owner);

        return result;
    }

    public Id getMarketingOwnerId(Lead ld){
        if(String.isBlank(ld.Last_Marketing_Owner_Id_CC__c)) return null;

        try{
            Id ownerId=Id.valueOf(ld.Last_Marketing_Owner_Id_CC__c.trim());
            return ownerId.getSObjectType()==User.SObjectType?ownerId:null;
        }catch(Exception ex){
            return null;
        }
    }

    public Map<Id,User> getMarketingOwners(List<Lead> leads){
        Set<Id> userIds=new Set<Id>();

        for(Lead ld:leads){
            Id marketingOwnerId=getMarketingOwnerId(ld);
            if(marketingOwnerId!=null) userIds.add(marketingOwnerId);
        }

        Map<Id,User> result=new Map<Id,User>();
        if(userIds.isEmpty()) return result;

        for(User userRecord:[SELECT Id,Name FROM User WHERE Id IN :userIds AND IsActive=true WITH SYSTEM_MODE]) result.put(userRecord.Id,userRecord);

        return result;
    }

    public Set<Id> getDirectlyMappedLeadIds(List<Lead> leads){
        Set<String> mappedCompanies=new Set<String>();

        for(Lead_Company_Owner_Mapping_CC__mdt mapping:[SELECT Company_Name_CC__c FROM Lead_Company_Owner_Mapping_CC__mdt WHERE Active_CC__c=true AND Company_Name_CC__c!=null AND Owner_Id_CC__c!=null WITH SYSTEM_MODE]) mappedCompanies.add(mapping.Company_Name_CC__c);

        Set<Id> result=new Set<Id>();

        for(Lead ld:leads){
            if(String.isNotBlank(ld.Company)&&mappedCompanies.contains(ld.Company)) result.add(ld.Id);
        }

        return result;
    }

    public String replaceMergeFields(String body,Lead ld,User owner,User marketingOwner){
        if(String.isBlank(body)) return body;

        String firstName=String.isNotBlank(owner.FirstName)?owner.FirstName:'Team';
        String ownerName=String.isNotBlank(owner.Name)?owner.Name:'Not Provided';
        String marketingOwnerName=marketingOwner!=null&&String.isNotBlank(marketingOwner.Name)?marketingOwner.Name:'Not Provided';
        String qualificationDate=valueOrDefault(ld.Qualified_Date_CC__c);

        body=body.replace('[Recipient First Name]',firstName);
        body=body.replace('[Assigned To]',ownerName);
        body=body.replace('[LastMarketingOwnerId]',marketingOwnerName);
        body=body.replace('[Qualified_Date_CC__c]',qualificationDate);
        body=body.replace('{!User.FirstName}',firstName);
        body=body.replace('{!Lead.OwnerFullName}',ownerName);

        return body;
    }

    public void sendCustomNotification(Id notificationTypeId,String notificationName,Lead ld,User owner,User marketingOwner){
        String company=String.isNotBlank(ld.Company)?ld.Company:'Lead';
        String firstName=String.isNotBlank(owner.FirstName)?owner.FirstName:'Team';
        String ownerName=String.isNotBlank(owner.Name)?owner.Name:'Not Provided';
        String marketingOwnerName=marketingOwner!=null&&String.isNotBlank(marketingOwner.Name)?marketingOwner.Name:'Not Provided';
        String title;
        String body;

        if(notificationName==DIRECT_NOTIFICATION){
            title='New Lead Assigned: '+company;
            body='Hi '+firstName+',\n\n'+'A new Lead has been assigned to you based on an existing customer relationship.\n\n'+'Key Details:\n'+'• Company: '+company+'\n'+'• Lead Source: '+valueOrDefault(ld.LeadSource)+'\n'+'• Product Category: '+valueOrDefault(ld.Product_Category_Text_CC__c)+'\n'+'• Assigned To: '+ownerName+'\n\n'+'Please review the Lead in Salesforce and begin the qualification process or update the Lead as appropriate.\n\n'+'Thank you,\nCarlton Packaging CRM';
        }else{
            title='Lead Ready for Sales Engagement: '+company;
            body='Hi '+firstName+',\n\n'+'A qualified Lead has been assigned to you for Sales engagement.\n\n'+'Key Details:\n'+'• Company: '+company+'\n'+'• Product Category: '+valueOrDefault(ld.Product_Category_Text_CC__c)+'\n'+'• Qualified By: '+marketingOwnerName+'\n'+'• Qualification Date: '+valueOrDefault(ld.Qualified_Date_CC__c)+'\n\n'+'Please review the Lead in Salesforce and continue the sales engagement process.\n\n'+'Thank you,\nCarlton Packaging CRM';
        }

        Messaging.CustomNotification notification=new Messaging.CustomNotification();
        notification.setNotificationTypeId(notificationTypeId);
        notification.setTitle(title);
        notification.setBody(body);
        notification.setTargetId(ld.Id);
        notification.send(new Set<String>{String.valueOf(owner.Id)});
    }

    public String valueOrDefault(Object value){
        return value==null||String.isBlank(String.valueOf(value))?'Not Provided':String.valueOf(value);
    }
}