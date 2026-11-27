/**
 * =============================================================================
 * Class Name    : ZoomInfoMappingBatch_CC
 * Description   : Applies the ZoomInfo Field Mapping CC metadata to records that the
 *                 ZoomInfo service account user has just inserted.
 *                 Today: Lead.LeadSource, Account.AccountSource, Contact.LeadSource = ZoomInfo.
 *                 New mappings are added as metadata records - no code change needed.
 *
 * Author        : Devander Kumra
 * Created Date  : 18-11-2026
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author           Description
 * -------    ----------   ------------     ---------------------------------------
 *    1       18-11-2026   Devander Kumra   Initial version
 *
 * =============================================================================
 * Usage: Called from the afterInsert() of the Lead, Account and Contact trigger handlers:
 *            ZoomInfoMappingBatch_CC.processInsertedRecords('Lead', (List<Lead>) Trigger.new);
 *        Only records whose CreatedById is the ZoomInfo service user (the active user
 *        whose Name equals Custom Label ZoomInfo_Service_User_Name_CC) are processed.
 *        Mappings are read from ZoomInfo_Field_Mapping_CC__mdt (Active rows only).
 *        Can also be run by hand for specific records:
 *            Database.executeBatch(new ZoomInfoMappingBatch_CC('Lead', leadIds), 200);
 *        If a batch cannot be queued (already inside a batch/future, or the flex queue
 *        is full) the mappings are applied in the same transaction instead, so a
 *        ZoomInfo import never fails because of this class.
 * =============================================================================
 */
public without sharing class ZoomInfoMappingBatch_CC implements Database.Batchable<SObject> {

    @TestVisible
    private static final Integer BATCH_SIZE = 200;
    private static final String CLASS_NAME = 'ZoomInfoMappingBatch_CC';
    private static final String INTEGRATION_NAME = 'ZoomInfo';

    @TestVisible
    private static Boolean forceSynchronous = false;
    @TestVisible
    private static List<ZoomInfo_Field_Mapping_CC__mdt> mockMappings;

    @TestVisible
    private static Id serviceUserId;
    private static Boolean serviceUserResolved = false;
    private static Map<String, List<ZoomInfo_Field_Mapping_CC__mdt>> mappingCache =
        new Map<String, List<ZoomInfo_Field_Mapping_CC__mdt>>();

    // Batch state - mappings are captured when the job is queued so the job is self-contained.
    private final String objectApiName;
    private final Set<Id> recordIds;
    private final List<ZoomInfo_Field_Mapping_CC__mdt> mappings;

    public ZoomInfoMappingBatch_CC(String objectApiName, Set<Id> recordIds) {
        this.objectApiName = objectApiName;
        this.recordIds = recordIds == null ? new Set<Id>() : recordIds;
        this.mappings = validMappings(objectApiName);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocatorWithBinds(buildQuery(objectApiName, mappings), new Map<String, Object>{ 'recordIds' => recordIds }, AccessLevel.SYSTEM_MODE);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        saveChanges(applyMappings(scope, mappings));
    }

    public void finish(Database.BatchableContext bc) {}

    public static void processInsertedRecords(String objectApiName, List<SObject> newRecords) {
        if (newRecords == null || newRecords.isEmpty()) {
            return;
        }
        Id zoomInfoUserId = getServiceUserId();
        if (zoomInfoUserId == null) {
            return;
        }
        Set<Id> recordIds = new Set<Id>();
        for (SObject record : newRecords) {
            if (record.get('CreatedById') == zoomInfoUserId) {
                recordIds.add(record.Id);
            }
        }
        enqueue(objectApiName, recordIds);
    }

    /** The active user whose Name matches Custom Label ZoomInfo_Service_User_Name_CC, or null. */
    @TestVisible
    private static Id getServiceUserId() {
        if (serviceUserId == null && !serviceUserResolved) {
            serviceUserResolved = true;
            String userName = System.Label.ZoomInfo_Service_User_Name_CC;
            List<User> users = [SELECT Id FROM User WHERE Name = :userName AND IsActive = TRUE ORDER BY CreatedDate ASC LIMIT 1];
            serviceUserId = users.isEmpty() ? null : users[0].Id;
        }
        return serviceUserId;
    }

    public static void enqueue(String objectApiName, Set<Id> recordIds) {
        if (recordIds == null || recordIds.isEmpty() || validMappings(objectApiName).isEmpty()) {
            return;
        }
        if (forceSynchronous || System.isBatch() || System.isFuture()) {
            applyNow(objectApiName, recordIds);
            return;
        }
        try {
            Database.executeBatch(new ZoomInfoMappingBatch_CC(objectApiName, recordIds), BATCH_SIZE);
        } catch (AsyncException ex) {
            // Typically "exceeded the limit of 100 jobs in the flex queue" during a very large import.
            Logger_CC.log(Logger_CC.ERROR,
                CLASS_NAME + ' could not be queued for ' + objectApiName + ' - mappings applied synchronously instead.',
                ex, new List<Id>(recordIds));
            applyNow(objectApiName, recordIds);
        }
    }

    @TestVisible
    private static void applyNow(String objectApiName, Set<Id> recordIds) {
        List<ZoomInfo_Field_Mapping_CC__mdt> objectMappings = validMappings(objectApiName);
        if (objectMappings.isEmpty()) {
            return;
        }
        List<SObject> records = Database.queryWithBinds(
            buildQuery(objectApiName, objectMappings),
            new Map<String, Object>{ 'recordIds' => recordIds },
            AccessLevel.SYSTEM_MODE
        );
        saveChanges(applyMappings(records, objectMappings));
    }

    // mapping logic

    @TestVisible
    private static List<SObject> applyMappings(List<SObject> records, List<ZoomInfo_Field_Mapping_CC__mdt> objectMappings) {
        List<SObject> changed = new List<SObject>();
        if (records == null || records.isEmpty() || objectMappings == null || objectMappings.isEmpty()) {
            return changed;
        }

        Map<String, Schema.SObjectField> fieldMap = records[0].getSObjectType().getDescribe().fields.getMap();
        List<Object> fixedValues = new List<Object>();
        for (ZoomInfo_Field_Mapping_CC__mdt mapping : objectMappings) {
            fixedValues.add(String.isNotBlank(mapping.Source_Field_API_Name_CC__c)
                ? null
                : convert(mapping.Value_CC__c, fieldMap.get(mapping.Target_Field_API_Name_CC__c.trim().toLowerCase()).getDescribe().getType()));
        }

        for (SObject record : records) {
            SObject delta = record.getSObjectType().newSObject(record.Id);
            Boolean hasChange = false;
            for (Integer i = 0; i < objectMappings.size(); i++) {
                ZoomInfo_Field_Mapping_CC__mdt mapping = objectMappings[i];
                String target = mapping.Target_Field_API_Name_CC__c.trim();
                Object current = record.get(target);
                if (mapping.Overwrite_Existing_CC__c != true && !isBlank(current)) {
                    continue;
                }
                Object newValue = String.isNotBlank(mapping.Source_Field_API_Name_CC__c)
                    ? record.get(mapping.Source_Field_API_Name_CC__c.trim())
                    : fixedValues[i];
                if (newValue != current) {
                    delta.put(target, newValue);
                    record.put(target, newValue);
                    hasChange = true;
                }
            }
            if (hasChange) {
                changed.add(delta);
            }
        }
        return changed;
    }

    private static void saveChanges(List<SObject> changed) {
        if (changed == null || changed.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(changed, false, AccessLevel.SYSTEM_MODE);
        List<Logger_CC.LogInput> failures = new List<Logger_CC.LogInput>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            List<String> messages = new List<String>();
            for (Database.Error error : results[i].getErrors()) {
                messages.add(error.getStatusCode() + ': ' + error.getMessage() + ' ' + error.getFields());
            }
            Logger_CC.LogInput input = new Logger_CC.LogInput(Logger_CC.ERROR, 'ZoomInfo field mapping could not be saved.');
            input.sourceType       = 'Batch';
            input.sourceClass      = CLASS_NAME;
            input.integrationName  = INTEGRATION_NAME;
            input.relatedRecordIds = String.valueOf(changed[i].Id);
            input.comments         = String.join(messages, '\n');
            failures.add(input);
        }
        Logger_CC.log(failures);
    }

    // metadata
    @TestVisible
    private static List<ZoomInfo_Field_Mapping_CC__mdt> validMappings(String objectApiName) {
        String cacheKey = String.isBlank(objectApiName) ? '' : objectApiName.toLowerCase();
        if (mappingCache.containsKey(cacheKey)) {
            return mappingCache.get(cacheKey);
        }

        List<ZoomInfo_Field_Mapping_CC__mdt> result = new List<ZoomInfo_Field_Mapping_CC__mdt>();
        List<String> problems = new List<String>();
        Map<String, Schema.SObjectField> fieldMap = fieldsOf(objectApiName);

        for (ZoomInfo_Field_Mapping_CC__mdt mapping : allMappings()) {
            if (mapping.Active_CC__c != true
                    || String.isBlank(mapping.Object_API_Name_CC__c)
                    || !mapping.Object_API_Name_CC__c.trim().equalsIgnoreCase(objectApiName)) {
                continue;
            }
            String problem = validate(mapping, fieldMap);
            if (problem == null) {
                result.add(mapping);
            } else {
                problems.add(mapping.DeveloperName + ': ' + problem);
            }
        }

        if (!problems.isEmpty()) {
            Logger_CC.log(Logger_CC.ERROR,
                'ZoomInfo Field Mapping CC - invalid mappings skipped for ' + objectApiName,
                String.join(problems, '\n'));
        }
        mappingCache.put(cacheKey, result);
        return result;
    }

    /** Lets tests replace the metadata rows. */
    @TestVisible
    private static void setMappings(List<ZoomInfo_Field_Mapping_CC__mdt> mappings) {
        mockMappings = mappings;
        mappingCache.clear();
    }

    private static List<ZoomInfo_Field_Mapping_CC__mdt> allMappings() {
        if (mockMappings != null) {
            return mockMappings;
        }
        return [SELECT DeveloperName, Active_CC__c, Object_API_Name_CC__c, Target_Field_API_Name_CC__c,
                       Value_CC__c, Source_Field_API_Name_CC__c, Overwrite_Existing_CC__c
                FROM ZoomInfo_Field_Mapping_CC__mdt
                WHERE Active_CC__c = TRUE
                ORDER BY DeveloperName];
    }

    private static String validate(ZoomInfo_Field_Mapping_CC__mdt mapping, Map<String, Schema.SObjectField> fieldMap) {
        if (fieldMap == null) {
            return 'object ' + mapping.Object_API_Name_CC__c + ' does not exist';
        }
        String target = mapping.Target_Field_API_Name_CC__c == null ? '' : mapping.Target_Field_API_Name_CC__c.trim();
        Schema.SObjectField targetField = fieldMap.get(target.toLowerCase());
        if (targetField == null) {
            return 'target field "' + target + '" does not exist';
        }
        Schema.DescribeFieldResult describe = targetField.getDescribe();
        if (describe.isCalculated() || describe.isAutoNumber()) {
            return 'target field "' + target + '" cannot be written';
        }
        if (String.isNotBlank(mapping.Source_Field_API_Name_CC__c)) {
            if (!fieldMap.containsKey(mapping.Source_Field_API_Name_CC__c.trim().toLowerCase())) {
                return 'source field "' + mapping.Source_Field_API_Name_CC__c + '" does not exist';
            }
            return null;
        }
        try {
            convert(mapping.Value_CC__c, describe.getType());
        } catch (Exception ex) {
            return 'value "' + mapping.Value_CC__c + '" is not valid for ' + describe.getType() + ' field ' + target;
        }
        return null;
    }

    private static Map<String, Schema.SObjectField> fieldsOf(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            return null;
        }
        try {
            return Schema.describeSObjects(new List<String>{ objectApiName })[0].fields.getMap();
        } catch (InvalidParameterValueException ex) {
            return null;
        }
    }

    @TestVisible
    private static Object convert(String raw, Schema.DisplayType fieldType) {
        if (String.isBlank(raw)) {
            return null;
        }
        String value = raw.trim();
        switch on fieldType {
            when BOOLEAN {
                return Boolean.valueOf(value);
            }
            when INTEGER {
                return Integer.valueOf(value);
            }
            when LONG {
                return Long.valueOf(value);
            }
            when DOUBLE, CURRENCY, PERCENT {
                return Decimal.valueOf(value);
            }
            when DATE {
                return Date.valueOf(value);
            }
            when DATETIME {
                return Datetime.valueOfGmt(value);
            }
            when else {
                return value;
            }
        }
    }

    private static Boolean isBlank(Object value) {
        return value == null || (value instanceof String && String.isBlank((String) value));
    }

    private static String buildQuery(String objectApiName, List<ZoomInfo_Field_Mapping_CC__mdt> objectMappings) {
        Set<String> fields = new Set<String>{ 'id' };
        for (ZoomInfo_Field_Mapping_CC__mdt mapping : objectMappings) {
            fields.add(mapping.Target_Field_API_Name_CC__c.trim().toLowerCase());
            if (String.isNotBlank(mapping.Source_Field_API_Name_CC__c)) {
                fields.add(mapping.Source_Field_API_Name_CC__c.trim().toLowerCase());
            }
        }
        return 'SELECT ' + String.join(new List<String>(fields), ', ')
             + ' FROM ' + String.escapeSingleQuotes(objectApiName)
             + ' WHERE Id IN :recordIds';
    }
}
