/**
 * =============================================================================
 * Class Name    : LeadTriggerHandler_CC
 * Description   : Trigger handler for Lead object
 *
 * Author        : Vansh Mansotra
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 * 1          15/08/2026   Vansh Mansotra     Initial handler implementation
 * 2          27/08/2026   Vansh Mansotra     Re-Nurture owner assignment
 *
 * =============================================================================
 * Usage:

 * Lead assignment notification is handled asynchronously through:
 * LeadAssignmentNotificationQueueable_CC
 * Re-Nurture ownership re-assignment is handled by assignOwnerOnReNurture().
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */
public without sharing class LeadTriggerHandler_CC_New extends BaseTriggerHandler_CC {
    private static Boolean transferDone = false;
    private static Map<String, Id> queueIdsByName;
    private static Boolean transferQueued  = false;
    
    public void run() {
        super.run(this, 'Lead');
    }
    
    public override void beforeInsert() {
        sortProductCategories((List<Lead>) Trigger.new, null);
        sortEmailValues((List<Lead>) Trigger.new, null);
        applyCompanyOwnerMapping((List<Lead>) Trigger.new, null);
        stampLastMarketingOwner((List<Lead>) Trigger.new, null);
    }
    
    public override void beforeUpdate(){
        List<Lead> leadsQualifying = new List<Lead>();
        Map<Id, Lead> oldLeadMap = (Map<Id, Lead>) Trigger.oldMap;
        for (Lead leadRecord : (List<Lead>) Trigger.new) {
            Lead oldLead = oldLeadMap.get(leadRecord.Id);
            if (oldLead.Status != 'Qualify' && leadRecord.Status == 'Qualify' && !leadRecord.Bypass_Duplicate_Rules_on_Qualification__c) {
                leadsQualifying.add(leadRecord);
            }
        }
        if (!leadsQualifying.isEmpty()) {
            checkDuplicates(leadsQualifying);
        }
        sortProductCategories((List<Lead>) Trigger.new,(Map<Id, Lead>) Trigger.oldMap);
        sortEmailValues((List<Lead>) Trigger.new,(Map<Id, Lead>) Trigger.oldMap);
        applyCompanyOwnerMapping((List<Lead>) Trigger.new, (Map<Id, Lead>)Trigger.oldMap);
        stampLastMarketingOwner((List<Lead>) Trigger.new, (Map<Id, Lead>) Trigger.oldMap);
        captureQualifyDate((List<Lead>)Trigger.new,oldLeadMap);
        raiseValidationOnOwnerChange((List<Lead>) Trigger.new, (Map<Id, Lead>) Trigger.oldMap);
    }
    
    public override void afterInsert() {
        notifyRoleManagerOnDuplicateLead((List<Lead>) Trigger.new);

        Set<Id> leadIds = new Set<Id>();
        List<Id> lstOfLeadsTobeMarkedImportFalse = new List<Id>();
        Boolean bulkImport = Trigger.new.size() > 1;

        for (Lead leadRecord : (List<Lead>) Trigger.new) {
            leadIds.add(leadRecord.Id);

            if (leadRecord.Bypass_Duplicate_Rules_on_Import_CC__c == true) {
                lstOfLeadsTobeMarkedImportFalse.add(leadRecord.Id);
            }
        }

        if (!lstOfLeadsTobeMarkedImportFalse.isEmpty()) {
            resetBypassDuplicateRules(lstOfLeadsTobeMarkedImportFalse);
        }

        if (!leadIds.isEmpty()) {
            new LeadAssignmentNotification_CC(leadIds,null,bulkImport,true).execute();
            if (!bulkImport) {
                new LeadDirectAssignmentNotification_CC(leadIds,'DIRECT').execute();
            }
        }
    }
        
    public override void afterUpdate() {
        Map<Id, Lead> oldLeadMap = (Map<Id, Lead>) Trigger.oldMap;
        Set<Id> leadIds = new Set<Id>();

        for (Lead newLead : (List<Lead>) Trigger.new) {
            Lead oldLead = oldLeadMap.get(newLead.Id);

            if (oldLead != null && newLead.OwnerId != oldLead.OwnerId) {
                leadIds.add(newLead.Id);
            }
        }

        if (!leadIds.isEmpty()) {
            new LeadAssignmentNotification_CC(leadIds,null,false,false).execute();
              // Sales Handover (Specific User) is only for a Marketing Representative reassigning to Sales
            if (isCurrentUserMarketing()) {
                new LeadDirectAssignmentNotification_CC(leadIds,'SALES_USER').execute();
            }
        }
        assignOwnerOnReNurture( (List<Lead>) Trigger.new, (Map<Id, Lead>) Trigger.oldMap);
    }
    
    public static Boolean isCurrentUserMarketing() {
        return [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() WITH SYSTEM_MODE].Name == 'Carlton Marketing User';
    }

    public static void sortProductCategories(List<Lead> newLeads,Map<Id, Lead> oldLeadMap) {
        for (Lead newLead : newLeads) {
            if((oldLeadMap == null && (!String.isBlank(newLead.Product_Category_CC__c))) || (oldLeadMap != null && (!String.isBlank(newLead.Product_Category_CC__c) &&  newLead.Product_Category_CC__c != oldLeadMap.get(newLead.Id).Product_Category_CC__c)) ) {
                List<String> categories = newLead.Product_Category_CC__c.split(';');
                categories.sort();
                newLead.Product_Category_Text_CC__c = String.join(categories, ';');
            }
        }
    }
    
    public static void sortEmailValues(List<Lead> newLeads,Map<Id, Lead> oldLeadMap) {
        for (Lead newLead : newLeads) {
            if((oldLeadMap == null && (!String.isBlank(newLead.email) || !String.isBlank(newLead.Secondary_Email_Address_CC__c))) || (oldLeadMap != null && ((newLead.email != oldLeadMap.get(newLead.Id).email) || (newLead.Secondary_Email_Address_CC__c != oldLeadMap.get(newLead.Id).Secondary_Email_Address_CC__c))) ) {
                List<String> lstOfEmail = new List<String>();
                if(!String.isBlank(newLead.email)) {
                    lstOfEmail.add(newLead.email);
                }
                if(!String.isBlank(newLead.Secondary_Email_Address_CC__c)) {
                    lstOfEmail.add(newLead.Secondary_Email_Address_CC__c);
                }
                lstOfEmail.sort();
                newLead.Email_List_CC__c = String.join(lstOfEmail, ';');
            }
        }
    }
    
    public static void checkDuplicates(List<Lead> newLeads) {
        List<Lead> chunk = new List<Lead>();
        for ( Lead ld : newLeads) {
            chunk.add(ld);
            if (chunk.size() == 50) {
                processChunk(chunk);
                chunk.clear();
            }
        }
        if (!chunk.isEmpty()) {
            processChunk(chunk);
        }
    }
    public static void processChunk(List<Lead> leadChunk) {
        List<Datacloud.FindDuplicatesResult> results = Datacloud.FindDuplicates.findDuplicates( leadChunk);
        for ( Integer i = 0; i < leadChunk.size(); i++) {
            Lead currentLead = leadChunk[i];
            Datacloud.FindDuplicatesResult findDupResult = results[i];
            for ( Datacloud.DuplicateResult dupResult : findDupResult.getDuplicateResults()) {
                for ( Datacloud.MatchResult matchResult : dupResult.getMatchResults()) {
                    if ( matchResult.getMatchRecords().size() > 0) {
                        String dupRuleName = dupResult.getDuplicateRule();
                        currentLead.addError('This Lead matches an existing record.');
                        break;
                    }
                }
            }
        }
    }
    
    public static void applyCompanyOwnerMapping(List<Lead> leads,Map<Id, Lead> oldLeadMap) {
        
        Map<String, Lead_Company_Owner_Mapping_CC__mdt> mappings = getCompanyMappings();
        String profileName = [ SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId() WITH SYSTEM_MODE].Profile.Name;
        for (Lead leadRecord : leads) {
            // System.debug('### leadRecord.Company '+ leadRecord.Company);
            // System.debug('### mappings.get(leadRecord.Company) '+ mappings.get(leadRecord.Company));
            
            if(leadRecord.status == 'Identify' && profileName != 'Carlton Sales User' &&
                (
                (oldLeadMap == NULL && leadRecord.ownerId != NULL) ||
                (oldLeadMap != NULL && leadRecord.ownerId != NULL && leadRecord.Company != oldLeadMap.get(leadRecord.Id).Company && mappings.get(leadRecord.Company)!=NULL)
                )
            ) {
                // System.debug('### Big If ');
                if(mappings.get(leadRecord.Company)!=NULL && mappings.get(leadRecord.Company).Owner_Id_CC__c != NULL) {
                    // System.debug('### Big If 1.a');
                    leadRecord.ownerId = mappings.get(leadRecord.Company).Owner_Id_CC__c;
                    // System.debug('### Big If 1');
                } else if(mappings.get(leadRecord.Belongs_To_CC__c)!=NULL && mappings.get(leadRecord.Belongs_To_CC__c).Owner_Id_CC__c != NULL) {
                    // System.debug('### Big If 2.a');
                    leadRecord.ownerId = mappings.get(leadRecord.Belongs_To_CC__c).Owner_Id_CC__c;
                    // System.debug('### Big If 2');
                }
            }
            
        }
        
    }
    
    private static Map<String, Lead_Company_Owner_Mapping_CC__mdt> getCompanyMappings() {
        Map<String, Lead_Company_Owner_Mapping_CC__mdt> mappings = new Map<String, Lead_Company_Owner_Mapping_CC__mdt>();
        for (Lead_Company_Owner_Mapping_CC__mdt mapping : [SELECT DeveloperName,MasterLabel,Company_Name_CC__c,Entity_CC__c,Owner_Id_CC__c,Active_CC__c
                                                     FROM Lead_Company_Owner_Mapping_CC__mdt WITH SYSTEM_MODE ]) {
            if ((mapping.Company_Name_CC__c)!= NULL && mapping.Active_CC__c) {
                mappings.put(mapping.Company_Name_CC__c,mapping);
            } else if((mapping.Entity_CC__c)!= NULL && mapping.Active_CC__c) {
                mappings.put(mapping.Entity_CC__c,mapping);
            }
        }
        // System.debug('### mappings '+mappings);
        return mappings;
    }
    
    public static void stampLastMarketingOwner(List<Lead> leads,Map<Id, Lead> oldLeadMap) {
        Set<Id> ownerIds = new Set<Id>();
        for (Lead leadRecord : leads) {
            if (isUserId(leadRecord.OwnerId)) {
                ownerIds.add(leadRecord.OwnerId);
            }
            if (oldLeadMap != NULL && oldLeadMap.get(leadRecord.Id) != NULL && isUserId(oldLeadMap.get(leadRecord.Id).OwnerId)) {
                ownerIds.add(oldLeadMap.get(leadRecord.Id).OwnerId);
            }
        }
        Set<Id> marketingUsers = getMarketingUsers(ownerIds);
        if (!marketingUsers.isEmpty()) {
            for (Lead leadRecord : leads) {
                Lead oldLead = (oldLeadMap == NULL) ? NULL : oldLeadMap.get(leadRecord.Id);
                if (marketingUsers.contains(leadRecord.OwnerId)) {
                    leadRecord.Last_Marketing_Owner_Id_CC__c = String.valueOf(leadRecord.OwnerId);
                } else if (oldLead != NULL && marketingUsers.contains(oldLead.OwnerId)) {
                    leadRecord.Last_Marketing_Owner_Id_CC__c = String.valueOf(oldLead.OwnerId);
                }
            }
        }
    }
    
    public static void assignOwnerOnReNurture(List<Lead> leads, Map<Id, Lead> oldLeadMap) {
        if (transferQueued || leads == NULL || oldLeadMap == NULL) {
            return;
        }
        Map<Id, Id> previousOwnerByLeadId = new Map<Id, Id>();
    
        for (Lead leadRecord : leads) {
            Lead oldLead = oldLeadMap.get(leadRecord.Id);
            if (oldLead == NULL || leadRecord.Status != 'Re-Nurture' || oldLead.Status == 'Re-Nurture') {
                continue;
            }
            if (isUserId(leadRecord.OwnerId)) {
                previousOwnerByLeadId.put(leadRecord.Id, leadRecord.OwnerId);
            }
        }
    
        if (!previousOwnerByLeadId.isEmpty()) {
            transferQueued = true;
            System.enqueueJob(new ChangeOwnerOnReNurture_CC(previousOwnerByLeadId));
        }
    }
    
    private static Set<Id> getMarketingUsers(Set<Id> userIds) {
        Set<Id> marketingUsers = new Set<Id>();
        if (userIds == NULL || userIds.isEmpty()) {
            return marketingUsers;
        }
        for (User userRecord : [SELECT Id FROM User WHERE Id IN :userIds AND IsActive = TRUE AND Profile.Name = 'Carlton Marketing User' WITH SYSTEM_MODE]) {
            marketingUsers.add(userRecord.Id);
        }
        return marketingUsers;
    }
    
    private static Map<String, Id> getQueues() {
        if (queueIdsByName == NULL) {
            queueIdsByName = new Map<String, Id>();
            for (Group queueRecord : [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND DeveloperName IN ('UK_Marketing_Pool', 'US_Marketing_Pool') WITH SYSTEM_MODE]) {
                queueIdsByName.put(queueRecord.DeveloperName, queueRecord.Id);
            }
        }
        return queueIdsByName;
    }
    
    private static Boolean isUserId(Id ownerId) {
        return ownerId != NULL && ownerId.getSObjectType() == User.SObjectType;
    }
    
    private static Id toUserId(String value) {
        if (String.isBlank(value) || !value.trim().startsWith('005')) {
            return NULL;
        }
        try {
            return Id.valueOf(value.trim());
        } catch (Exception ex) {
            return NULL;
        }
    }
    
    @future
    public static void resetBypassDuplicateRules(List<Id> leadIds) {
        System.debug('### leadIds '+leadIds);
        List<Lead> leadsToUpdate = [ SELECT Id, Bypass_Duplicate_Rules_on_Import_CC__c 
                              FROM Lead WHERE Id IN :leadIds AND Bypass_Duplicate_Rules_on_Import_CC__c = true WITH SYSTEM_MODE];
        for (Lead ld : leadsToUpdate) {
            ld.Bypass_Duplicate_Rules_on_Import_CC__c = false;
        }
        System.debug('### leadsToUpdate '+leadsToUpdate);
        if(!leadsToUpdate.isEmpty()) {
            Database.update(leadsToUpdate, false);
        }
        
    }
    
    public static void captureQualifyDate(List<Lead> leads,Map<Id,Lead> oldLeadMap){
    for(Lead leadRecord:leads){
        Lead oldLead=oldLeadMap.get(leadRecord.Id);
        if(oldLead!=null&&oldLead.Status!='Qualify'&&leadRecord.Status=='Qualify'&&leadRecord.Qualified_Date_CC__c==null){
            leadRecord.Qualified_Date_CC__c=Datetime.now();
        } }
	}
    
    public static void raiseValidationOnOwnerChange(List<Lead> leadNew, Map<Id,Lead> leadOldMap) {
        Set<Id> userOwnerIds=new Set<Id>();
        Set<Id> queueOwnerIds=new Set<Id>();
        
        for(Lead ld:leadNew){
            Lead oldLd=leadOldMap.get(ld.Id);
            
            if(ld.OwnerId!=null){
                if(ld.OwnerId.getSObjectType()==User.SObjectType) userOwnerIds.add(ld.OwnerId);
                else if(ld.OwnerId.getSObjectType()==Group.SObjectType) queueOwnerIds.add(ld.OwnerId);
            }
            
            if(oldLd!=null&&oldLd.OwnerId!=null){
                if(oldLd.OwnerId.getSObjectType()==User.SObjectType) userOwnerIds.add(oldLd.OwnerId);
                else if(oldLd.OwnerId.getSObjectType()==Group.SObjectType) queueOwnerIds.add(oldLd.OwnerId);
            }
        }
        
        String currentUserProfileName=[SELECT Name FROM Profile WHERE Id=:UserInfo.getProfileId() WITH SYSTEM_MODE].Name;
        Id currentUserId=UserInfo.getUserId();
        
        Map<Id,User> userMap=userOwnerIds.isEmpty()?new Map<Id,User>():new Map<Id,User>([ SELECT Id,Profile.Name FROM User WHERE Id IN :userOwnerIds WITH SYSTEM_MODE]);
        
        Map<Id,Group> queueMap=queueOwnerIds.isEmpty()?new Map<Id,Group>():new Map<Id,Group>([SELECT Id,DeveloperName FROM Group WHERE Id IN :queueOwnerIds AND Type='Queue' AND DeveloperName IN ('UK_Marketing_Pool','US_Marketing_Pool','UK_Sales_Pool','US_Sales_Pool') WITH SYSTEM_MODE]);
        Map<Id,Set<String>> userQueueMemberships=new Map<Id,Set<String>>();
        
        if(!userOwnerIds.isEmpty()){
            for(GroupMember gm:[SELECT GroupId,UserOrGroupId,Group.DeveloperName FROM GroupMember WHERE UserOrGroupId IN :userOwnerIds AND Group.DeveloperName IN ('UK_Marketing_Pool','US_Marketing_Pool','UK_Sales_Pool','US_Sales_Pool') WITH SYSTEM_MODE]){
                if(!userQueueMemberships.containsKey(gm.UserOrGroupId)){
                    userQueueMemberships.put(gm.UserOrGroupId,new Set<String>());
                }
                userQueueMemberships.get(gm.UserOrGroupId).add(gm.Group.DeveloperName);
            }
        }
        
        for(Lead ld:leadNew){
            Lead oldLd=leadOldMap.get(ld.Id);
            
            if(oldLd==null||ld.OwnerId==null||ld.OwnerId==oldLd.OwnerId||currentUserProfileName!='Carlton Marketing User') continue;
            
            Boolean isUS=ld.Belongs_To_CC__c=='Carlton Packaging INC';
            Boolean isUK=ld.Belongs_To_CC__c=='Carlton Packaging LLP';
            
            if(queueMap.containsKey(oldLd.OwnerId)&&userMap.containsKey(ld.OwnerId)&&ld.OwnerId==currentUserId){
                String oldQueue=queueMap.get(oldLd.OwnerId).DeveloperName;
                
                if(oldQueue=='US_Marketing_Pool'||oldQueue=='UK_Marketing_Pool'){
                    continue;
                }
            }
            
            if(queueMap.containsKey(ld.OwnerId)){
                String queueName=queueMap.get(ld.OwnerId).DeveloperName;
                
                if(queueName=='US_Marketing_Pool'||queueName=='UK_Marketing_Pool'){
                    Boolean validMarketingQueue=(isUS&&queueName=='US_Marketing_Pool')||(isUK&&queueName=='UK_Marketing_Pool');
                    
                    if(!validMarketingQueue){
                        ld.addError('A Lead can only be assigned to the Marketing Pool corresponding to its entity.');
                    }
                }else if(queueName=='US_Sales_Pool'||queueName=='UK_Sales_Pool'){
                    if(ld.Status!='Engage'){
                        ld.addError('A Lead can only be reassigned to Sales once it has been Engaged by Marketing.');
                        continue;
                    }
                    
                    Boolean validSalesQueue=(isUS&&queueName=='US_Sales_Pool')||(isUK&&queueName=='UK_Sales_Pool');
                    
                    if(!validSalesQueue){
                        if(isUS) ld.addError('Leads belonging to Carlton Packaging INC can only be assigned to the US Sales Pool.');
                        else if(isUK) ld.addError('Leads belonging to Carlton Packaging LLP can only be assigned to the UK Sales Pool.');
                    }
                }
            }else if(userMap.containsKey(ld.OwnerId)){
                User targetUser=userMap.get(ld.OwnerId);
                
                if(targetUser.Profile.Name=='Carlton Sales User'){
                    if(ld.Status!='Engage'){
                        ld.addError('A Lead can only be reassigned to Sales once it has been Engaged by Marketing.');
                        continue;
                    }
                    
                    Set<String> targetOwnerQueues=userQueueMemberships.get(ld.OwnerId);
                    Boolean validAssignment=targetOwnerQueues!=null&&(
                        (isUS&&targetOwnerQueues.contains('US_Sales_Pool'))||
                        (isUK&&targetOwnerQueues.contains('UK_Sales_Pool'))
                        );
                    
                    if(!validAssignment){
                        ld.addError('A Marketing User can only reassign a Lead to a Sales User from the corresponding regional Sales Pool.');
                    }
                }else if(targetUser.Profile.Name=='Carlton Marketing User'){
                    Set<String> targetOwnerQueues=userQueueMemberships.get(ld.OwnerId);
                    Boolean validAssignment=targetOwnerQueues!=null&&(
                        (isUS&&targetOwnerQueues.contains('US_Marketing_Pool'))||
                        (isUK&&targetOwnerQueues.contains('UK_Marketing_Pool'))
                        );
                    
                    if(!validAssignment){
                        ld.addError('A Marketing User can only reassign a Lead to a Marketing User from the corresponding regional Marketing Pool.');
                    }
                }
            }
        }
    }
    public static void notifyRoleManagerOnDuplicateLead(List<Lead> newLeads) {
        if (newLeads == NULL || newLeads.isEmpty()) {
            return;
        }

        List<CustomNotificationType> notificationTypes = [SELECT Id FROM CustomNotificationType
                                                          WHERE DeveloperName = 'Duplicate_Lead_Alert_CC'
                                                          WITH SYSTEM_MODE LIMIT 1];
        if (notificationTypes.isEmpty()) {
            System.debug(LoggingLevel.ERROR, '### Custom Notification Type Duplicate_Lead_Alert_CC not found.');
            return;
        }

        // 1. Find which new Leads are duplicates (FindDuplicates accepts max 50 records per call)
        Map<Id, String> ruleNameByLeadId = new Map<Id, String>();
        List<Lead> chunk = new List<Lead>();
        for (Integer i = 0; i < newLeads.size(); i++) {
            chunk.add(newLeads[i]);
            if (chunk.size() == 50 || i == newLeads.size() - 1) {
                List<Datacloud.FindDuplicatesResult> results = Datacloud.FindDuplicates.findDuplicates(chunk);
                for (Integer j = 0; j < chunk.size(); j++) {
                    Lead currentLead = chunk[j];
                    for (Datacloud.DuplicateResult dupResult : results[j].getDuplicateResults()) {
                        for (Datacloud.MatchResult matchResult : dupResult.getMatchResults()) {
                            for (Datacloud.MatchRecord matchRecord : matchResult.getMatchRecords()) {
                                // Ignore the Lead matching itself
                                if (matchRecord.getRecord() != NULL && matchRecord.getRecord().Id != currentLead.Id
                                    && !ruleNameByLeadId.containsKey(currentLead.Id)) {
                                    ruleNameByLeadId.put(currentLead.Id, dupResult.getDuplicateRule());
                                }
                            }
                        }
                    }
                }
                chunk = new List<Lead>();
            }
        }
        if (ruleNameByLeadId.isEmpty()) {
            return;
        }

        // 2. Get the creators and their parent roles
        Set<Id> creatorIds = new Set<Id>();
        for (Lead ld : newLeads) {
            if (ruleNameByLeadId.containsKey(ld.Id) && ld.CreatedById != NULL) {
                creatorIds.add(ld.CreatedById);
            }
        }
        Map<Id, User> creatorsById = new Map<Id, User>([SELECT Id, Name, UserRoleId, UserRole.ParentRoleId
                                                        FROM User WHERE Id IN :creatorIds WITH SYSTEM_MODE]);
        Set<Id> parentRoleIds = new Set<Id>();
        for (User creator : creatorsById.values()) {
            if (creator.UserRoleId != NULL && creator.UserRole.ParentRoleId != NULL) {
                parentRoleIds.add(creator.UserRole.ParentRoleId);
            }
        }
        if (parentRoleIds.isEmpty()) {
            return;
        }

        // 3. First active user in each parent role (oldest user first, so the pick is consistent)
        Map<Id, Id> recipientIdByRoleId = new Map<Id, Id>();
        for (User roleUser : [SELECT Id, UserRoleId FROM User
                              WHERE UserRoleId IN :parentRoleIds AND IsActive = TRUE AND UserType = 'Standard'
                              WITH SYSTEM_MODE
                              ORDER BY CreatedDate ASC, Id ASC]) {
            if (!recipientIdByRoleId.containsKey(roleUser.UserRoleId)) {
                recipientIdByRoleId.put(roleUser.UserRoleId, roleUser.Id);
            }
        }

        // 4. Send one notification per duplicate Lead
        for (Lead ld : newLeads) {
            if (!ruleNameByLeadId.containsKey(ld.Id)) {
                continue;
            }
            User creator = creatorsById.get(ld.CreatedById);
            if (creator == NULL || creator.UserRoleId == NULL || creator.UserRole.ParentRoleId == NULL) {
                continue;
            }
            Id recipientId = recipientIdByRoleId.get(creator.UserRole.ParentRoleId);
            if (recipientId == NULL) {
                continue;
            }
            String leadName = ((String.isBlank(ld.FirstName) ? '' : ld.FirstName + ' ') + (ld.LastName == NULL ? '' : ld.LastName)).trim();
            if (String.isBlank(leadName)) {
                leadName = 'Lead';
            }
            String body = 'Hi ' + creator.Name + ',\n\n' +
                'A new Lead has been created even though a potential duplicate was identified during Lead creation.\n\n' +
                'Key Details:\n' +
                '• New Lead: ' + (String.isBlank(ld.Company) ? 'Not specified' : ld.Company) + '\n' +
                '• Potential Matching Lead: ' + leadName + '\n' +
                '• Product Category: ' + (String.isBlank(ld.Product_Category_CC__c) ? 'Not specified' : ld.Product_Category_CC__c) + '\n' +
                '• Lead Owner: ' + creator.Name + '\n\n' +
                'Please review the Lead records in Salesforce and determine whether any further action is required.\n' +
                'Salesforce Record: Open the Lead notification to review the record.';
            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(notificationTypes[0].Id);
            notification.setTargetId(ld.Id);
            notification.setTitle('Potential Duplicate Lead');
            notification.setBody(body.left(750));
            
            try {
                notification.send(new Set<String>{ String.valueOf(recipientId) });
            } catch (Exception ex) {
                System.debug(LoggingLevel.ERROR, '### Duplicate Lead notification failed for Lead ' + ld.Id + ': ' + ex.getMessage());
            }
        }
    }
    
}