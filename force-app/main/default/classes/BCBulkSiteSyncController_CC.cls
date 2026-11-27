/**
 * Controller for the bcBulkSiteSync_CC quick action on the Entity record page.
 *
 * Lists all child Sites of an Entity, separates the Sites that are missing
 * mandatory fields, and sends only the Sites the user selects to Business Central.
 *
 * Mandatory fields are read from the Request Mapping of the Integration Config
 * custom metadata record used for Site creation (Site_BC_Create). Every field sent
 * to Business Central in that mapping must have a value before a Site can be synced,
 * so the check always matches the integration without a code change.
 */
public without sharing class BCBulkSiteSyncController_CC {

    // Integration Config custom metadata. Confirm these API names match the org.
    @TestVisible private static final String CONFIG_OBJECT = 'Integration_Config__mdt';
    @TestVisible private static final String CONFIG_REQUEST_MAPPING_FIELD = 'Request_Mapping__c';
    @TestVisible private static final String SITE_CREATE_CONFIG = 'Site_BC_Create';

    // Fields in the mapping that are always populated and do not need checking.
    private static final Set<String> FIELDS_NOT_CHECKED = new Set<String>{ 'id' };
    private static final String SITE_RECORD_TYPE = 'Site';
    private static final Integer USER_ACCESS_BATCH_SIZE = 200;

    public class SiteRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String recordUrl;
        @AuraEnabled public String syncType;   // 'New' or 'Update'
        @AuraEnabled public String issue;      // populated for Sites that cannot be synced
        public Boolean isSynced = false;
    }

    public class SyncSummary {
        @AuraEnabled public String entityName;
        @AuraEnabled public Boolean canSync = false;
        @AuraEnabled public String blockingMessage;
        @AuraEnabled public Integer totalSites = 0;
        @AuraEnabled public List<SiteRow> eligibleSites = new List<SiteRow>();
        @AuraEnabled public List<SiteRow> excludedSites = new List<SiteRow>();
    }

    /**
     * One field from the Request Mapping, resolved against the Account schema.
     */
    private class MandatoryField {
        public String path;
        public String label;
        public Boolean isCheckbox = false;
    }

    private class ConfigException extends Exception {}

    public class SyncResult {
        @AuraEnabled public Integer createdCount = 0;
        @AuraEnabled public Integer updatedCount = 0;
        @AuraEnabled public Integer skippedCount = 0;
    }

    /**
     * Called when the action opens. Read-only: nothing is sent to Business Central.
     */
    @AuraEnabled
    public static SyncSummary getSiteSyncSummary(Id entityId) {
        try {
            return evaluate(entityId);
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    /**
     * Called only after the user confirms. All checks are re-run server-side and only
     * Sites that the user selected AND are still eligible are sent.
     */
    @AuraEnabled
    public static SyncResult syncSites(Id entityId, List<Id> siteIds) {
        try {
            if (siteIds == null || siteIds.isEmpty()) {
                throw auraError('Select at least one Site to sync.');
            }

            SyncSummary summary = evaluate(entityId);
            if (!summary.canSync) {
                throw auraError(summary.blockingMessage);
            }

            Set<Id> requested = new Set<Id>(siteIds);
            Set<Id> createIds = new Set<Id>();
            Set<Id> updateIds = new Set<Id>();

            for (SiteRow row : summary.eligibleSites) {
                if (!requested.contains(row.id)) {
                    continue;
                }
                if (row.isSynced) {
                    updateIds.add(row.id);
                } else {
                    createIds.add(row.id);
                }
            }

            SyncResult result = new SyncResult();
            result.createdCount = createIds.size();
            result.updatedCount = updateIds.size();
            result.skippedCount = requested.size() - createIds.size() - updateIds.size();

            if (createIds.isEmpty() && updateIds.isEmpty()) {
                throw auraError('None of the selected Sites can be synced. Close this window, refresh the page and check the Sites again.');
            }

            if (!createIds.isEmpty()) {
                CalloutService_CC.send(createIds, 'SiteCreate');
            }
            if (!updateIds.isEmpty()) {
                CalloutService_CC.send(updateIds, 'SiteUpdate');
            }
            return result;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    // ---------------------------------------------------------------------
    // Evaluation
    // ---------------------------------------------------------------------

    private static SyncSummary evaluate(Id entityId) {
        SyncSummary summary = new SyncSummary();

        if (entityId == null || entityId.getSObjectType() != Account.SObjectType) {
            return block(summary, 'This action can only be used on an Entity.');
        }

        Account entity = [
            SELECT Id, Name, RecordType.DeveloperName, Business_Central_Customer_ID_CC__c
            FROM Account
            WHERE Id = :entityId
            WITH SYSTEM_MODE LIMIT 1
        ];
        summary.entityName = entity.Name;

        if (entity.RecordType?.DeveloperName == SITE_RECORD_TYPE) {
            return block(summary, 'This action can only be used on an Entity, not on a Site.');
        }
        if (String.isBlank(entity.Business_Central_Customer_ID_CC__c)) {
            return block(summary, 'This Entity must be synced to Business Central before its Sites can be synced.');
        }
        if (!Schema.SObjectType.Account.isUpdateable()) {
            return block(summary, 'You do not have permission to edit Sites, so you cannot sync them to Business Central.');
        }

        List<MandatoryField> mandatoryFields;
        try {
            mandatoryFields = getMandatoryFields();
        } catch (ConfigException e) {
            return block(summary, e.getMessage() + ' Please contact your Salesforce administrator.');
        }

        List<Account> sites = querySites(entityId, mandatoryFields);
        summary.totalSites = sites.size();
        if (sites.isEmpty()) {
            return block(summary, 'This Entity has no Sites to sync.');
        }

        Set<Id> siteIds = new Map<Id, Account>(sites).keySet();
        Set<Id> editableIds = getEditableIds(siteIds);

        for (Account site : sites) {
            SiteRow row = new SiteRow();
            row.id = site.Id;
            row.name = site.Name;
            row.recordUrl = '/lightning/r/Account/' + site.Id + '/view';
            row.isSynced = site.Site_Synced_CC__c == true;
            row.syncType = row.isSynced ? 'Update' : 'New';

            List<String> issues = new List<String>();
            List<String> missing = getMissingFieldLabels(site, mandatoryFields);
            if (!missing.isEmpty()) {
                issues.add('Missing: ' + String.join(missing, ', '));
            }
            if (!editableIds.contains(site.Id)) {
                issues.add('You do not have edit access to this Site');
            }

            if (issues.isEmpty()) {
                summary.eligibleSites.add(row);
            } else {
                row.issue = String.join(issues, '. ');
                summary.excludedSites.add(row);
            }
        }

        summary.canSync = true;
        return summary;
    }

    /**
     * Reads the Request Mapping (a JSON list of Account field paths) from the
     * Site_BC_Create Integration Config record and resolves each field against
     * the Account schema to get its label and type.
     */
    private static List<MandatoryField> getMandatoryFields() {
        String soql = 'SELECT DeveloperName, ' + CONFIG_REQUEST_MAPPING_FIELD
            + ' FROM ' + CONFIG_OBJECT
            + ' WHERE DeveloperName = :configName LIMIT 1';
        List<SObject> configs;
        try {
            configs = Database.queryWithBinds(
                soql,
                new Map<String, Object>{ 'configName' => SITE_CREATE_CONFIG },
                AccessLevel.SYSTEM_MODE
            );
        } catch (QueryException e) {
            // Usually means CONFIG_OBJECT or CONFIG_REQUEST_MAPPING_FIELD does not match the org.
            throw new ConfigException('Could not read the Integration Config metadata: ' + e.getMessage());
        }

        if (configs.isEmpty()) {
            throw new ConfigException('The Integration Config record "' + SITE_CREATE_CONFIG + '" was not found.');
        }

        String mapping = (String) configs[0].get(CONFIG_REQUEST_MAPPING_FIELD);
        if (String.isBlank(mapping)) {
            throw new ConfigException('The Request Mapping on Integration Config "' + SITE_CREATE_CONFIG + '" is empty.');
        }

        List<Object> fieldPaths;
        try {
            fieldPaths = (List<Object>) JSON.deserializeUntyped(mapping);
        } catch (Exception e) {
            throw new ConfigException('The Request Mapping on Integration Config "' + SITE_CREATE_CONFIG
                + '" is not a valid list of field names.');
        }

        List<MandatoryField> fields = new List<MandatoryField>();
        List<String> invalidPaths = new List<String>();
        Set<String> seen = new Set<String>();

        for (Object item : fieldPaths) {
            if (item == null) {
                continue;
            }
            String path = String.valueOf(item).trim();
            if (String.isBlank(path) || FIELDS_NOT_CHECKED.contains(path.toLowerCase()) || !seen.add(path.toLowerCase())) {
                continue;
            }
            MandatoryField field = resolveField(path);
            if (field == null) {
                invalidPaths.add(path);
            } else {
                fields.add(field);
            }
        }

        if (!invalidPaths.isEmpty()) {
            throw new ConfigException('The Request Mapping on Integration Config "' + SITE_CREATE_CONFIG
                + '" contains fields that do not exist on Account: ' + String.join(invalidPaths, ', ') + '.');
        }
        return fields;
    }

    /**
     * Resolves a field path such as "GLN_CC__c" or "Parent.Business_Central_Customer_ID_CC__c"
     * against the Account schema. Returns null if any part of the path does not exist.
     */
    private static MandatoryField resolveField(String path) {
        List<String> parts = path.split('\\.');
        Schema.SObjectType currentType = Account.SObjectType;
        List<String> labelParts = new List<String>();

        for (Integer i = 0; i < parts.size(); i++) {
            Map<String, Schema.SObjectField> fieldMap = currentType.getDescribe().fields.getMap();
            Boolean isLast = i == parts.size() - 1;

            if (isLast) {
                Schema.SObjectField sObjField = fieldMap.get(parts[i]);
                if (sObjField == null) {
                    return null;
                }
                Schema.DescribeFieldResult describe = sObjField.getDescribe();
                labelParts.add(describe.getLabel());

                MandatoryField field = new MandatoryField();
                field.path = path;
                field.label = String.join(labelParts, ' > ');
                field.isCheckbox = describe.getType() == Schema.DisplayType.BOOLEAN;
                return field;
            }

            // Relationship hop, e.g. "Parent" or "Custom_Lookup__r"
            Schema.DescribeFieldResult lookup = findRelationship(fieldMap, parts[i]);
            if (lookup == null || lookup.getReferenceTo().isEmpty()) {
                return null;
            }
            labelParts.add(lookup.getRelationshipName());
            currentType = lookup.getReferenceTo()[0];
        }
        return null;
    }

    private static Schema.DescribeFieldResult findRelationship(Map<String, Schema.SObjectField> fieldMap, String relationshipName) {
        for (Schema.SObjectField sObjField : fieldMap.values()) {
            Schema.DescribeFieldResult describe = sObjField.getDescribe();
            if (describe.getRelationshipName() != null
                    && describe.getRelationshipName().equalsIgnoreCase(relationshipName)) {
                return describe;
            }
        }
        return null;
    }

    private static List<Account> querySites(Id entityId, List<MandatoryField> mandatoryFields) {
        List<String> fields = new List<String>{ 'Id', 'Name', 'Site_Synced_CC__c' };
        Set<String> seen = new Set<String>{ 'id', 'name', 'site_synced_cc__c' };

        for (MandatoryField field : mandatoryFields) {
            if (seen.add(field.path.toLowerCase())) {
                fields.add(field.path);
            }
        }

        // Field paths come from admin-managed metadata and are validated against the schema above.
        String soql = 'SELECT ' + String.join(fields, ', ')
            + ' FROM Account'
            + ' WHERE ParentId = :entityId AND RecordType.DeveloperName = :siteRecordType'
            + ' ORDER BY Name';

        return Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'entityId' => entityId, 'siteRecordType' => SITE_RECORD_TYPE },
            AccessLevel.SYSTEM_MODE
        );
    }

    private static List<String> getMissingFieldLabels(Account site, List<MandatoryField> mandatoryFields) {
        List<String> missing = new List<String>();
        for (MandatoryField field : mandatoryFields) {
            // Checkboxes always hold a value (true/false), so they cannot be "missing".
            if (field.isCheckbox) {
                continue;
            }
            Object value = getValue(site, field.path);
            if (value == null || (value instanceof String && String.isBlank((String) value))) {
                missing.add(field.label);
            }
        }
        return missing;
    }

    // Supports cross-object paths such as "Parent.Business_Central_Customer_ID_CC__c".
    private static Object getValue(SObject record, String fieldPath) {
        List<String> parts = fieldPath.split('\\.');
        SObject current = record;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            current = current.getSObject(parts[i]);
            if (current == null) {
                return null;
            }
        }
        return current.get(parts[parts.size() - 1]);
    }

    /**
     * The class runs without sharing, so record-level edit access is checked explicitly.
     * UserRecordAccess accepts at most 200 record Ids per query.
     */
    private static Set<Id> getEditableIds(Set<Id> recordIds) {
        Set<Id> editable = new Set<Id>();
        List<Id> allIds = new List<Id>(recordIds);

        for (Integer i = 0; i < allIds.size(); i += USER_ACCESS_BATCH_SIZE) {
            List<Id> batch = new List<Id>();
            Integer upper = Math.min(i + USER_ACCESS_BATCH_SIZE, allIds.size());
            for (Integer j = i; j < upper; j++) {
                batch.add(allIds[j]);
            }
            for (UserRecordAccess access : [
                SELECT RecordId, HasEditAccess
                FROM UserRecordAccess
                WHERE UserId = :UserInfo.getUserId() AND RecordId IN :batch
            ]) {
                if (access.HasEditAccess) {
                    editable.add(access.RecordId);
                }
            }
        }
        return editable;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    private static SyncSummary block(SyncSummary summary, String message) {
        summary.canSync = false;
        summary.blockingMessage = message;
        return summary;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}