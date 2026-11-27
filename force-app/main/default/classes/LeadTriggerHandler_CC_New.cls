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
 * 3          28/10/2026   Aaron Blackledge   Field-driven stages via LeadStageTransitionService_CC;
 *                                            duplicate checkpoint moved from Qualify to Engage
 * 4          29/10/2026   Aaron Blackledge   Initial Next Step set on insert (beforeInsert)
 * 5          12/11/2026   Vansh Mansotra     Active Lead validation rules migrated to Apex
 *                                            (validateLeadStageGates, before insert / before update)
 * 6          12/11/2026   Vansh Mansotra     Stage gates moved to custom metadata (Lead_Stage_CC__mdt,
 *                                            Lead_Stage_Field_CC__mdt); remaining rules as plain if statements
 * 7          19/11/2026   Vansh Mansotra     Automatic advancement on insert (Identify -> Qualify when complete) and
 *                                            Qualified Date stamped on insert
 * 8          20/11/2026   Vansh Mansotra     Duplicate checkpoint moved from Engage to Qualified (CP27)
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
        // After owner routing (it reads the Identify status): a Lead created with every Qualify field filled starts at Qualify.
        LeadStageTransitionService_CC.applyOnInsert((List<Lead>) Trigger.new);
        captureQualifyDate((List<Lead>) Trigger.new, null);
        // After owner routing and advancement, so the initial Next Step reflects the routed owner and the final stage.
        LeadStageTransitionService_CC.setInitialProgressMessages((List<Lead>) Trigger.new);
        // Last, so the stage gates see the final values to be saved (validation rules run after before-triggers).
        validateLeadStageGates((List<Lead>) Trigger.new, null);
    }

    public override void beforeUpdate(){
        Map<Id, Lead> oldLeadMap = (Map<Id, Lead>) Trigger.oldMap;
        // Sort first: Email_List_CC__c and Product_Category_Text_CC__c feed the duplicate matching rule.
        sortProductCategories((List<Lead>) Trigger.new,(Map<Id, Lead>) Trigger.oldMap);
        sortEmailValues((List<Lead>) Trigger.new,(Map<Id, Lead>) Trigger.oldMap);
        // Owner mapping reads the incoming Identify status, so it runs before any automatic stage change.
        applyCompanyOwnerMapping((List<Lead>) Trigger.new, (Map<Id, Lead>)Trigger.oldMap);
        stampLastMarketingOwner((List<Lead>) Trigger.new, (Map<Id, Lead>) Trigger.oldMap);
        // Field-driven stage changes and the duplicate checkpoint on entry to Qualified (previously on entry to Engage).
        LeadStageTransitionService_CC.apply((List<Lead>) Trigger.new, oldLeadMap);
        captureQualifyDate((List<Lead>)Trigger.new,oldLeadMap);
        raiseValidationOnOwnerChange((List<Lead>) Trigger.new, (Map<Id, Lead>) Trigger.oldMap);
        // Last, so the stage gates see automatic stage changes made above (validation rules run after before-triggers).
        validateLeadStageGates((List<Lead>) Trigger.new, oldLeadMap);
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

        ZoomInfoMappingBatch_CC.processInsertedRecords('Lead', (List<Lead>) Trigger.new);
    }
        
    public override void afterUpdate() {
        Map<Id, Lead> oldLeadMap = (Map<Id, Lead>) Trigger.oldMap;
        Set<Id> leadIds = new Set<Id>();
        List<Guidance_Refresh_CC__e> guidanceEvents = new List<Guidance_Refresh_CC__e>();

        for (Lead newLead : (List<Lead>) Trigger.new) {
            Lead oldLead = oldLeadMap.get(newLead.Id);

            if (oldLead != null && newLead.OwnerId != oldLead.OwnerId) {
                leadIds.add(newLead.Id);
            }
            
            if(oldLead != NULL & newLead.Status != oldLead.Status) {
                guidanceEvents.add(new Guidance_Refresh_CC__e(
                    Record_Id_CC__c = String.valueOf(newLead.Id),
                    Object_API_Name_CC__c = 'Lead'
                ));
            }
        }

        if (!guidanceEvents.isEmpty()) {
            EventBus.publish(guidanceEvents);
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
            
            if(leadRecord.status == 'Identify' && profileName != 'Carlton Sales User' && profileName != 'Carlton Internal Account Manager' &&
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
    
    /**
     * Stamps Qualified_Date_CC__c when a Lead enters Qualify: on update, or on insert (oldLeadMap null) only when
     * automatic advancement on insert moved it there (a Lead created at Qualify directly is not stamped, as before).
     */
    public static void captureQualifyDate(List<Lead> leads,Map<Id,Lead> oldLeadMap){
        for(Lead leadRecord:leads){
            Lead oldLead=oldLeadMap==null?null:oldLeadMap.get(leadRecord.Id);
            Boolean enteredQualify=leadRecord.Status=='Qualify'&&(oldLeadMap==null
                ?LeadStageTransitionService_CC.wasAdvancedOnInsert(leadRecord)
                :(oldLead!=null&&oldLead.Status!='Qualify'));
            if(enteredQualify&&leadRecord.Qualified_Date_CC__c==null){
                leadRecord.Qualified_Date_CC__c=Datetime.now();
            }
        }
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
                List<Datacloud.FindDuplicatesResult> results;
                try {
                    results = Datacloud.FindDuplicates.findDuplicates(chunk);
                } catch (System.HandledException e) {
                    // Thrown when no Lead duplicate rule is active. The alert is optional, so the Lead still saves.
                    System.debug(LoggingLevel.WARN, '### Duplicate Lead alert skipped: ' + e.getMessage());
                    return;
                }
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
        Map<Id, User> recipientsById = new Map<Id, User>();
        for (User roleUser : [SELECT Id, UserRoleId, Name FROM User
                              WHERE UserRoleId IN :parentRoleIds AND IsActive = TRUE AND UserType = 'Standard'
                              WITH SYSTEM_MODE
                              ORDER BY CreatedDate ASC, Id ASC]) {
            if (!recipientIdByRoleId.containsKey(roleUser.UserRoleId)) {
                recipientIdByRoleId.put(roleUser.UserRoleId, roleUser.Id);
                recipientsById.put(roleUser.Id, roleUser);
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
            User recipient = recipientsById.get(recipientId);
            
            if (recipientId == NULL) {
                continue;
            }
            String leadName = ((String.isBlank(ld.FirstName) ? '' : ld.FirstName + ' ') + (ld.LastName == NULL ? '' : ld.LastName)).trim();
            if (String.isBlank(leadName)) {
                leadName = 'Lead';
            }
            String body = 'Hi ' + recipient.Name + ',\n\n' +
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

    // =============================================================================================================
    // LEAD VALIDATIONS
    // =============================================================================================================
    // 1. Required fields per stage come from custom metadata, read through LeadStageTransitionService_CC:
    //      Lead_Stage_CC__mdt        the stages (order, Path / Exit)
    //      Lead_Stage_Field_CC__mdt  the fields required at each stage
    //    A Path stage (Identify -> Qualify -> Engage -> Qualified) also requires the fields of every earlier Path
    //    stage. Disqualified and Re-Nurture (Exit stages) require only their own fields.
    //    To add, change or remove a required field, edit the metadata: no code change is needed.
    // 2. Rules that are not "field is required" checks follow as plain if statements, each tagged with the
    //    validation rule it replaced.
    // Exempt: System Administrator profile and the Trigger_Framework_Config_CC__mdt Lead bypass, unless a rule
    // says otherwise.
    // =============================================================================================================

    private static final String PROFILE_SYSTEM_ADMIN = 'System Administrator';
    private static final String PROFILE_MARKETING_USER = 'Carlton Marketing User';
    private static final String PERMISSION_SALES_USER = 'Sales_User_Permission_CC';
    private static final String MEETING_OUTCOME_QUALIFIED = LeadStageTransitionService_CC.MEETING_OUTCOME_QUALIFIED;
    private static final String ACCOUNT_RECORD_TYPE_ENTITY = 'Entity';
    private static final Integer PHONE_MAX_LENGTH = 15;

    private static final String MSG_PLACEHOLDER_STAGE = 'Identify the contact first: replace the "Needs to Identify" placeholder with the contact\'s real name before moving this Lead beyond Identify.';
    private static final String MSG_IDENTIFY_STATUS = 'New Leads must be created with a Status of \'Identify\'. Please update the Status field before saving.';
    private static final String MSG_MARKETING_SKIP = 'Marketing team members cannot skip Qualify Stage';
    private static final String MSG_PROGRESSION = 'Only sales users and admins can move the status';
    private static final String MSG_QUALIFIED_FROM_ENGAGE = 'A Lead can only be marked as Qualified when its previous status is Engage.';
    private static final String MSG_BACKTRACKING = 'Lead Status cannot be moved backwards. Please move the Lead forward through the qualification process.';
    private static final String MSG_DISQUALIFICATION_STAGE = 'Lead can only be moved to Disqualified from Qualify or Engage status, or from Identify while the contact is still unidentified.';
    private static final String MSG_DISQUALIFIED_LOCK = 'Disqualified leads can not be edited/reopened';
    private static final String MSG_RE_NURTURE_STATUS = 'Lead can only be moved to Re-Nurture from Engage status.';
    private static final String MSG_ACCOUNT_RECORD_TYPE = 'Account does not belong to Entity Record Type.';
    private static final String MSG_MOBILE_LENGTH = 'Mobile number cannot be greater than 15 characters';
    private static final String MSG_PHONE_LENGTH = 'Phone Number cannot be greater than 15 Characters';
    private static final String MSG_CONVERSION = 'Only Sales Qualified leads can be converted: record Meeting Outcome Qualified at Engage first.';
    private static final String MSG_PLACEHOLDER_CONVERSION = 'This Lead still has the placeholder contact name "Needs to Identify". Enter the contact\'s real First and Last Name before converting.';

    private static Map<Id, String> cachedProfileNameByUser = new Map<Id, String>();

    /**
     * Lead validations. Runs last in before insert and before update, so it checks the final values, including the
     * automatic stage change made by LeadStageTransitionService_CC.
     * Bulk-safe: one Profile query (cached) and one Account query per call; metadata queries do not count; no DML.
     * @param newList Trigger.new
     * @param oldMap  Trigger.oldMap (null on insert)
     */
    public static void validateLeadStageGates(List<Lead> newList, Map<Id, Lead> oldMap) {
        if (newList == null || newList.isEmpty()) {
            return;
        }

        // Running user: the same for every Lead in the batch.
        String profileName = getRunningProfileName();
        Boolean isMarketingUser = profileName == PROFILE_MARKETING_USER;
        Boolean bypassValidation = isValidationBypassed();
        Boolean exempt = profileName == PROFILE_SYSTEM_ADMIN || bypassValidation;
        Boolean isSalesUser = FeatureManagement.checkPermission(PERMISSION_SALES_USER);
        Map<Id, String> accountRecordTypes = exempt ? new Map<Id, String>() : getAccountRecordTypes(newList);

        // Stage names come from the stage metadata (Lead_Stage_CC__mdt).
        String identify = LeadStageTransitionService_CC.STATUS_IDENTIFY;
        String qualify = LeadStageTransitionService_CC.STATUS_QUALIFY;
        String engage = LeadStageTransitionService_CC.STATUS_ENGAGE;
        String qualified = LeadStageTransitionService_CC.STATUS_QUALIFIED;
        String disqualified = LeadStageTransitionService_CC.STATUS_DISQUALIFIED;
        String reNurture = LeadStageTransitionService_CC.STATUS_RE_NURTURE;

        for (Lead lead : newList) {
            Lead oldLead = (oldMap == null || lead.Id == null) ? null : oldMap.get(lead.Id);
            Boolean isNew = oldLead == null;
            String status = lead.Status;
            String priorStatus = isNew ? lead.Status : oldLead.Status; // PRIORVALUE() returns the current value on insert
            Boolean statusChanged = !isNew && status != priorStatus;
            Boolean placeholderName = LeadStageTransitionService_CC.isPlaceholderName(lead);

            // -----------------------------------------------------------------------------------------------------
            // 1. REQUIRED FIELDS PER STAGE (metadata: Lead_Stage_Field_CC__mdt)
            //    Replaces: Address_Base_Validation_CC, First_Name_Validation, Contact_Method_Validation,
            //    Title_Engage_Gate_CC, Lead_Type_Required_for_Qualified_Lead_CC, Qualification_Criteria_Gate_CC,
            //    Company_Registration_No_Qualified_Gate, Existing_Account_Required_for_Site_CC,
            //    First_Sales_Appointment_Engage_Gate_CC, Sales_Appointment_booked_Engage_Gate_CC,
            //    LeadQualify_ProductCategoryValidation_CC, Product_Category_Qualified_Gate_CC,
            //    Meeting_Outcome_Qualified_Gate_CC, Lead_Account_Questions_Qualified_Gate_CC,
            //    Lead_Bespoke_Over_20_Percent_CC, Lead_Core_Category_Min_Qty_CC, Lead_Tender_Exclusive_Pricing_CC,
            //    Qualified_Lead_Opportunity_Value_Require, Lead_Source_Other_Validation_CC,
            //    Trade_Show_Expo_Name_Validation_CC, Disqualification_Validation_CC, ReNurturing_Validation_CC,
            //    Re_Engagement_Date_ReNurture_Gate_CC
            // -----------------------------------------------------------------------------------------------------
            if (!exempt) {
                for (Lead_Stage_Field_CC__mdt rule : LeadStageTransitionService_CC.requiredFieldsFor(status)) {
                    if (!LeadStageTransitionService_CC.isRequirementMet(lead, rule)) {
                        addLeadError(lead, LeadStageTransitionService_CC.errorFieldOf(rule), rule.Error_Message_CC__c);
                    }
                }
            }

            // -----------------------------------------------------------------------------------------------------
            // 2. STATUS RULES
            // -----------------------------------------------------------------------------------------------------

            // Validation Rule: Placeholder_Name_Stage_Block_CC
            // A Lead whose contact is still "Needs to Identify" cannot be created at, moved to, or have its Last Name
            // edited at a stage after Identify. Exempt: nobody (as the original rule).
            Boolean lastNameChanged = !isNew && lead.LastName != oldLead.LastName;
            if (placeholderName && LeadStageTransitionService_CC.isLaterPathStage(status, identify)
                && (isNew || statusChanged || lastNameChanged)) {
                addLeadError(lead, 'LastName', MSG_PLACEHOLDER_STAGE);
            }

            // Validation Rule: Identify_Status_Validation_CC
            // A Marketing user must create Leads at Identify. A Lead moved to Qualify by automatic advancement on
            // insert (LeadStageTransitionService_CC.applyOnInsert) was created at Identify, so it passes.
            if (isNew && status != identify && isMarketingUser && !exempt
                && !LeadStageTransitionService_CC.wasAdvancedOnInsert(lead)) {
                addLeadError(lead, 'Status', MSG_IDENTIFY_STATUS);
            }

            // Validation Rule: Marketing_User_Validation
            // A Marketing user moving a Lead out of Identify can only move it to Qualify or Disqualified (Disqualified
            // from Identify is still limited by Disqualification_Stage_Validation_CC below). Exempt: nobody (the
            // bypass does not apply, as the original rule).
            if (isMarketingUser && statusChanged && priorStatus == identify && status != qualify
                && status != disqualified) {
                addLeadError(lead, null, MSG_MARKETING_SKIP);
            }

            // Validation Rule: Lead_Progression_Validation_CC
            // Only Sales users (Sales_User_Permission_CC) can move a Lead to Qualified or Re-Nurture. Disqualified is
            // not restricted here, so Marketing users can disqualify (stage rules below still apply).
            if (statusChanged && (status == qualified || status == reNurture)
                && !exempt && !isSalesUser) {
                addLeadError(lead, null, MSG_PROGRESSION);
            }

            // Validation Rule: Lead_Qualified_Validation_CC
            // Qualified can only be entered from Engage (moves out of Disqualified are not checked).
            if (statusChanged && status == qualified && priorStatus != engage && priorStatus != disqualified
                && !exempt) {
                addLeadError(lead, 'Status', MSG_QUALIFIED_FROM_ENGAGE);
            }

            // Validation Rule: Lead_Status_Backtracking_Validation_CC
            // Status cannot move to a lower Stage Order (metadata). Moves out of Disqualified or Re-Nurture are not
            // checked.
            if (statusChanged && priorStatus != disqualified && priorStatus != reNurture && !exempt
                && LeadStageTransitionService_CC.stageOrder(status) < LeadStageTransitionService_CC.stageOrder(priorStatus)) {
                addLeadError(lead, null, MSG_BACKTRACKING);
            }

            // Validation Rule: Disqualification_Stage_Validation_CC
            // Disqualified can only be entered from Qualify or Engage; from Identify only while the contact is the
            // placeholder, or through the Disqualify action (Disqualified_By_Pilot_Action_CC__c set in this save).
            if (statusChanged && status == disqualified && priorStatus != qualify && priorStatus != engage && !exempt) {
                Boolean fromIdentifyWithPlaceholder = priorStatus == identify && placeholderName;
                Boolean fromIdentifyByDisqualifyAction = priorStatus == identify
                    && lead.Disqualified_By_Pilot_Action_CC__c == true
                    && oldLead.Disqualified_By_Pilot_Action_CC__c != true;
                if (!fromIdentifyWithPlaceholder && !fromIdentifyByDisqualifyAction) {
                    addLeadError(lead, 'Status', MSG_DISQUALIFICATION_STAGE);
                }
            }

            // Validation Rule: Disqualified_Stage_Lock_CC
            // A Disqualified Lead can be neither reopened nor edited (this also blocks inserting at Disqualified).
            if (priorStatus == disqualified && !exempt) {
                addLeadError(lead, null, MSG_DISQUALIFIED_LOCK);
            }

            // Validation Rule: ReNurture_status_validation_CC
            // Re-Nurture can only be entered from Engage.
            if (statusChanged && status == reNurture && priorStatus != engage && !exempt) {
                addLeadError(lead, 'Status', MSG_RE_NURTURE_STATUS);
            }

            // -----------------------------------------------------------------------------------------------------
            // 3. FIELD RULES (every status)
            // -----------------------------------------------------------------------------------------------------

            // Validation Rule: Lead_Account_Must_Be_Site_CC
            // Entity Associated must be an Account of the Entity record type.
            if (lead.Entity_Associated_CC__c != null && !exempt
                && accountRecordTypes.get(lead.Entity_Associated_CC__c) != ACCOUNT_RECORD_TYPE_ENTITY) {
                addLeadError(lead, 'Entity_Associated_CC__c', MSG_ACCOUNT_RECORD_TYPE);
            }

            // Validation Rule: Mobile_Character_Limit_Validation
            if (lead.MobilePhone != null && lead.MobilePhone.length() > PHONE_MAX_LENGTH && !exempt) {
                addLeadError(lead, 'MobilePhone', MSG_MOBILE_LENGTH);
            }

            // Validation Rule: Phone_Character_Limit_Validation
            if (lead.Phone != null && lead.Phone.length() > PHONE_MAX_LENGTH && !exempt) {
                addLeadError(lead, 'Phone', MSG_PHONE_LENGTH);
            }

            // -----------------------------------------------------------------------------------------------------
            // 4. CONVERSION RULES (Lead Settings "Require Validation for Converted Leads" is on)
            // -----------------------------------------------------------------------------------------------------

            // Validation Rule: Lead_conversion_validation
            // Only a Lead that was Qualified, or at Engage with Meeting Outcome "Qualified", can be converted.
            // Exempt: the bypass only (System Administrators are not exempt, as the original rule).
            if (lead.IsConverted == true && !bypassValidation && priorStatus != qualified
                && !(priorStatus == engage && lead.Meeting_Outcome_CC__c == MEETING_OUTCOME_QUALIFIED)) {
                addLeadError(lead, null, MSG_CONVERSION);
            }

            // Validation Rule: Placeholder_Name_Conversion_Block_CC
            // A Lead whose contact is still "Needs to Identify" cannot be converted. Exempt: nobody.
            if (lead.IsConverted == true && placeholderName) {
                addLeadError(lead, 'LastName', MSG_PLACEHOLDER_CONVERSION);
            }
        }
    }

    /**
     * Adds an error to a field (or to the record when fieldName is null). A Lead keeps one error per field, so a
     * message already on the same field is kept in front instead of being replaced.
     */
    private static void addLeadError(Lead lead, String fieldName, String message) {
        for (Database.Error existing : lead.getErrors()) {
            List<String> fields = existing.getFields();
            Boolean recordLevel = fields == null || fields.isEmpty();
            Boolean sameLocation = fieldName == null ? recordLevel : (!recordLevel && fields.contains(fieldName));
            if (sameLocation) {
                if (existing.getMessage().contains(message)) {
                    return;
                }
                message = existing.getMessage() + ' | ' + message;
                break;
            }
        }
        if (fieldName == null) {
            lead.addError(message);
        } else {
            lead.addError(fieldName, message);
        }
    }

    /** Profile name of the running user, cached per user (System.runAs can switch user inside one transaction). */
    private static String getRunningProfileName() {
        Id userId = UserInfo.getUserId();
        if (!cachedProfileNameByUser.containsKey(userId)) {
            cachedProfileNameByUser.put(userId,
                [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() WITH SYSTEM_MODE].Name);
        }
        return cachedProfileNameByUser.get(userId);
    }

    private static Boolean isValidationBypassed() {
        Trigger_Framework_Config_CC__mdt config = Trigger_Framework_Config_CC__mdt.getInstance('Lead');
        return config != null && config.Bypass_Validation_CC__c == true;
    }

    /** Record type developer name of every referenced Entity Associated Account (one query per call). */
    private static Map<Id, String> getAccountRecordTypes(List<Lead> leads) {
        Set<Id> accountIds = new Set<Id>();
        for (Lead lead : leads) {
            if (lead.Entity_Associated_CC__c != null) {
                accountIds.add(lead.Entity_Associated_CC__c);
            }
        }
        Map<Id, String> recordTypeById = new Map<Id, String>();
        if (accountIds.isEmpty()) {
            return recordTypeById;
        }
        for (Account acc : [SELECT Id, RecordType.DeveloperName FROM Account WHERE Id IN :accountIds WITH SYSTEM_MODE]) {
            recordTypeById.put(acc.Id, acc.RecordType?.DeveloperName);
        }
        return recordTypeById;
    }
}
