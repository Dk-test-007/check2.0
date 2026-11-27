public with sharing class GuidancePathController_CC {
    private static final String WILDCARD_CONTEXT = '*';
    private static final String PERSONA_GLOBAL = 'GLOBAL';
    private static final String PERSONA_PROFILE = 'PROFILE';
    private static final String PERSONA_CUSTOM_PERMISSION = 'CUSTOM_PERMISSION';
    private static final String ACTION_SHOW = 'SHOW';

    @TestVisible
    private static List<Guidance_Object_Config_CC__mdt> testConfigurations;
    @TestVisible
    private static List<Guidance_Section_CC__mdt> testSections;

    /** Single entry point for loading the current record's guidance. */
    @AuraEnabled
    public static GuidanceResponse getGuidanceData(Id recordId) {
        GuidanceResponse response = new GuidanceResponse();
        if (recordId == null) return response;
        try {
            Schema.SObjectType objectType = recordId.getSObjectType();
            Schema.DescribeSObjectResult objectDescribe = objectType.getDescribe();
            response.objectApiName = objectDescribe.getName();
            SObject record = queryRecord(recordId, objectType, null);
            Id recordTypeId = getRecordTypeId(record, objectDescribe);
            String recordTypeName = getRecordTypeDeveloperName(
                objectDescribe, recordTypeId
            );

            Guidance_Object_Config_CC__mdt config = findConfiguration(
                response.objectApiName, recordTypeName
            );
            if (config == null) return response;

            response.isConfigured = true;
            String contextField = config.Context_Field_API_Name_CC__c;
            String contextValue = WILDCARD_CONTEXT;
            if (!String.isBlank(contextField)) {
                contextField = contextField.trim();
                if (!isDirectReadableField(objectType, contextField)) {
                    throw new AuraHandledException(
                        'The configured guidance context field is unavailable. Check its API name and field-level access.'
                    );
                }
                record = queryRecord(recordId, objectType, contextField);
                Object rawContext = record.get(contextField);
                contextValue = rawContext == null
                    ? null
                    : String.valueOf(rawContext).trim();
            }

            List<Guidance_Section_CC__mdt> sections = resolveApplicableSections(
                loadSections(config.DeveloperName),
                contextValue,
                getCurrentProfileName()
            );
            for (Guidance_Section_CC__mdt source : sections) {
                GuidanceSectionDTO item = new GuidanceSectionDTO();
                item.key = String.isBlank(source.Section_Key_CC__c)
                    ? source.DeveloperName
                    : source.Section_Key_CC__c;
                item.heading = source.Section_Heading_CC__c;
                item.text = source.Section_Text_CC__c;
                item.orderNumber = source.Section_Order_CC__c == null
                    ? 0
                    : source.Section_Order_CC__c.intValue();
                response.sections.add(item);
            }
            return response;
        } catch (AuraHandledException handledException) {
            throw handledException;
        } catch (Exception ex) {
            throw new AuraHandledException(
                'Unable to load guidance. Check the guidance metadata, context field, and user permissions.'
            );
        }
    }

    private static Guidance_Object_Config_CC__mdt findConfiguration(
        String objectApiName,
        String recordTypeName
    ) {
        List<Guidance_Object_Config_CC__mdt> configs =
            new List<Guidance_Object_Config_CC__mdt>();
        if (testConfigurations != null) {
            for (Guidance_Object_Config_CC__mdt candidate : testConfigurations) {
                if (
                    candidate.Active_CC__c == true &&
                    candidate.Object_API_Name_CC__c == objectApiName
                ) configs.add(candidate);
            }
        } else {
            configs = [
                SELECT DeveloperName, Object_API_Name_CC__c,
                       Record_Type_Developer_Name_CC__c,
                       Context_Field_API_Name_CC__c, Active_CC__c
                FROM Guidance_Object_Config_CC__mdt
                WHERE Active_CC__c = true
                  AND Object_API_Name_CC__c = :objectApiName
            ];
        }
        Guidance_Object_Config_CC__mdt defaultConfig;
        for (Guidance_Object_Config_CC__mdt config : configs) {
            String configuredRecordType = config.Record_Type_Developer_Name_CC__c;
            if (String.isBlank(configuredRecordType)) {
                defaultConfig = config;
            } else if (
                !String.isBlank(recordTypeName) &&
                configuredRecordType.equalsIgnoreCase(recordTypeName)
            ) {
                return config;
            }
        }
        return defaultConfig;
    }

    private static List<Guidance_Section_CC__mdt> loadSections(
        String configDeveloperName
    ) {
        if (testSections != null) {
            List<Guidance_Section_CC__mdt> matches =
                new List<Guidance_Section_CC__mdt>();
            for (Guidance_Section_CC__mdt section : testSections) {
                if (
                    section.Active_CC__c == true &&
                    section.Object_Config_Developer_Name_CC__c == configDeveloperName
                ) matches.add(section);
            }
            return matches;
        }
        return [
            SELECT DeveloperName, Context_Value_CC__c,
                   Persona_Type_CC__c, Persona_Value_CC__c,
                   Section_Key_CC__c, Section_Heading_CC__c,
                   Section_Text_CC__c, Section_Order_CC__c,
                   Display_Action_CC__c, Active_CC__c
            FROM Guidance_Section_CC__mdt
            WHERE Active_CC__c = true
              AND Object_Config_Developer_Name_CC__c = :configDeveloperName
            ORDER BY Section_Order_CC__c ASC, DeveloperName ASC
        ];
    }

    @TestVisible
    private static List<Guidance_Section_CC__mdt> resolveApplicableSections(
        List<Guidance_Section_CC__mdt> sections,
        String contextValue,
        String profileName
    ) {
        Map<String, SectionCandidate> winners = new Map<String, SectionCandidate>();
        if (contextValue == null) return new List<Guidance_Section_CC__mdt>();
        for (Guidance_Section_CC__mdt section : sections) {
            String configuredContext = String.isBlank(section.Context_Value_CC__c)
                ? WILDCARD_CONTEXT
                : section.Context_Value_CC__c.trim();
            Boolean exactContext = configuredContext != WILDCARD_CONTEXT &&
                configuredContext.equalsIgnoreCase(contextValue);
            Boolean wildcardContext = configuredContext == WILDCARD_CONTEXT;
            if (!exactContext && !wildcardContext) continue;

            Integer personaPriority = getPersonaPriority(section, profileName);
            if (personaPriority < 0) continue;

            String key = String.isBlank(section.Section_Key_CC__c)
                ? section.DeveloperName
                : section.Section_Key_CC__c.trim();
            Integer score = (exactContext ? 1000 : 0) + personaPriority;
            SectionCandidate previous = winners.get(key);
            if (previous == null || score > previous.score) {
                winners.put(key, new SectionCandidate(section, score));
            }
        }
        List<Guidance_Section_CC__mdt> applicable =
            new List<Guidance_Section_CC__mdt>();
        for (Guidance_Section_CC__mdt section : sections) {
            String key = String.isBlank(section.Section_Key_CC__c)
                ? section.DeveloperName
                : section.Section_Key_CC__c.trim();
            SectionCandidate winner = winners.get(key);
            if (
                winner != null &&
                winner.sectionRecord.DeveloperName == section.DeveloperName &&
                (String.isBlank(section.Display_Action_CC__c) ||
                 section.Display_Action_CC__c == ACTION_SHOW)
            ) applicable.add(section);
        }
        return applicable;
    }

    private static Integer getPersonaPriority(
        Guidance_Section_CC__mdt section,
        String profileName
    ) {
        String type = String.isBlank(section.Persona_Type_CC__c)
            ? PERSONA_GLOBAL
            : section.Persona_Type_CC__c;

        if (type == PERSONA_GLOBAL) return 0;
        if (type == PERSONA_PROFILE) {
            return !String.isBlank(profileName) &&
                profileName.equalsIgnoreCase(section.Persona_Value_CC__c)
                ? 10 : -1;
        }
        if (type == PERSONA_CUSTOM_PERMISSION) {
            if (String.isBlank(section.Persona_Value_CC__c)) return -1;
            try {
                return FeatureManagement.checkPermission(section.Persona_Value_CC__c)
                    ? 20 : -1;
            } catch (Exception ignored) {
                return -1;
            }
        }
        return -1;
    }

    private static SObject queryRecord(
        Id recordId,
        Schema.SObjectType objectType,
        String extraField
    ) {
        Schema.DescribeSObjectResult objectDescribe = objectType.getDescribe();
        if (!objectDescribe.isAccessible()) {
            throw new AuraHandledException('You do not have permission to view this record.');
        }
        Set<String> fields = new Set<String>{ 'Id' };
        Map<String, Schema.SObjectField> fieldMap = objectDescribe.fields.getMap();
        if (
            fieldMap.containsKey('RecordTypeId') &&
            fieldMap.get('RecordTypeId').getDescribe().isAccessible()
        ) fields.add('RecordTypeId');
        if (!String.isBlank(extraField)) fields.add(extraField);
        List<String> fieldList = new List<String>(fields);
        fieldList.sort();
        String soql = 'SELECT ' + String.join(fieldList, ',') +
            ' FROM ' + objectDescribe.getName() +
            ' WHERE Id = :recordId WITH USER_MODE';
        List<SObject> rows = Database.query(soql);
        if (rows.isEmpty()) {
            throw new AuraHandledException(
                'The record could not be found or you do not have access to it.'
            );
        }
        return rows[0];
    }

    private static Boolean isDirectReadableField(
        Schema.SObjectType objectType,
        String fieldApiName
    ) {
        if (String.isBlank(fieldApiName) || fieldApiName.contains('.')) return false;
        Schema.SObjectField token = objectType.getDescribe().fields.getMap().get(fieldApiName);
        return token != null && token.getDescribe().isAccessible();
    }

    private static Id getRecordTypeId(
        SObject record,
        Schema.DescribeSObjectResult objectDescribe
    ) {
        Schema.SObjectField fieldToken = objectDescribe.fields.getMap().get('RecordTypeId');
        if (fieldToken == null || !fieldToken.getDescribe().isAccessible()) return null;
        return (Id) record.get('RecordTypeId');
    }

    private static String getRecordTypeDeveloperName(
        Schema.DescribeSObjectResult objectDescribe,
        Id recordTypeId
    ) {
        if (recordTypeId == null) return null;
        Schema.RecordTypeInfo info = objectDescribe.getRecordTypeInfosById().get(recordTypeId);
        return info == null ? null : info.getDeveloperName();
    }

    private static String getCurrentProfileName() {
        List<Profile> profiles = [
            SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() WITH SYSTEM_MODE LIMIT 1
        ];
        return profiles.isEmpty() ? null : profiles[0].Name;
    }

    private class SectionCandidate {
        private Guidance_Section_CC__mdt sectionRecord;
        private Integer score;
        private SectionCandidate(Guidance_Section_CC__mdt recordValue, Integer scoreValue) {
            sectionRecord = recordValue;
            score = scoreValue;
        }
    }

    public class GuidanceResponse {
        @AuraEnabled public Boolean isConfigured { get; set; }
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public List<GuidanceSectionDTO> sections { get; set; }
        public GuidanceResponse() {
            isConfigured = false;
            sections = new List<GuidanceSectionDTO>();
        }
    }

    public class GuidanceSectionDTO {
        @AuraEnabled public String key { get; set; }
        @AuraEnabled public String heading { get; set; }
        @AuraEnabled public String text { get; set; }
        @AuraEnabled public Integer orderNumber { get; set; }
    }
}