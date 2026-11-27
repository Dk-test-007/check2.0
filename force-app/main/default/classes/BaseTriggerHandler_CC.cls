/**
 * =============================================================================
 * Class Name    : BaseTriggerHandler_CC
 * Description   : Base Trigger handler for all triggers
 *
 * Author        : Vansh Mansotra
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author           Description
 * -------    ----------   ------------     ---------------------------------------
 *    1                    Vansh Mansotra   Initial setup for base trigger handler
 *    2                    Vansh Mansotra   Added try/catch with error logging
 *    3       2026-10-22   Devander Kumra   Added label driven delete restriction by
 *                                          object and profile
 *
 * =============================================================================
 * Usage: To get trigger context, use metadata before triggering the context & log errors
 * =============================================================================
 */
public virtual without sharing class BaseTriggerHandler_CC {




    /*
     * Triggers on these objects must never log - doing so publishes an event that
     * re-enters this class and publishes again.
     */
    private static final Set<SObjectType> LOGGING_OBJECTS = new Set<SObjectType>{
        Logger_Event_CC__e.SObjectType,
        Logger_CC__c.SObjectType
    };




    @TestVisible
    private static final String DELETE_RESTRICTED_MESSAGE = 'You do not have permission to delete this record.';




    @TestVisible
    private static String deleteRestrictedObjects = System.Label.Delete_Restricted_Objects_CC;
    @TestVisible
    private static String deleteRestrictedProfiles = System.Label.Delete_Restricted_Profiles_CC;




    private static String currentProfileName;




    public void run(BaseTriggerHandler_CC handler, String objectApiName) {




        Trigger_Framework_Config_CC__mdt config =
            Trigger_Framework_Config_CC__mdt.getInstance(objectApiName);
        
        if (Trigger.isExecuting != true) {
        System.debug(LoggingLevel.WARN, 'BaseTriggerHandler_CC: run() called outside trigger context for "' + objectApiName + '" - nothing will run.');
        return;
        }




        // Runs ahead of the config check so the restriction applies regardless of Before_Delete_CC__c
        if (Trigger.isBefore && Trigger.isDelete && preventRestrictedDeletion(Trigger.old)) {
            return;
        }




        if (config == null) {
            System.debug(LoggingLevel.WARN,'BaseTriggerHandler_CC: no Trigger_Framework_Config_CC__mdt record for "' +objectApiName + '" - nothing will run.');
            return;
        }




        if (Trigger.isBefore) {
            if (Trigger.isInsert && config.Before_Insert_CC__c) {
                beforeInsertBase(handler);
            }
            if (Trigger.isUpdate && config.Before_Update_CC__c) {
                beforeUpdateBase(handler);
            }
            if (Trigger.isDelete && config.Before_Delete_CC__c) {
                beforeDeleteBase(handler);
            }
        }




        if (Trigger.isAfter) {
            if (Trigger.isInsert && config.After_Insert_CC__c) {
                afterInsertBase(handler);
            }
            if (Trigger.isUpdate && config.After_Update_CC__c) {
                afterUpdateBase(handler);
            }
            if (Trigger.isDelete && config.After_Delete_CC__c) {
                afterDeleteBase(handler);
            }
            if (Trigger.isUndelete && config.After_Undelete_CC__c) {
                afterUndeleteBase(handler);
            }
        }
    }




    public static void beforeInsertBase(BaseTriggerHandler_CC handler) {
        System.debug('##### ---- Before Insert started ---- #####');
        System.debug('### Trigger.new value ----- ' + Trigger.new);
        try {
            handler.beforeInsert();
        } catch (Exception ex) {
            handleError(handler, 'Before Insert', ex, Trigger.new);
        }
        System.debug('##### ---- Before Insert ended ---- #####');
    }




    public static void beforeUpdateBase(BaseTriggerHandler_CC handler) {
        System.debug('##### ---- Before Update started ---- #####');
        System.debug('### Trigger.new value ----- ' + Trigger.new);
        System.debug('### Trigger.old value ----- ' + Trigger.old);
        try {
            handler.beforeUpdate();
        } catch (Exception ex) {
            handleError(handler, 'Before Update', ex, Trigger.new);
        }
        System.debug('##### ---- Before Update ended ---- #####');
    }




    public static void beforeDeleteBase(BaseTriggerHandler_CC handler) {
        System.debug('##### ---- Before Delete started ---- #####');
        System.debug('### Trigger.old value ----- ' + Trigger.old);
        try {
            handler.beforeDelete();
        } catch (Exception ex) {
            handleError(handler, 'Before Delete', ex, Trigger.old);
        }
        System.debug('##### ---- Before Delete ended ---- #####');
    }




    public static void afterInsertBase(BaseTriggerHandler_CC handler) {
        System.debug('##### ---- After Insert started ---- #####');
        System.debug('### Trigger.new value ----- ' + Trigger.new);
        try {
            handler.afterInsert();
        } catch (Exception ex) {
            handleError(handler, 'After Insert', ex, Trigger.new);
        }
        System.debug('##### ---- After Insert ended ---- #####');
    }




    public static void afterUpdateBase(BaseTriggerHandler_CC handler) {
        System.debug('##### ---- After Update started ---- #####');
        System.debug('### Trigger.new value ----- ' + Trigger.new);
        try {
            handler.afterUpdate();
        } catch (Exception ex) {
            handleError(handler, 'After Update', ex, Trigger.new);
        }
        System.debug('##### ---- After Update ended ---- #####');
    }




    public static void afterDeleteBase(BaseTriggerHandler_CC handler) {
        System.debug('##### ---- After Delete started ---- #####');
        System.debug('### Trigger.old value ----- ' + Trigger.old);
        try {
            handler.afterDelete();
        } catch (Exception ex) {
            handleError(handler, 'After Delete', ex, Trigger.old);
        }
        System.debug('##### ---- After Delete ended ---- #####');
    }




    public static void afterUndeleteBase(BaseTriggerHandler_CC handler) {
        System.debug('##### ---- After Undelete started ---- #####');
        System.debug('### Trigger.new value ----- ' + Trigger.new);
        try {
            handler.afterUndelete();
        } catch (Exception ex) {
            handleError(handler, 'After Undelete', ex, Trigger.new);
        }
        System.debug('##### ---- After Undelete ended ---- #####');
    }




    // ===================================================================== delete restriction
    /**
     * Adds an error to every record when the running user's profile may not delete this object.
     * Returns true when the deletion was blocked.
     */
    @TestVisible
    private static Boolean preventRestrictedDeletion(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            return false;
        }
        String objectApiName = records[0].getSObjectType().getDescribe().getName();
        if (!isDeletionRestricted(objectApiName)) {
            return false;
        }
        for (SObject record : records) {
            record.addError(DELETE_RESTRICTED_MESSAGE);
        }
        return true;
    }




    @TestVisible
    private static Boolean isDeletionRestricted(String objectApiName) {
        // Object check first so the Profile query only runs for restricted objects
        return splitLabel(deleteRestrictedObjects).contains(objectApiName.toLowerCase())
            && splitLabel(deleteRestrictedProfiles).contains(getCurrentProfileName().toLowerCase());
    }




    private static String getCurrentProfileName() {
        if (currentProfileName == null) {
            currentProfileName = [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() LIMIT 1].Name;
        }
        return currentProfileName;
    }




    private static Set<String> splitLabel(String labelValue) {
        Set<String> values = new Set<String>();
        if (String.isBlank(labelValue)) {
            return values;
        }
        for (String value : labelValue.split(',')) {
            if (String.isNotBlank(value)) {
                values.add(value.trim().toLowerCase());
            }
        }
        return values;
    }




    // ===================================================================== error handling
    private static void handleError(BaseTriggerHandler_CC handler, String contextName, Exception ex, List<SObject> records) {
        String handlerName = handlerNameOf(handler);
        System.debug(LoggingLevel.ERROR,'BaseTriggerHandler_CC: ' + handlerName + ' ' + contextName + ' failed - ' +ex.getTypeName() + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString());
        /*
         * The logging objects get the debug log above and nothing else. Calling Logger here
         * would publish an event, which re-enters this class, which publishes again.
         */
        if (isLoggingContext()) {
            return;
        }
        Logger_CC.LogInput input = new Logger_CC.LogInput(Logger_CC.ERROR,handlerName + ' - ' + contextName + ' failed: ' + ex.getMessage());
        input.sourceType       = 'Trigger';
        input.sourceClass      = handlerName;
        input.relatedRecordIds = idsOf(records);
        input.comments         = ex.getTypeName() + ': ' + ex.getMessage() +'\nLine ' + ex.getLineNumber() +'\n' + ex.getStackTraceString();
        Logger_CC.log(input);
        throw ex;
    }




    /**
     * True when the trigger currently executing belongs to the logging framework itself.
     */
    @TestVisible
    private static Boolean isLoggingContext() {
        SObjectType currentType = currentSObjectType();
        return currentType != null && LOGGING_OBJECTS.contains(currentType);
    }




    private static SObjectType currentSObjectType() {
        if (Trigger.new != null && !Trigger.new.isEmpty()) {
            return Trigger.new[0].getSObjectType();
        }
        if (Trigger.old != null && !Trigger.old.isEmpty()) {
            return Trigger.old[0].getSObjectType();
        }
        return null;
    }




    private static String idsOf(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            return null;
        }
        List<String> ids = new List<String>();
        for (SObject record : records) {
            if (record.Id != null) {
                ids.add(String.valueOf(record.Id));
            }
            if (ids.size() == 100) {   // keep the field bounded on large batches
                break;
            }
        }
        return ids.isEmpty() ? null : String.join(ids, ';');
    }




    /** Apex has no getClass(); String.valueOf on an instance yields "ClassName:[...]". */
    private static String handlerNameOf(BaseTriggerHandler_CC handler) {
        return handler == null ? 'UnknownHandler' : String.valueOf(handler).substringBefore(':');
    }




    /*
     * Trigger context methods.
     * Object-specific handlers override only the methods they require.
     */
    protected virtual void beforeInsert() {}
    protected virtual void beforeUpdate() {}
    protected virtual void beforeDelete() {}
    protected virtual void afterInsert() {}
    protected virtual void afterUpdate() {}
    protected virtual void afterDelete() {}
    protected virtual void afterUndelete() {}
}