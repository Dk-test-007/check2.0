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
 * Central trigger handler for Lead object.
 * Lead assignment notification is handled asynchronously through:
 * LeadAssignmentNotification_CC
 * Re-Nurture ownership re-assignment is handled by assignOwnerOnReNurture().
 * =============================================================================
 * Prerequisites
 * =============================================================================
 * - Field history tracking enabled on the Lead 'Owner' field.
 * - Custom permission 'Marketing_User_Permission_CC' granted to Marketing
 *   users, via profile or permission set.
 * - Queues 'UK_Marketing_Pool' and 'US_Marketing_Pool' must support Lead.
 * - No additional permissions are required for end users.
 * =============================================================================
 */
public without sharing class LeadTriggerHandler_CC extends BaseTriggerHandler_CC {
    public void run() {
        super.run(this, 'Lead');
    }
    
    public override void beforeInsert() {
        sortProductCategories((List<Lead>) Trigger.new, null);
        //applyCompanyOwnerMapping((List<Lead>) Trigger.new, null);
        
    }
    
    public override void beforeUpdate(){
        List<Lead> leadsQualifying = new List<Lead>();
        Map<Id, Lead> oldLeadMap = (Map<Id, Lead>) Trigger.oldMap;
        for (Lead leadRecord : (List<Lead>) Trigger.new) {
            Lead oldLead = oldLeadMap.get(leadRecord.Id);
            if (oldLead.Status != 'Qualify' && leadRecord.Status == 'Qualify') {
                leadsQualifying.add(leadRecord);
            }
        }
        if (!leadsQualifying.isEmpty()) {
            checkDuplicates(leadsQualifying);
        }
        
        sortProductCategories((List<Lead>) Trigger.new,(Map<Id, Lead>) Trigger.oldMap);
        // applyCompanyOwnerMapping((List<Lead>) Trigger.new, null);
        
    }
    
    public override void afterInsert() {
        notifyRoleManagerOnDuplicateLead((List<Lead>) Trigger.new);
        Set<Id> leadIds = new Set<Id>();
        for (Lead leadRecord : (List<Lead>) Trigger.new) {
            if (leadRecord.Id != null) {
                leadIds.add(leadRecord.Id);
            }
        }
        if (leadIds.isEmpty()) {
            return;
        }
        new LeadAssignmentNotification_CC(leadIds, null, false, true).execute();
    }
    
    public override void afterUpdate() {
        Map<Id, Lead> oldLeadMap = (Map<Id, Lead>) Trigger.oldMap;
        Set<Id> leadIds = new Set<Id>();
        for (Lead newLead : (List<Lead>) Trigger.new) {
            Lead oldLead = oldLeadMap.get(newLead.Id);
            if (oldLead == null) {
                continue;
            }
            if (newLead.OwnerId != oldLead.OwnerId && newLead.Status == 'Qualify') {
                leadIds.add(newLead.Id);
            }
        }
        if (leadIds.isEmpty()) {
            return;
        }
        new LeadAssignmentNotification_CC(leadIds, null, false, false).execute();
    }
    
    public static void sortProductCategories(List<Lead> newLeads,Map<Id, Lead> oldLeadMap) {
        for (Lead newLead : newLeads) {
            // On update, only process when Product Category changed
            if (oldLeadMap != null) {
                Lead oldLead = oldLeadMap.get(newLead.Id);
                
                if (oldLead != null && newLead.Product_Category_CC__c == oldLead.Product_Category_CC__c) {
                    continue;
                }
            }
            
            // Clear text field if no categories are selected
            if (String.isBlank(newLead.Product_Category_CC__c)) {
                newLead.Product_Category_Text_CC__c = null;
                continue;
            }
            List<String> categories = newLead.Product_Category_CC__c.split(';');
            categories.sort();
            newLead.Product_Category_Text_CC__c =
                String.join(categories, ';');
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
                        currentLead.addError('This Lead matches an existing record. ' +'Triggered by rule: ' + dupRuleName);
                        break;
                    }
                }
            }
        }
    }
    
    
    private static void applyCompanyOwnerMapping(List<Lead> leads,Map<Id, Lead> oldLeadMap) {
        if (leads == null || leads.isEmpty()) {
            return;
        }
        Map<String, Lead_Company_Owner_Mapping_CC__mdt> mappings = getCompanyMappings();
        if (mappings.isEmpty()) {
            return;
        }
        Map<Lead, Id> leadToOwnerId = new Map<Lead, Id>();
        Set<Id> ownerIds = new Set<Id>();
        
        for (Lead leadRecord : leads) {
            
            if (oldLeadMap != null) {
                Lead oldLead = oldLeadMap.get(leadRecord.Id);
                
                if (oldLead != null &&
                oldLead.Company == leadRecord.Company) {
                    continue;
                }
            }
            
            if (String.isBlank(leadRecord.Company)) {
                continue;
            }
            
            Lead_Company_Owner_Mapping_CC__mdt mapping =
                mappings.get(leadRecord.Company);
            
            if (mapping == null) {
                continue;
            }
            
            if (String.isBlank(mapping.Owner_Id_CC__c)) {
                System.debug(
                    LoggingLevel.WARN,
                'CP-33: Owner Id is blank for Company ' +
                    leadRecord.Company
                    );
                continue;
            }
            
            try {
                Id ownerId = (Id) mapping.Owner_Id_CC__c;
                ownerIds.add(ownerId);
                leadToOwnerId.put(leadRecord, ownerId);
            } catch (Exception ex) {
                System.debug(
                    LoggingLevel.WARN,
                'CP-33: Invalid Owner Id in metadata for Company ' +
                    leadRecord.Company +
                    ': ' +
                    mapping.Owner_Id_CC__c
                    );
            }
        }
        
        if (leadToOwnerId.isEmpty()) {
            return;
        }
        
        Map<Id, User> usersById = new Map<Id, User>();
        
        for (User userRecord : [
            SELECT Id, IsActive
            FROM User
            WHERE Id IN :ownerIds
            WITH SYSTEM_MODE
        ]) {
            usersById.put(userRecord.Id, userRecord);
        }
        
        Map<Id, Group> queuesById = new Map<Id, Group>();
        
        for (Group queueRecord : [
            SELECT Id, Type
            FROM Group
            WHERE Id IN :ownerIds
            AND Type = 'Queue'
            WITH SYSTEM_MODE
        ]) {
            queuesById.put(queueRecord.Id, queueRecord);
        }
        
        for (Lead leadRecord : leadToOwnerId.keySet()) {
            Id configuredOwnerId = leadToOwnerId.get(leadRecord);
            
            if (usersById.containsKey(configuredOwnerId)) {
                User owner = usersById.get(configuredOwnerId);
                
                if (!owner.IsActive) {
                    System.debug(
                        LoggingLevel.WARN,
                    'CP-33: Configured User is inactive for Company ' +
                        leadRecord.Company
                        );
                    continue;
                }
                
                leadRecord.OwnerId = configuredOwnerId;
                continue;
            }
            
            if (queuesById.containsKey(configuredOwnerId)) {
                leadRecord.OwnerId = configuredOwnerId;
                continue;
            }
            
            System.debug(
                LoggingLevel.WARN,
            'CP-33: Configured Owner is not a valid User or Queue. ' +
                'Company=' +
                leadRecord.Company +
                ', OwnerId=' +
                String.valueOf(configuredOwnerId)
                );
        }
    }
    
    private static Map<String, Lead_Company_Owner_Mapping_CC__mdt>
    getCompanyMappings() {
        
        Map<String, Lead_Company_Owner_Mapping_CC__mdt> mappings =
            new Map<String, Lead_Company_Owner_Mapping_CC__mdt>();
        
        for (Lead_Company_Owner_Mapping_CC__mdt mapping : [SELECT DeveloperName,MasterLabel,Company_Name_CC__c,Entity_CC__c,Owner_Id_CC__c,Active_CC__c
                                                                FROM Lead_Company_Owner_Mapping_CC__mdt WHERE Active_CC__c = TRUE]) {
            if (String.isBlank(mapping.Company_Name_CC__c)) {
                continue;
            }
            
            if (!mappings.containsKey(mapping.Company_Name_CC__c)) {
                mappings.put(mapping.Company_Name_CC__c,mapping);
            }
            Database.DMLOptions dmo = new Database.DMLOptions();
            dmo.assignmentRuleHeader.useDefaultRule = false;
        }
        
        return mappings;
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
            String ruleName = ruleNameByLeadId.get(ld.Id);
            String body = leadName
                + (String.isBlank(ld.Company) ? '' : ' (' + ld.Company + ')')
                + ', created by ' + creator.Name
                + ', matches an existing record.'
                + (String.isBlank(ruleName) ? '' : ' Duplicate rule: ' + ruleName + '.');

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(notificationTypes[0].Id);
            notification.setTargetId(ld.Id);
            notification.setTitle(('Duplicate Lead Created: ' + leadName).left(250));
            notification.setBody(body.left(750));
            try {
                notification.send(new Set<String>{ String.valueOf(recipientId) });
            } catch (Exception ex) {
                System.debug(LoggingLevel.ERROR, '### Duplicate Lead notification failed for Lead ' + ld.Id + ': ' + ex.getMessage());
            }
        }
    }
    
}