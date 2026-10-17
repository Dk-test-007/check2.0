public class AccountTriggerHandler_CC extends BaseTriggerHandler_CC {
    public void run(BaseTriggerHandler_CC handler) {
        super.run(handler, 'Account');
    }
    
    public static Boolean bypassUpdateSyncForAutoNumber = false;
    
    public override void beforeInsert()
    {
        setAccountTypeToProspect((List<Account>)trigger.new);
        populateAddressMatchKeys((List<Account>)trigger.new, null);
        handleAccountGenerationFromLead((List<Account>)trigger.new);
        syncSiteCustomerTypeFromParent((List<Account>)trigger.new,null);
        setCashAccountCreditLimit((List<Account>)trigger.new);
        setDefaultTaxAreaCode((List<Account>)trigger.new,null);
    }
    public override void beforeUpdate()
    {
        //automateFinancialCheck((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        setTypeOnBusinessCentralIdPopulated((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        populateAddressMatchKeys((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        updateBusinessCentralSyncStatus((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        syncSiteCustomerTypeFromParent((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        setCashAccountCreditLimit((List<Account>)trigger.new);
        lockIntegrationFieldsAfterSync((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        validateFinancialApproval((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        validateCreditAccountCreditLimit((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        setDefaultTaxAreaCode((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
    }
    public override void afterUpdate() {
        sendOnboardingCompletionEmails((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        sendFinancialCheckCompletionEmails((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        publishFinancialCheckApprovedToBusinessCentral((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        publishEntityUpdatesToBusinessCentral((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        publishRelatedRecordsOnParentSync((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        publishSiteUpdatesToBusinessCentral((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        cascadeCustomerTypeToSites((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        initiateBauOpportunityCreation((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
    }
    public override void afterInsert() {
        publishNewSitesForSyncedParents((List<Account>)trigger.new, (Map<Id,Account>)trigger.oldMap);
        populateSiteCodeFromAutoNumber((List<Account>)trigger.new);
    }
    public override void beforeDelete() {
        preventAccountDeletion((List<Account>)trigger.Old);
    }
    public static void setDefaultTaxAreaCode(List<Account> newList, Map<Id, Account> oldMap) {
        for (Account acc : newList) {
            Account oldAcc = oldMap != null ? oldMap.get(acc.Id) : null;
            
            if (acc.Entity_CC__c == 'Carlton Packaging INC') {
                if (oldAcc == null || acc.Entity_CC__c != oldAcc.Entity_CC__c) {
                    acc.Tax_Area_CC__c = 'VERTEX';
                }
            }
        }
    }
    public static void validateFinancialApproval(List<Account> newList, Map<Id, Account> oldMap) {
        
        // 1-2. Bypass check: Custom Metadata / System Administrator Profile
        if (isFinancialValidationBypassed()) {
            return;
        }
        
        // 3. Process records
        for (Account newAcc : newList) {
            Account oldAcc = (oldMap != null) ? oldMap.get(newAcc.Id) : null;
            
            // Check if Financial_Check_CC__c is being set/changed to 'Approved'
            Boolean isApprovedNow = (newAcc.Financial_Check_CC__c == 'Approved');
            Boolean wasNotApprovedBefore = (oldAcc == null || oldAcc.Financial_Check_CC__c != 'Approved');
            
            if (isApprovedNow && wasNotApprovedBefore) {
                
                // 4. Validate Credit fields ONLY if Customer Type is 'Credit Account'
                if (newAcc.Customer_Type_CC__c == 'Credit Account') {
                    if (String.isBlank(newAcc.Credit_Risk_Status_CC__c)) {
                        newAcc.addError(Account.Credit_Risk_Status_CC__c, 'Credit Risk Status is required for Credit Accounts before approving Financial Check');
                    }
                    // Credit Limit is validated in validateCreditAccountCreditLimit
                }
                
                // 5. Validate fields required to create the Customer in Business Central (all Customer Types)
                if (String.isBlank(newAcc.VAT_Registration_Number_CC__c)) {
                    newAcc.addError(Account.VAT_Registration_Number_CC__c, 'VAT Registration Number is required before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.Tax_Registration_No_CC__c)) {
                    newAcc.addError(Account.Tax_Registration_No_CC__c, 'Tax Registration Number is required for Business Central sync before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.BillingStreet)) {
                    newAcc.addError(Account.BillingStreet, 'Billing Street is required for Business Central sync before approving Financial Check');
                } else if (newAcc.BillingStreet.length() > BC_ADDRESS_MAX_LENGTH) {
                    newAcc.addError(Account.BillingStreet, 'Billing Street cannot exceed ' + BC_ADDRESS_MAX_LENGTH + ' characters for Business Central sync');
                }
                
                if (String.isBlank(newAcc.BillingCity)) {
                    newAcc.addError(Account.BillingCity, 'Billing City is required for Business Central sync before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.BillingPostalCode)) {
                    newAcc.addError(Account.BillingPostalCode, 'Billing Zip/Postal Code is required for Business Central sync before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.BillingCountry)) {
                    newAcc.addError(Account.BillingCountry, 'Billing Country is required for Business Central sync before approving Financial Check');
                } else if (String.isBlank(newAcc.BillingState) && STATE_REQUIRED_COUNTRIES.contains(newAcc.BillingCountry.trim().toUpperCase())) {
                    newAcc.addError(Account.BillingState, 'Billing State/Province is required for US, Mexico and Canada addresses for Business Central sync');
                }
                
                if (String.isBlank(newAcc.Tax_Area_CC__c)) {
                    newAcc.addError(Account.Tax_Area_CC__c, 'Tax Area is required for Business Central sync before approving Financial Check');
                }
                
                if (newAcc.Tax_Liable_CC__c != true) {
                    newAcc.addError(Account.Tax_Liable_CC__c, 'Tax Liable must be checked for Business Central sync before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.Customer_Posting_Group_CC__c)) {
                    newAcc.addError(Account.Customer_Posting_Group_CC__c, 'Customer Posting Group is required for Business Central sync before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.Gen_Bus_Posting_Group_CC__c)) {
                    newAcc.addError(Account.Gen_Bus_Posting_Group_CC__c, 'Gen. Bus. Posting Group is required for Business Central sync before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.Salesperson_Code_CC__c) && String.isBlank(newAcc.Responsibility_Center_CC__c)) {
                    newAcc.addError(Account.Salesperson_Code_CC__c, 'Salesperson Code is required for Business Central sync unless a Responsibility Center is selected');
                }
                
                if (String.isBlank(newAcc.Document_Sending_Profile_CC__c)) {
                    newAcc.addError(Account.Document_Sending_Profile_CC__c, 'Document Sending Profile is required for Business Central sync before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.Payment_Terms_CC__c)) {
                    newAcc.addError(Account.Payment_Terms_CC__c, 'Payment Terms is required for Business Central sync before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.Location_Code_CC__c)) {
                    newAcc.addError(Account.Location_Code_CC__c, 'Location Code is required for Business Central sync before approving Financial Check');
                }
                
                if (String.isBlank(newAcc.Email_CC__c)) {
                    newAcc.addError(Account.Email_CC__c, 'Email is required for Business Central sync before approving Financial Check');
                }
            }
        }
    }
    
    // Credit Limit rules apply only when a user edits an Account whose Financial Check is already 'Initiated'
    // (the automatic move to 'Initiated' on onboarding completion is not checked)
    private static Boolean isEditDuringFinancialCheck(Account oldAcc) {
        return oldAcc != null && oldAcc.Financial_Check_CC__c == 'Initiated';
    }
    
    // Before insert / update: a Cash Account always has a Credit Limit of 0
    public static void setCashAccountCreditLimit(List<Account> newList) {
        for (Account newAcc : newList) {
            if (newAcc.Customer_Type_CC__c == 'Cash Account' && newAcc.Credit_Limit_CC__c != 0) {
                newAcc.Credit_Limit_CC__c = 0;
            }
        }
    }
    
    // Before update: a Credit Account must have a Credit Limit greater than 0 (blank treated as 0)
    public static void validateCreditAccountCreditLimit(List<Account> newList, Map<Id, Account> oldMap) {
        
        List<Account> creditAccounts = new List<Account>();
        for (Account newAcc : newList) {
            Account oldAcc = (oldMap != null) ? oldMap.get(newAcc.Id) : null;
            if (isEditDuringFinancialCheck(oldAcc) && newAcc.Customer_Type_CC__c == 'Credit Account') {
                creditAccounts.add(newAcc);
            }
        }
        
        if (creditAccounts.isEmpty() || isFinancialValidationBypassed()) {
            return;
        }
        
        for (Account newAcc : creditAccounts) {
            Decimal creditLimit = (newAcc.Credit_Limit_CC__c == null) ? 0 : newAcc.Credit_Limit_CC__c;
            if (creditLimit <= 0) {
                newAcc.addError(Account.Credit_Limit_CC__c, 'Credit Limit must be greater than 0 for Credit Accounts');
            }
        }
    }
    
    // Financial Check validations are skipped when the Account framework bypass is on or the user is a System Administrator
    private static Boolean financialValidationBypassed;
    
    private static Boolean isFinancialValidationBypassed() {
        if (financialValidationBypassed == null) {
            Trigger_Framework_Config_CC__mdt config = Trigger_Framework_Config_CC__mdt.getInstance('Account');
            Profile currentProfile = [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() WITH SYSTEM_MODE LIMIT 1];
            financialValidationBypassed = (config != null && config.Bypass_Validation_CC__c == true)
                || currentProfile.Name == 'System Administrator';
        }
        return financialValidationBypassed;
    }
    
    // Business Central limits for the customer address (addressLine1 = Text[100])
    private static final Integer BC_ADDRESS_MAX_LENGTH = 100;
    
    // Billing Country values for which Business Central requires a State / Province
    private static final Set<String> STATE_REQUIRED_COUNTRIES = new Set<String>{
        'US', 'USA', 'UNITED STATES', 'UNITED STATES OF AMERICA',
            'MX', 'MEX', 'MEXICO', 'MÉXICO',
            'CA', 'CAN', 'CANADA'
            };
                public static void lockIntegrationFieldsAfterSync(List<Account> newList, Map<Id, Account> oldMap) {
                    Profile currentUserProfile = [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() WITH SYSTEM_MODE LIMIT 1];
                    String profileName = currentUserProfile.Name;
                    
                    // Bypass for Admin, Finance User, and Integration User
                    if (profileName == 'System Administrator' || profileName == 'Carlton Finance User' || UserInfo.getName() == 'Integration User') {
                        return; 
                    }
                    
                    List<Integration_Config__mdt> configs = [SELECT Request_Mapping__c FROM Integration_Config__mdt WHERE SObject_API_Name__c = 'Account' AND Operation__c = 'Update' WITH SYSTEM_MODE LIMIT 1];
                    
                    if (configs.isEmpty() || String.isBlank(configs[0].Request_Mapping__c)) {
                        return;
                    }
                    
                    List<String> mappedFieldsList = (List<String>) JSON.deserialize(configs[0].Request_Mapping__c, List<String>.class);
                    Set<String> lockedFields = new Set<String>(mappedFieldsList);
                    
                    lockedFields.remove('Id');
                    
                    for (Account acc : newList) {
                        Account oldAcc = oldMap.get(acc.Id);
                        
                        if (String.isNotBlank(acc.Business_Central_Customer_ID_CC__c)) {
                            for (String field : lockedFields) {
                                if (field.contains('.')) continue;
                                
                                if (acc.get(field) != oldAcc.get(field)) {
                                    acc.addError(field, 'Only Admin Users can edit Entity Synced Fields');
                                }
                            }
                        }
                    }
                }
    public static void cascadeCustomerTypeToSites(List<Account> newList, Map<Id, Account> oldMap) {
        Map<Id, String> parentIdToNewType = new Map<Id, String>();
        
        for (Account acc : newList) {
            Account oldAcc = oldMap.get(acc.Id);
            if (acc.Type != oldAcc.Type) {
                parentIdToNewType.put(acc.Id, acc.Type);
            }
        }
        
        if (parentIdToNewType.isEmpty()) return;
        
        List<Account> sitesToUpdate = [SELECT Id, ParentId, Type FROM Account WHERE ParentId IN :parentIdToNewType.keySet() AND RecordType.DeveloperName = 'Site' WITH SYSTEM_MODE];
        
        if (!sitesToUpdate.isEmpty()) {
            for (Account site : sitesToUpdate) {
                site.Type = parentIdToNewType.get(site.ParentId);
            }
            update sitesToUpdate;
        }
    }
    public static void populateSiteCodeFromAutoNumber(List<Account> newList) {
        Id siteRecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Site').getRecordTypeId();
        List<Id> siteIdsToProcess = new List<Id>();
        
        for (Account acc : newList) {
            if (acc.RecordTypeId == siteRecordTypeId) {
                siteIdsToProcess.add(acc.Id);
            }
        }
        
        if (siteIdsToProcess.isEmpty()) return;
        
        List<Account> sitesToUpdate = [SELECT Id, Site_Code_Auto_CC__c FROM Account WHERE Id IN :siteIdsToProcess WITH SYSTEM_MODE];
        
        for (Account acc : sitesToUpdate) {
            acc.Site_Code_CC__c = acc.Site_Code_Auto_CC__c;
        }
        bypassUpdateSyncForAutoNumber = true;
        
        if (!sitesToUpdate.isEmpty()) {
            Database.update(sitesToUpdate, AccessLevel.SYSTEM_MODE);
        }
        
        // FLIP FLAG BACK TO FALSE AFTER DML
        bypassUpdateSyncForAutoNumber = false;
        
    }
    public static void preventAccountDeletion(List<Account> oldList) {
        Id adminProfileId = [SELECT Id FROM Profile WHERE Name = 'System Administrator' WITH SYSTEM_MODE LIMIT 1].Id;
        
        if (UserInfo.getProfileId() != adminProfileId) {
            for (Account acc : oldList) {
                acc.addError('Only Admin Users are permitted to delete Accounts.');
            }
        }
    }
    public static void syncSiteCustomerTypeFromParent(List<Account> newList, Map<Id, Account> oldMap) {
        Id siteRecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Site').getRecordTypeId();
        Set<Id> parentIds = new Set<Id>();
        
        for (Account acc : newList) {
            Account oldAcc = oldMap != null ? oldMap.get(acc.Id) : null;
            if (acc.RecordTypeId == siteRecordTypeId && acc.ParentId != null && 
                (oldAcc == null || acc.ParentId != oldAcc.ParentId)) {
                    parentIds.add(acc.ParentId);
                }
        }
        
        if (parentIds.isEmpty()) return;
        
        Map<Id, Account> parents = new Map<Id, Account>([SELECT Id, Type FROM Account WHERE Id IN :parentIds]);
        
        for (Account acc : newList) {
            if (acc.RecordTypeId == siteRecordTypeId && acc.ParentId != null && parents.containsKey(acc.ParentId)) {
                acc.Type = parents.get(acc.ParentId).Type;
            }
        }
    }
    public static void setAccountTypeToProspect(List<Account> newAccounts) {
        for (Account acc : newAccounts) {
            if (String.isBlank(acc.Type)) {
                acc.Type = 'Prospect';
            }
        }
    }
    //DEPRECATED BY CLIENT
    /*
public void automateFinancialCheck(List<Account> newAccountList, Map<Id,Account> accountOldMap)
{
for(Account acc:newAccountList)
{
System.debug('Check new val '+acc.Client_Onboarding_Status_CC__c);
System.debug('Check Old val '+accountOldMap.get(acc.Id).Client_Onboarding_Status_CC__c);
If(acc.Client_Onboarding_Status_CC__c == 'Completed' && accountOldMap.get(acc.Id).Client_Onboarding_Status_CC__c != 'Completed') {
System.debug('Reached here --1');
acc.Financial_Check_CC__c = 'Initiated';
}
}
}
*/
    
    
    // Sends the Account to Business Central (via Anypoint MQ) as soon as Financial_Check_CC__c becomes 'Approved'
    private static final Set<Id> publishedToBusinessCentral = new Set<Id>();
    
    public static void publishFinancialCheckApprovedToBusinessCentral(List<Account> newList, Map<Id, Account> oldMap) {
        if (UserInfo.getName() == 'Integration User') return;
        
        Set<Id> accountsToCreate = new Set<Id>();
        Set<Id> accountsToUpdate = new Set<Id>();
        
        for (Account acc : newList) {
            Account oldAcc = oldMap.get(acc.Id);
            if (oldAcc == null) continue;
            if (acc.Financial_Check_CC__c != 'Approved' || oldAcc.Financial_Check_CC__c == 'Approved') continue;
            if (!publishedToBusinessCentral.add(acc.Id)) continue; 
            
            if (String.isBlank(acc.Business_Central_Customer_ID_CC__c)) {
                accountsToCreate.add(acc.Id);
            } else {
                accountsToUpdate.add(acc.Id);
            }
        }
        
        // The second parameter must map to the HTTP method defined in your metadata
        if (!accountsToCreate.isEmpty()) {
            CalloutService_CC.send(accountsToCreate, 'Create');
        }
    }
    public static void publishEntityUpdatesToBusinessCentral(List<Account> newList, Map<Id, Account> oldMap) {
        if (UserInfo.getName() == 'Integration User') return;
        
        // 1. Query and parse tracked fields directly from Custom Metadata
        Set<String> trackedFields = new Set<String>();
        List<Integration_Config__mdt> configs = [
            SELECT Request_Mapping__c 
            FROM Integration_Config__mdt 
            WHERE SObject_API_Name__c = 'Account' 
            AND Operation__c = 'Update' 
            WITH SYSTEM_MODE LIMIT 1
        ];
        
        if (!configs.isEmpty() && String.isNotBlank(configs[0].Request_Mapping__c)) {
            List<String> mappedFieldsList = (List<String>) JSON.deserialize(configs[0].Request_Mapping__c, List<String>.class);
            for (String field : mappedFieldsList) {
                if (field != 'Id' && !field.contains('.')) {
                    trackedFields.add(field);
                }
            }
        }
        
        if (trackedFields.isEmpty()) return;
        
        // 2. Evaluate changes and dispatch
        Map<Id, List<String>> entityToChangedFields = new Map<Id, List<String>>();
        Id siteRecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Site').getRecordTypeId();
        
        for (Account acc : newList) {
            Account oldAcc = oldMap.get(acc.Id);
            if (oldAcc == null) continue;
            
            if (acc.RecordTypeId != siteRecordTypeId && String.isNotBlank(acc.Business_Central_Customer_ID_CC__c)) {
                List<String> changedFields = new List<String>();
                
                for (String field : trackedFields) {
                    if (acc.get(field) != oldAcc.get(field)) {
                        changedFields.add(field);
                    }
                }
                
                if (!changedFields.isEmpty()) {
                    entityToChangedFields.put(acc.Id, changedFields);
                }
            }
        }
        
        if (!entityToChangedFields.isEmpty()) {
            CalloutService_CC.send(entityToChangedFields, 'Update');
        }
    }
    public static void publishRelatedRecordsOnParentSync(List<Account> newList, Map<Id, Account> oldMap) {
        Set<Id> syncedParentIds = new Set<Id>();
        List<Account> newlySyncedAccounts = new List<Account>(); // Track for notifications
        
        // 1. Identify parent accounts that just synced to Business Central
        for (Account acc : newList) {
            Account oldAcc = oldMap.get(acc.Id);
            if (oldAcc != null 
                && String.isBlank(oldAcc.Business_Central_Customer_ID_CC__c) 
                && String.isNotBlank(acc.Business_Central_Customer_ID_CC__c)) {
                    
                    syncedParentIds.add(acc.Id);
                    newlySyncedAccounts.add(acc); // Collect for notification
                }
        }
        
        // 2. Send Custom Notifications immediately
        if (!newlySyncedAccounts.isEmpty()) {
            sendBCSyncNotifications(newlySyncedAccounts);
        }
        
        if (syncedParentIds.isEmpty()) return;
        
        // 3. Query Child Accounts (Sites) related to the parents
        Map<Id, Account> childAccounts = new Map<Id, Account>([
            SELECT Id 
            FROM Account 
            WHERE ParentId IN :syncedParentIds
        ]);
        
        if (!childAccounts.isEmpty()) {
            CalloutService_CC.send(childAccounts.keySet(), 'SiteCreate');
        }
        
    }
    public static void publishNewSitesForSyncedParents(List<Account> newList, Map<Id, Account> oldMap) {
        if (UserInfo.getName() == 'Integration User') return;
        
        Set<Id> potentialSiteIds = new Set<Id>();
        Set<Id> parentIdsToQuery = new Set<Id>();
        
        // 1. Identify Sites inserted with a parent, or updated to a new parent
        for (Account acc : newList) {
            Account oldAcc = oldMap != null ? oldMap.get(acc.Id) : null;
            
            if (acc.ParentId != null && (oldAcc == null || acc.ParentId != oldAcc.ParentId)) {
                potentialSiteIds.add(acc.Id);
                parentIdsToQuery.add(acc.ParentId);
            }
        }
        
        if (parentIdsToQuery.isEmpty()) return;
        
        // 2. Query the parent accounts to verify if they are already synced
        Map<Id, Account> syncedParents = new Map<Id, Account>([
            SELECT Id 
            FROM Account 
            WHERE Id IN :parentIdsToQuery 
            AND Business_Central_Customer_ID_CC__c != null
        ]);
        
        if (syncedParents.isEmpty()) return;
        
        // 3. Collect the Site IDs that belong to a synced parent
        Set<Id> sitesToSync = new Set<Id>();
        for (Account acc : newList) {
            if (potentialSiteIds.contains(acc.Id) && syncedParents.containsKey(acc.ParentId)) {
                sitesToSync.add(acc.Id);
            }
        }
        
        // 4. Dispatch to the integration framework using the existing Site configuration
        if (!sitesToSync.isEmpty()) {
            CalloutService_CC.send(sitesToSync, 'SiteCreate');
        }
    }
    public static void publishSiteUpdatesToBusinessCentral(List<Account> newList, Map<Id, Account> oldMap) {
        if (UserInfo.getName() == 'Integration User' || bypassUpdateSyncForAutoNumber) return;
        
        Set<String> trackedFields = new Set<String>();
        List<Integration_Config__mdt> configs = [
            SELECT Request_Mapping__c 
            FROM Integration_Config__mdt 
            WHERE SObject_API_Name__c = 'Account' 
            AND Operation__c = 'SiteUpdate' 
            WITH SYSTEM_MODE LIMIT 1
        ];
        
        if (!configs.isEmpty() && String.isNotBlank(configs[0].Request_Mapping__c)) {
            List<String> mappedFieldsList = (List<String>) JSON.deserialize(configs[0].Request_Mapping__c, List<String>.class);
            for (String field : mappedFieldsList) {
                if (field != 'Id' && !field.contains('.')) {
                    trackedFields.add(field);
                }
            }
        }
        
        if (trackedFields.isEmpty()) return;
        
        Id siteRecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Site').getRecordTypeId();
        
        // Track both mapped field updates AND full creates
        Map<Id, List<String>> preliminarySiteUpdates = new Map<Id, List<String>>();
        Set<Id> preliminarySiteCreates = new Set<Id>();
        Set<Id> parentIdsToCheck = new Set<Id>();
        
        for (Account acc : newList) {
            Account oldAcc = oldMap.get(acc.Id);
            if (oldAcc == null) continue;
            
            if (acc.RecordTypeId == siteRecordTypeId && acc.ParentId != null) {
                List<String> changedFields = new List<String>();
                
                for (String field : trackedFields) {
                    if (acc.get(field) != oldAcc.get(field)) {
                        changedFields.add(field);
                    }
                }
                
                if (!changedFields.isEmpty()) {
                    parentIdsToCheck.add(acc.ParentId);
                    
                    // Route based on sync checkbox
                    if (acc.Site_Synced_CC__c == true) {
                        changedFields.add('RecordType.Name');
                        preliminarySiteUpdates.put(acc.Id, changedFields);
                    } else {
                        preliminarySiteCreates.add(acc.Id);
                    }
                }
            }
        }
        
        if (parentIdsToCheck.isEmpty()) return;
        
        Map<Id, Account> syncedParents = new Map<Id, Account>([
            SELECT Id FROM Account WHERE Id IN :parentIdsToCheck AND Business_Central_Customer_ID_CC__c != null
        ]);
        
        if (syncedParents.isEmpty()) return;
        
        Map<Id, List<String>> confirmedSitesToUpdate = new Map<Id, List<String>>();
        Set<Id> confirmedSitesToCreate = new Set<Id>();
        
        for (Account acc : newList) {
            if (syncedParents.containsKey(acc.ParentId)) {
                if (preliminarySiteUpdates.containsKey(acc.Id)) {
                    confirmedSitesToUpdate.put(acc.Id, preliminarySiteUpdates.get(acc.Id));
                } else if (preliminarySiteCreates.contains(acc.Id)) {
                    confirmedSitesToCreate.add(acc.Id);
                }
            }
        }
        
        if (!confirmedSitesToUpdate.isEmpty()) {
            CalloutService_CC.send(confirmedSitesToUpdate, 'SiteUpdate');
        }
        if (!confirmedSitesToCreate.isEmpty()) {
            CalloutService_CC.send(confirmedSitesToCreate, 'SiteCreate');
        }
    }
    
    private static void sendBCSyncNotifications(List<Account> accounts) {
        try {
            // Fetch the notification type created in Setup
            CustomNotificationType type = [
                SELECT Id 
                FROM CustomNotificationType 
                WHERE DeveloperName = 'BC_Sync_Success_CC' 
                LIMIT 1
            ];
            
            for (Account acc : accounts) {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                
                // Construct the notification payload
                notification.setTitle('Business Central Sync Complete');
                notification.setBody('Account "' + acc.Name + '" has successfully synced. BC ID: ' + acc.Business_Central_Customer_ID_CC__c);
                notification.setNotificationTypeId(type.Id);
                notification.setTargetId(acc.Id); // Clicking the bell icon routes to the Account record
                
                // Send to the Account Owner. 
                // Note: You can replace acc.OwnerId with acc.LastModifiedById if you want to notify the person who triggered the sync.
                notification.send(new Set<String> { acc.OwnerId });
            }
        } catch (Exception e) {
            System.debug('Error sending BC Sync Custom Notification: ' + e.getMessage());
        }
    }
    public static void updateBusinessCentralSyncStatus(List<Account> newList, Map<Id, Account> oldMap) {
        for (Account acc : newList) {
            Account oldAcc = oldMap != null ? oldMap.get(acc.Id) : null;
            
            // Detect when BC writes back the ID and mark as Successfully Synced
            if (String.isNotBlank(acc.Business_Central_Customer_ID_CC__c) && 
                (oldAcc == null || String.isBlank(oldAcc.Business_Central_Customer_ID_CC__c))) {
                    
                    acc.BC_Sync_Status_CC__c = 'Successfully Synced';
                }
        }
    }
    public static void setTypeOnBusinessCentralIdPopulated(List<Account> newList, Map<Id, Account> oldMap) {
        for (Account acc : newList) {
            Account oldAcc = oldMap.get(acc.Id);
            
            Boolean justPopulated = String.isNotBlank(acc.Business_Central_Customer_ID_CC__c) && String.isBlank(oldAcc.Business_Central_Customer_ID_CC__c);
            
            if (justPopulated && acc.Type != 'Customer') {
                acc.Type = 'Customer';  
            }
        }
    }
    public static void sendOnboardingCompletionEmails(List<Account> newList, Map<Id, Account> oldMap) {
        
        List<Account> eligible = new List<Account>();
        for (Account acc : newList) {
            Account oldAcc = oldMap.get(acc.Id);
            if (oldAcc != null
                && acc.Client_Onboarding_Status_CC__c == 'Completed'
                && oldAcc.Client_Onboarding_Status_CC__c != 'Completed') {
                    eligible.add(acc);
                }
        }
        if (eligible.isEmpty()) return;
        
        List<String> recipients = new List<String>();
        for (Finance_Team_Email_CC__mdt rec : [
            SELECT Email_CC__c
            FROM Finance_Team_Email_CC__mdt
            WHERE Email_CC__c != NULL
            WITH SYSTEM_MODE
        ]) {
            recipients.add(rec.Email_CC__c);
        }
        if (recipients.isEmpty()) return;
        
        Id templateId = getActiveTemplateId('Customer_Onboarding_Documentation_Ready_for_Finance_Review_CC');
        if (templateId == null) return;
        
        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
        for (Account acc : eligible) {
            Messaging.SingleEmailMessage msg =
                Messaging.renderStoredEmailTemplate(templateId, null, acc.Id);
            msg.setToAddresses(recipients);
            msg.setSaveAsActivity(false);
            messages.add(msg);
        }
        
        sendInBatches(messages);
    }
    
    private static final Set<String> FINANCIAL_CHECK_OUTCOMES = new Set<String>{ 'Approved', 'Rejected' };
        public static void sendFinancialCheckCompletionEmails(List<Account> newList, Map<Id, Account> oldMap) {
            
            List<Account> eligible = new List<Account>();
            Set<Id> ownerIds = new Set<Id>();
            
            for (Account acc : newList) {
                Account oldAcc = oldMap.get(acc.Id);
                if (oldAcc == null) continue;
                
                String newStatus = acc.Financial_Check_CC__c;
                String oldStatus = oldAcc.Financial_Check_CC__c;
                
                // Only Approved / Rejected are notifiable outcomes
                if (!FINANCIAL_CHECK_OUTCOMES.contains(newStatus)) continue;
                
                // Ignore saves that did not change the outcome
                if (newStatus == oldStatus) continue;
                
                // Do not notify when an already-approved check is later rejected.
                // Rejected -> Approved still notifies.
                if (oldStatus == 'Approved' && newStatus == 'Rejected') continue;
                
                eligible.add(acc);
                ownerIds.add(acc.OwnerId);
            }
            if (eligible.isEmpty()) return;
            
            Map<Id, User> owners = new Map<Id, User>([
                SELECT Id, FirstName, Email, IsActive
                FROM User
                WHERE Id IN :ownerIds
                WITH SYSTEM_MODE
            ]);
            
            Id templateId = getActiveTemplateId('Credit_Outcome_Notification_CC');
            
            if (templateId != null) {
                List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
                
                for (Account acc : eligible) {
                    User owner = owners.get(acc.OwnerId);
                    if (owner == null || String.isBlank(owner.Email)) {
                        System.debug(LoggingLevel.WARN,
                                     'Skipping email for ' + acc.Id + ' - owner has no usable email address.');
                        continue;
                    }
                    
                    // renderStoredEmailTemplate merges the template against the Account
                    // up front, so no targetObjectId / whatId is required.
                    Messaging.SingleEmailMessage msg =
                        Messaging.renderStoredEmailTemplate(templateId, null, acc.Id);
                    msg.setToAddresses(new List<String>{ owner.Email });
                    msg.setSaveAsActivity(false);
                    messages.add(msg);
                }
                
                sendInBatches(messages);
            } else {
                System.debug(LoggingLevel.ERROR,
                             'Email template Credit_Outcome_Notification_CC not found or inactive.');
            }
            
            sendCreditApprovalNotifications(eligible, owners);
        }
    
    /* ------------------------------------------------------------------
* Custom (bell) notifications
* ------------------------------------------------------------------ */
    private static void sendCreditApprovalNotifications(List<Account> eligible, Map<Id, User> owners) {
        
        List<CustomNotificationType> notifTypes = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = 'Credit_Approval_Outcome_Notification_CC'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (notifTypes.isEmpty()) return;
        
        Id notifTypeId = notifTypes[0].Id;
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        
        for (Account acc : eligible) {
            User owner = owners.get(acc.OwnerId);
            
            String firstName = (owner != null && String.isNotBlank(owner.FirstName))
                ? owner.FirstName
                : 'there';
            
            String creditAssessmentStatus = String.isNotBlank(acc.Financial_Check_CC__c)
                ? acc.Financial_Check_CC__c
                : '';
            
            String creditRiskStatus = blankIfNull(acc.Credit_Risk_Status_CC__c);
            String creditLimit = formatCreditLimit(acc);
            
            String body = 'Hi ' + firstName + ',\n\n'
                + 'The customer credit assessment has been completed.\n\n'
                + 'Key Details:\n'
                + '- Account: ' + acc.Name + '\n'
                + '- Credit Assessment Status: ' + creditAssessmentStatus + '\n'
                + '- Credit Status: ' + acc.Credit_Risk_Status_CC__c + '\n'
                + '- Credit Limit: ' + creditLimit + '\n'
                + '- Assessed By: Finance\n\n'
                + 'Please review the Account in Salesforce and continue with the next appropriate business activity.\n'
                + 'Thank you,\nCarlton Packaging CRM';
            
            if (body.length() > 750) {
                body = body.substring(0, 747) + '...';
            }
            
            Messaging.CustomNotification notif = new Messaging.CustomNotification();
            notif.setNotificationTypeId(notifTypeId);
            notif.setTargetId(acc.Id);
            notif.setTitle('Customer Credit Assessment Completed - ' + acc.Name);
            notif.setBody(body);
            
            try {
                notif.send(new Set<String>{ String.valueOf(acc.OwnerId) });
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                             'Custom notification failed for ' + acc.Id + ': ' + e.getMessage());
            }
        }
    }
    
    /* ------------------------------------------------------------------
* Helpers
* ------------------------------------------------------------------ */
    
    // Apex exposes no API for a currency's symbol, so map the codes the org uses.
    private static final Map<String, String> CURRENCY_SYMBOLS = new Map<String, String>{
        'GBP' => '\u00A3',
            'EUR' => '\u20AC',
            'USD' => '$',
            'INR' => '\u20B9',
            'AUD' => 'A$',
            'CAD' => 'C$',
            'CHF' => 'CHF ',
            'JPY' => '\u00A5',
            'PLN' => 'z\u0142 '
            };
                
                /**
* Returns the ISO currency code for the record. Uses CurrencyIsoCode in
* multi-currency orgs (read dynamically so the class still compiles in
* single-currency orgs), otherwise the org default currency.
*/
                private static String getCurrencyIsoCode(Account acc) {
                    if (UserInfo.isMultiCurrencyOrganization()) {
                        Object iso = acc.get('CurrencyIsoCode');
                        if (iso != null) {
                            return String.valueOf(iso);
                        }
                    }
                    return UserInfo.getDefaultCurrency();
                }
    
    /**
* Formats Credit_Limit_CC__c with its currency symbol, e.g. "\u00A350,000.00".
* Falls back to the ISO code when the symbol is not mapped.
*/
    private static String formatCreditLimit(Account acc) {
        if (acc.Credit_Limit_CC__c == null) return '';
        
        String isoCode = getCurrencyIsoCode(acc);
        String amount  = acc.Credit_Limit_CC__c.setScale(2, System.RoundingMode.HALF_UP).format();
        String symbol  = CURRENCY_SYMBOLS.get(isoCode);
        
        return symbol != null ? symbol + amount : isoCode + ' ' + amount;
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
            for (Integer j = i; j < endIdx; j++) {
                batch.add(messages[j]);
            }
            
            List<Messaging.SendEmailResult> results = Messaging.sendEmail(batch, false);
            logEmailFailures(results);
        }
    }
    private static String blankIfNull(String value) {
        return String.isBlank(value) ? '' : value;
    }
    
    private static void logEmailFailures(List<Messaging.SendEmailResult> results) {
        for (Messaging.SendEmailResult res : results) {
            if (res.isSuccess()) continue;
            for (Messaging.SendEmailError err : res.getErrors()) {
                System.debug(LoggingLevel.ERROR,
                             'Email send failed [' + err.getStatusCode() + ']: ' + err.getMessage()
                             + ' | Fields: ' + err.getFields());
            }
        }
    }
    public static void populateAddressMatchKeys(List<Account> accounts, Map<Id, Account> oldAccountMap) {
        for (Account accountRecord : accounts) {
            // On update, only rebuild when an address field has changed.
            if (oldAccountMap != null && !oldAccountMap.isEmpty()) {
                Account oldAccount = oldAccountMap.get(accountRecord.Id);
                if (oldAccount != null &&
                    accountRecord.BillingCity == oldAccount.BillingCity &&
                    accountRecord.BillingState == oldAccount.BillingState &&
                    accountRecord.BillingPostalCode == oldAccount.BillingPostalCode &&
                    accountRecord.BillingCountry == oldAccount.BillingCountry &&
                    accountRecord.ShippingCity == oldAccount.ShippingCity &&
                    accountRecord.ShippingState == oldAccount.ShippingState &&
                    accountRecord.ShippingPostalCode == oldAccount.ShippingPostalCode &&
                    accountRecord.ShippingCountry == oldAccount.ShippingCountry) {
                        continue;
                    }
            }
            accountRecord.Billing_Address_Match_Key_CC__c = buildAddressMatchKey(accountRecord.BillingCity, accountRecord.BillingState,accountRecord.BillingPostalCode, accountRecord.BillingCountry);
            accountRecord.Shipping_Address_Match_Key_CC__c = buildAddressMatchKey(accountRecord.ShippingCity, accountRecord.ShippingState,accountRecord.ShippingPostalCode, accountRecord.ShippingCountry);
        }
    }
    
    private static String buildAddressMatchKey(String city, String state, String postalCode, String country) {
        List<String> addressParts = new List<String>();
        if (String.isNotBlank(city)) {
            addressParts.add(city.trim().toUpperCase());
        }
        if (String.isNotBlank(state)) {
            addressParts.add(state.trim().toUpperCase());
        }
        if (String.isNotBlank(postalCode)) {
            addressParts.add(postalCode.trim().toUpperCase());
        }
        if (String.isNotBlank(country)) {
            addressParts.add(country.trim().toUpperCase());
        }
        return String.join(addressParts, '|');
    }
    public static void handleAccountGenerationFromLead(List<Account> accountList) {
        if (accountList == null || accountList.isEmpty()) return;
        Map<String, Id> accountRecordTypeIds = new Map<String, Id>();
        for (RecordType rt : [
            SELECT Id, DeveloperName
            FROM RecordType
            WHERE SObjectType = 'Account'
            AND DeveloperName IN ('Entity', 'Site')
            WITH SYSTEM_MODE
        ]) {
            accountRecordTypeIds.put(rt.DeveloperName, rt.Id);
        }
        Id entityRecordTypeId = accountRecordTypeIds.get('Entity');
        Id siteRecordTypeId = accountRecordTypeIds.get('Site');
        for (Account acc : accountList) {
            if (acc.Generated_From_Lead_CC__c != true) continue;
            if (acc.Lead_Type_CC__c == 'Entity') {
                if (acc.RecordTypeId != entityRecordTypeId) {
                    acc.addError('An Entity Lead can only be converted into an Account with the Entity record type.');
                    continue;
                }
            }
            if (acc.Lead_Type_CC__c == 'Site') {
                if (acc.RecordTypeId != siteRecordTypeId) {
                    acc.addError('A Site Lead can only be converted into an Account with the Site record type.');
                    continue;
                }
                if (acc.Lead_Existing_Account_CC__c != null) {
                    acc.ParentId = acc.Lead_Existing_Account_CC__c;
                }
            }
            if (String.isBlank(acc.ShippingStreet)
                && String.isBlank(acc.ShippingCity)
                && String.isBlank(acc.ShippingState)
                && String.isBlank(acc.ShippingPostalCode)
                && String.isBlank(acc.ShippingCountry)) {
                    acc.ShippingStreet = acc.BillingStreet;
                    acc.ShippingCity = acc.BillingCity;
                    acc.ShippingState = acc.BillingState;
                    acc.ShippingPostalCode = acc.BillingPostalCode;
                    acc.ShippingCountry = acc.BillingCountry;
                }
        }
    }
    
    public static void initiateBauOpportunityCreation(List<Account> newAcc, Map<Id, Account> oldAccMap) {
        Set<Id> accIds = new Set<Id>();
        for(Account acc: newAcc) {
            if(acc.Is_BAU_Account_CC__c == TRUE && acc.Is_BAU_Account_CC__c != oldAccMap.get(acc.Id).Is_BAU_Account_CC__c) {
                accIds.add(acc.Id);
            }
        }
        System.debug('accIds--> ' + accIds);
        if(!accIds.isEmpty()) {
            Database.executeBatch(new BAUOpportunityBatch_CC(accIds));
        }
    }
}