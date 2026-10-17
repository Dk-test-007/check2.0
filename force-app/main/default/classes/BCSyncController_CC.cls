public with sharing class BCSyncController_CC {
    
    @AuraEnabled
    public static String syncRecord(Id recordId, String objectApiName) {
        try {
            String operation = 'Create'; 

            if (objectApiName == 'Account') {
                // Include Site_Synced_CC__c in the query
                Account acc = [
                    SELECT Id, RecordType.DeveloperName, Site_Synced_CC__c, Parent.Business_Central_Customer_ID_CC__c 
                    FROM Account 
                    WHERE Id = :recordId 
                    WITH SYSTEM_MODE LIMIT 1
                ];
                
                if (acc.RecordType.DeveloperName == 'Site') {
                    // Check the flag to determine the operation
                    operation = acc.Site_Synced_CC__c ? 'SiteUpdate' : 'SiteCreate';
                    
                    if (String.isBlank(acc.Parent?.Business_Central_Customer_ID_CC__c)) {
                        return 'Error: The parent Entity must be synced to Business Central before syncing this Site.';
                    }
                } else {
                    operation = 'Create'; // Entity
                }
            } 
            else if (objectApiName == 'Contact') {
                Contact con = [
                    SELECT Id, Account.Business_Central_Customer_ID_CC__c 
                    FROM Contact 
                    WHERE Id = :recordId 
                    WITH SYSTEM_MODE LIMIT 1
                ];
                
                if (String.isBlank(con.Account?.Business_Central_Customer_ID_CC__c)) {
                    return 'Error: The parent Account/Site must be synced to Business Central before syncing this Contact.';
                }
                operation = 'Create';
            } 
            else if (objectApiName == 'Order') {
                operation = 'Create';
            } 
            else {
                return 'Error: Business Central sync is not configured for the ' + objectApiName + ' object.';
            }

            CalloutService_CC.send(new Set<Id>{ recordId }, operation);
            return 'Success';
            
        } catch (Exception e) {
            return 'Error: ' + e.getMessage();
        }
    }
}