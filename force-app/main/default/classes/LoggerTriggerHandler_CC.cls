/**
 * =============================================================================
 * Class Name    : LoggerTriggerHandler_CC
 * Description   : Trigger handler for Logger_CC__c object
 *
 * Author        : Nipun Jain
 * Created Date  : Oct 2026
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Central trigger handler for Logger_CC__c object.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public without sharing class LoggerTriggerHandler_CC extends BaseTriggerHandler_CC {

    public void run() {
        super.run(this, 'Logger_CC_c');
    }

    public override void afterInsert() {
        syncErrorToRecord((List<Logger_CC__c>) Trigger.new);
    }

    public static void syncErrorToRecord(List<Logger_CC__c> newLogs) {
        Map<Id, SObject> recordsToUpdate = new Map<Id, SObject>();

        for(Logger_CC__c log: newLogs) {
            if(log.Log_Level_CC__c == 'ERROR' && log.Source_Type_CC__c == 'Integration') {
                
                String errorMessage;
                
                try {
                    Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(log.Root_Cause_CC__c);
                    Map<String, Object> errorMap = (Map<String, Object>) responseMap.get('error');
                    
                    errorMessage = errorMap != null && errorMap.get('message') != null ? (String) errorMap.get('message') : (String) responseMap.get('message');
                } catch(Exception e) {
                    continue;
                }
                
                if(String.isNotBlank(errorMessage) && String.isNotBlank(log.Related_Record_Ids_CC__c)) {
                    for(String recId: log.Related_Record_Ids_CC__c.split(';')) {
                        Id relatedRecordId;
                        String objectApiName;
                        
                        try {
                            relatedRecordId = (Id) recId.trim();
                            objectApiName = relatedRecordId.getSObjectType().getDescribe().getName();
                        } catch(Exception e) {
                            continue;
                        }
                        
                        switch on objectApiName {
                            when 'Account' {
                                Account acc = new Account(
                                    Id = relatedRecordId,
                                    Business_Central_Customer_Sync_Error_CC__c = errorMessage,
                                    BC_Sync_Status_CC__c = 'Callout Failed'
                                );
                                recordsToUpdate.put(relatedRecordId, acc);
                            }
                            when 'Order' {
                                Order order = new Order(
                                    Id = relatedRecordId,
                                    Business_Central_Customer_Sync_Error_CC__c = errorMessage,
                                    BC_Sync_Status_CC__c = 'Callout Failed'
                                );
                                recordsToUpdate.put(relatedRecordId, order);
                            }
                            when else {
                            }
                        }
                    }
                }            
            }
        }

        if(!recordsToUpdate.isEmpty()) {
            Database.update(recordsToUpdate.values());
        }
    }
}