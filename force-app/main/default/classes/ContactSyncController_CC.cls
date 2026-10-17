public with sharing class ContactSyncController_CC {
    
    @AuraEnabled
    public static String syncContact(Id contactId) {
        try {
            // Include Email, Phone, and MobilePhone in the query
            Contact con = [
                SELECT Id, Email, Phone, MobilePhone, Account.Business_Central_Customer_ID_CC__c 
                FROM Contact 
                WHERE Id = :contactId 
                WITH SYSTEM_MODE 
                LIMIT 1
            ];
            
            // 1. Validate Parent Account is synced
            if (String.isBlank(con.Account?.Business_Central_Customer_ID_CC__c)) {
                return 'Error: The parent Account/Site must be synced to Business Central before syncing this Contact.';
            }
            
            // 2. Validate Contact has at least one contact method
            if (String.isBlank(con.Email) && String.isBlank(con.Phone) && String.isBlank(con.MobilePhone)) {
                return 'Error: Contact must have an Email, Phone, or Mobile populated before it can be synced to Business Central.';
            }
            
            // 3. Dispatch the Callout
            CalloutService_CC.send(new Set<Id>{ contactId }, 'Create');
            
            return 'Success';
            
        } catch (Exception e) {
            return 'Error: ' + e.getMessage();
        }
    }
}