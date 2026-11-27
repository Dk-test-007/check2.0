public with sharing class ProductRelatedListController_CC {
    private static final String SCREEN_RELATED_LIST = 'RELATED LIST';
    private static final String SCREEN_ADD_PRODUCT = 'ADD PRODUCT';
    private static final String SCREEN_EDIT_PRODUCTS = 'EDIT PRODUCTS';

    private static final String SOURCE_PRODUCT = 'PRODUCT';
    private static final String SOURCE_PRICEBOOK_ENTRY = 'PRICEBOOK_ENTRY';
    private static final String SOURCE_LINE_ITEM = 'LINE_ITEM';
    private static final String SOURCE_CALCULATED = 'CALCULATED';

    private static final String ORDER_SOURCE_FIELD = 'Order_Source_CC__c';
    private static final Set<String> NEW_BUSINESS_ORDER_SOURCES = new Set<String>{ 'Quote', 'Contract' };
    private static final Set<String> NEW_BUSINESS_EDITABLE_FIELDS = new Set<String>{
        'Warehouse_CC__c',
        'Shipment_Date_CC__c',
        'Location_Code_CC__c'
    };

    private static Product_Config_CC__mdt configFor(Id recordId) {
        String parentObjectName = recordId.getSObjectType().getDescribe().getName();

        for (Product_Config_CC__mdt config : Product_Config_CC__mdt.getAll().values()) {
            if (config.Parent_Object_API_Name_CC__c == parentObjectName) {
                return config;
            }
        }

        throw new AuraHandledException('No Product Config found for ' + parentObjectName);
    }

    private static SObject parentFor(Product_Config_CC__mdt config, Id recordId) {
        return parentFor(config, recordId, new List<Product_Column_Config_CC__mdt>());
    }

    private static SObject parentFor(
        Product_Config_CC__mdt config,
        Id recordId,
        List<Product_Column_Config_CC__mdt> editColumns
    ) {
        Map<String, Schema.SObjectField> parentFields = Schema.getGlobalDescribe()
            .get(config.Parent_Object_API_Name_CC__c).getDescribe().fields.getMap();
        Set<String> selectedFields = new Set<String>{
            'Id',
            config.Parent_Pricebook_Field_API_Name_CC__c,
            'Pricebook2.Name',
            config.Parent_Account_Field_API_Name_CC__c
        };

        if (UserInfo.isMultiCurrencyOrganization() && parentFields.containsKey('CurrencyIsoCode')) {
            selectedFields.add('CurrencyIsoCode');
        }

        if (config.Parent_Object_API_Name_CC__c == 'Order') {
            if (!parentFields.containsKey(ORDER_SOURCE_FIELD) ||
                !parentFields.get(ORDER_SOURCE_FIELD).getDescribe().isAccessible()) {
                throw new AuraHandledException(
                    'Read access to Order.Order_Source_CC__c is required to determine Order editing permissions.'
                );
            }
            selectedFields.add(ORDER_SOURCE_FIELD);
        }

        for (Product_Column_Config_CC__mdt column : editColumns) {
            String dataType = String.valueOf(column.Data_Type_CC__c).toLowerCase();
            Boolean isDate = dataType == 'date' || dataType == 'date-local';
            if (column.Field_Source_Type_CC__c != SOURCE_LINE_ITEM ||
                column.Editable_CC__c != true ||
                (dataType != 'lookup' && dataType != 'picklist' && !isDate) ||
                String.isBlank(column.Default_Value_Field_Path_CC__c)) {
                continue;
            }

            String relativePath = parentRelativePath(
                config,
                column.Default_Value_Field_Path_CC__c
            );
            selectedFields.add(relativePath);

            if (dataType == 'lookup') {
                Map<String, Object> lookupInfo = lookupInfoForPath(
                    config.Parent_Object_API_Name_CC__c,
                    relativePath
                );
                if (canReadField((String) lookupInfo.get('objectApiName'), 'Name')) {
                    selectedFields.add((String) lookupInfo.get('namePath'));
                }
            } else if (isDate) {
                validateDateDefaultPath(config, column.Field_API_Name_CC__c, relativePath);
            }
        }

        String soql = 'SELECT ' + String.join(new List<String>(selectedFields), ',') +
            ' FROM ' + config.Parent_Object_API_Name_CC__c +
            ' WHERE Id = :recordId LIMIT 1';

        List<SObject> parents = Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'recordId' => recordId },
            AccessLevel.USER_MODE
        );

        return parents[0];
    }

    private static String parentCurrencyIsoCode(SObject parent) {
        if (parent == null || !parent.getSObjectType().getDescribe().fields.getMap()
            .containsKey('CurrencyIsoCode')) {
            return null;
        }

        return (String) parent.get('CurrencyIsoCode');
    }

    // New Business Orders originate from Quotes or Contracts. Opportunity-sourced Orders remain BAU.
    private static Boolean isRestrictedNewBusinessOrder(
        Product_Config_CC__mdt config,
        SObject parent
    ) {
        if (config.Parent_Object_API_Name_CC__c != 'Order' || parent == null) {
            return false;
        }

        Object sourceValue = parent.get(ORDER_SOURCE_FIELD);
        return sourceValue != null &&
            NEW_BUSINESS_ORDER_SOURCES.contains(String.valueOf(sourceValue));
    }

    private static Boolean isNewBusinessEditableField(String fieldApiName) {
        return NEW_BUSINESS_EDITABLE_FIELDS.contains(fieldApiName);
    }

    private static List<Product_Column_Config_CC__mdt> columns(
        Product_Config_CC__mdt config,
        String screen
    ) {
        return [
            SELECT Label_CC__c, Field_Source_Type_CC__c, Field_API_Name_CC__c,
                   Display_Order_CC__c, Width_Percent_CC__c, Editable_CC__c, Required_CC__c, Data_Type_CC__c,
                   Default_Value_Field_Path_CC__c, URL_Field_Source_CC__c
            FROM Product_Column_Config_CC__mdt
            WHERE Product_Config_CC__r.DeveloperName = :config.DeveloperName
              AND Screen_Type_CC__c = :screen
            ORDER BY Display_Order_CC__c
        ];
    }

    private static List<Map<String, Object>> columnData(
        List<Product_Column_Config_CC__mdt> configs,
        String screen
    ) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        for (Integer i = 0; i < configs.size(); i++) {
            Product_Column_Config_CC__mdt config = configs[i];
            Map<String, Object> columnInfo = new Map<String, Object>{
                'label' => config.Label_CC__c,
                'fieldName' => 'f' + i,
                'type' => String.isBlank(config.Data_Type_CC__c) ? 'text' : config.Data_Type_CC__c,
                'editable' => screen == SCREEN_EDIT_PRODUCTS && config.Editable_CC__c,
                'required' => screen == SCREEN_EDIT_PRODUCTS && config.Required_CC__c,
                'source' => config.Field_Source_Type_CC__c,
                'apiName' => config.Field_API_Name_CC__c,
                'displayOrder' => config.Display_Order_CC__c,
                'widthPercent' => config.Width_Percent_CC__c
            };

            if (String.valueOf(config.Data_Type_CC__c).toLowerCase() == 'url') {
                columnInfo.put('labelFieldName', 'f' + i + 'Label');
            }

            result.add(columnInfo);
        }

        return result;
    }

    private static Object pathValue(SObject record, String path) {
        return pathValue(record, path.split('\\.'));
    }

    // Reuse pre-split paths inside row loops instead of splitting the same metadata for every record.
    private static Object pathValue(SObject record, List<String> parts) {
        if (record == null || parts == null || parts.isEmpty()) {
            return null;
        }

        SObject currentRecord = record;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            currentRecord = currentRecord == null ? null : currentRecord.getSObject(parts[i]);
            if (currentRecord == null) {
                return null;
            }
        }

        return currentRecord.get(parts[parts.size() - 1]);
    }

    private static void validateUrlFieldSource(String rootObjectName, String fieldPath) {
        if (String.isBlank(fieldPath)) {
            throw new AuraHandledException('URL Field Source must be configured for every URL column.');
        }

        List<String> parts = fieldPath.split('\\.');
        Schema.SObjectType currentType = Schema.getGlobalDescribe().get(rootObjectName);

        if (currentType == null) {
            throw new AuraHandledException('Unable to resolve URL source object ' + rootObjectName + '.');
        }

        for (Integer i = 0; i < parts.size() - 1; i++) {
            currentType = relatedObjectType(currentType, parts[i]);
            if (currentType == null) {
                throw new AuraHandledException(
                    'Invalid relationship ' + parts[i] + ' in URL Field Source ' + fieldPath + '.'
                );
            }
        }

        Map<String, Schema.SObjectField> fieldMap = currentType.getDescribe().fields.getMap();
        String finalFieldName = parts[parts.size() - 1];

        if (!fieldMap.containsKey(finalFieldName)) {
            throw new AuraHandledException(
                'Field ' + finalFieldName + ' does not exist in URL Field Source ' + fieldPath + '.'
            );
        }

        Schema.DisplayType fieldType = fieldMap.get(finalFieldName).getDescribe().getType();
        if (finalFieldName.toLowerCase() != 'id' && fieldType != Schema.DisplayType.Reference) {
            throw new AuraHandledException(
                'URL Field Source must end with an Id field or a Lookup field: ' + fieldPath + '.'
            );
        }
    }

    private static String parentRelativePath(
        Product_Config_CC__mdt config,
        String configuredPath
    ) {
        String expectedPrefix = config.Parent_Object_API_Name_CC__c + '.';
        if (String.isBlank(configuredPath) || !configuredPath.startsWith(expectedPrefix)) {
            throw new AuraHandledException(
                'Default Value Field Path must start with ' +
                config.Parent_Object_API_Name_CC__c + '.'
            );
        }

        return configuredPath.substring(expectedPrefix.length());
    }

    private static Schema.SObjectType relatedObjectType(
        Schema.SObjectType sourceType,
        String relationshipName
    ) {
        for (Schema.SObjectField fieldToken : sourceType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult fieldInfo = fieldToken.getDescribe();
            if (fieldInfo.getRelationshipName() == relationshipName) {
                List<Schema.SObjectType> referenceTypes = fieldInfo.getReferenceTo();
                return referenceTypes.size() == 1 ? referenceTypes[0] : null;
            }
        }

        return null;
    }

    private static Map<String, Object> lookupInfoForPath(
        String rootObjectName,
        String relativePath
    ) {
        List<String> parts = relativePath.split('\\.');
        if (parts.isEmpty()) {
            throw new AuraHandledException('Invalid Lookup field path: ' + relativePath);
        }

        Schema.SObjectType currentType = Schema.getGlobalDescribe().get(rootObjectName);
        List<String> relationshipParts = new List<String>();

        for (Integer i = 0; i < parts.size() - 1; i++) {
            currentType = relatedObjectType(currentType, parts[i]);
            if (currentType == null) {
                throw new AuraHandledException(
                    'Invalid relationship ' + parts[i] + ' in field path ' + relativePath
                );
            }
            relationshipParts.add(parts[i]);
        }

        Map<String, Schema.SObjectField> fields = currentType.getDescribe().fields.getMap();
        if (!fields.containsKey(parts[parts.size() - 1])) {
            throw new AuraHandledException('Invalid field path: ' + relativePath);
        }

        Schema.DescribeFieldResult fieldInfo =
            fields.get(parts[parts.size() - 1]).getDescribe();
        List<Schema.SObjectType> referenceTypes = fieldInfo.getReferenceTo();
        if (fieldInfo.getType() != Schema.DisplayType.Reference ||
            referenceTypes.size() != 1 ||
            String.isBlank(fieldInfo.getRelationshipName())) {
            throw new AuraHandledException(
                'Default Value Field Path must point to a Lookup field: ' + relativePath
            );
        }

        String namePath = String.join(relationshipParts, '.');
        namePath = String.isBlank(namePath)
            ? fieldInfo.getRelationshipName() + '.Name'
            : namePath + '.' + fieldInfo.getRelationshipName() + '.Name';

        return new Map<String, Object>{
            'objectApiName' => referenceTypes[0].getDescribe().getName(),
            'relationshipName' => fieldInfo.getRelationshipName(),
            'namePath' => namePath
        };
    }

    // Resolve the field type at the end of a parent-relative relationship path.
    private static Schema.DescribeFieldResult describeFieldForPath(
        String rootObjectName,
        String relativePath
    ) {
        List<String> parts = relativePath.split('\\.');
        Schema.SObjectType currentType = Schema.getGlobalDescribe().get(rootObjectName);

        if (currentType == null || parts.isEmpty()) {
            throw new AuraHandledException('Invalid Default Value Field Path: ' + relativePath);
        }

        for (Integer i = 0; i < parts.size() - 1; i++) {
            currentType = relatedObjectType(currentType, parts[i]);
            if (currentType == null) {
                throw new AuraHandledException(
                    'Invalid relationship ' + parts[i] + ' in Default Value Field Path ' + relativePath
                );
            }
        }

        Map<String, Schema.SObjectField> fields = currentType.getDescribe().fields.getMap();
        String fieldName = parts[parts.size() - 1];
        if (!fields.containsKey(fieldName)) {
            throw new AuraHandledException('Invalid field in Default Value Field Path: ' + relativePath);
        }

        return fields.get(fieldName).getDescribe();
    }

    // Date defaults must come from a Date field and target a Date line-item field.
    private static void validateDateDefaultPath(
        Product_Config_CC__mdt config,
        String lineItemFieldName,
        String relativePath
    ) {
        Schema.DescribeFieldResult sourceField = describeFieldForPath(
            config.Parent_Object_API_Name_CC__c,
            relativePath
        );
        Map<String, Schema.SObjectField> lineFields = Schema.getGlobalDescribe()
            .get(config.Line_Item_Object_API_Name_CC__c)
            .getDescribe()
            .fields.getMap();

        if (!lineFields.containsKey(lineItemFieldName) ||
            sourceField.getType() != Schema.DisplayType.Date ||
            lineFields.get(lineItemFieldName).getDescribe().getType() != Schema.DisplayType.Date) {
            throw new AuraHandledException(
                'Default Value Field Path for ' + lineItemFieldName +
                ' must reference a Date field, and the configured line-item field must also be Date.'
            );
        }
    }

    private static Map<String, Object> lookupInfoForField(
        String objectName,
        String fieldName
    ) {
        Map<String, Schema.SObjectField> fields = Schema.getGlobalDescribe()
            .get(objectName).getDescribe().fields.getMap();
        if (!fields.containsKey(fieldName)) {
            throw new AuraHandledException(
                'Lookup field ' + fieldName + ' does not exist on ' + objectName + '.'
            );
        }

        Schema.DescribeFieldResult fieldInfo = fields.get(fieldName).getDescribe();
        List<Schema.SObjectType> referenceTypes = fieldInfo.getReferenceTo();
        if (fieldInfo.getType() != Schema.DisplayType.Reference ||
            referenceTypes.size() != 1 ||
            String.isBlank(fieldInfo.getRelationshipName())) {
            throw new AuraHandledException(
                'Lookup column ' + fieldName + ' must reference a single object.'
            );
        }

        return new Map<String, Object>{
            'objectApiName' => referenceTypes[0].getDescribe().getName(),
            'relationshipName' => fieldInfo.getRelationshipName()
        };
    }

    // Check the exact API value against active picklist options. Labels are intentionally ignored.
    private static Boolean isActivePicklistApiValue(
        List<Map<String, Object>> options,
        Object candidateValue
    ) {
        if (candidateValue == null || String.isBlank(String.valueOf(candidateValue))) {
            return false;
        }

        String candidate = String.valueOf(candidateValue);
        for (Map<String, Object> option : options) {
            if (String.valueOf(option.get('value')).equals(candidate)) {
                return true;
            }
        }
        return false;
    }

    // Build UI options from the active Salesforce values of a single-select picklist field.
    private static List<Map<String, Object>> picklistOptionsForField(
        String objectName,
        String fieldName,
        Boolean includeNoneOption
    ) {
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectName);
        if (objectType == null) {
            throw new AuraHandledException('Invalid object configured for picklist: ' + objectName);
        }

        Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
        if (!fields.containsKey(fieldName)) {
            throw new AuraHandledException(
                'Picklist field ' + fieldName + ' does not exist on ' + objectName + '.'
            );
        }

        Schema.DescribeFieldResult fieldInfo = fields.get(fieldName).getDescribe();
        if (fieldInfo.getType() != Schema.DisplayType.Picklist) {
            throw new AuraHandledException(
                'Column configured as Picklist must reference a single-select picklist field: ' +
                objectName + '.' + fieldName
            );
        }

        List<Map<String, Object>> options = new List<Map<String, Object>>();
        if (includeNoneOption == true && fieldInfo.isNillable()) {
            options.add(new Map<String, Object>{
                'label' => '--None--',
                'value' => ''
            });
        }

        for (Schema.PicklistEntry entry : fieldInfo.getPicklistValues()) {
            if (!entry.isActive()) {
                continue;
            }
            options.add(new Map<String, Object>{
                'label' => entry.getLabel(),
                'value' => entry.getValue()
            });
        }

        return options;
    }

    private static List<Map<String, Object>> editColumnData(
        List<Product_Column_Config_CC__mdt> configs,
        Product_Config_CC__mdt config,
        SObject parent
    ) {
        List<Map<String, Object>> result = columnData(configs, SCREEN_EDIT_PRODUCTS);

        for (Integer i = 0; i < configs.size(); i++) {
            Product_Column_Config_CC__mdt column = configs[i];
            if (column.Field_Source_Type_CC__c != SOURCE_LINE_ITEM) {
                continue;
            }

            String dataType = String.valueOf(column.Data_Type_CC__c).toLowerCase();
            Map<String, Object> columnInfo = result[i];

            if (dataType == 'picklist') {
                columnInfo.put('labelFieldName', 'f' + i + 'Label');
                List<Map<String, Object>> picklistOptions = picklistOptionsForField(
                    config.Line_Item_Object_API_Name_CC__c,
                    column.Field_API_Name_CC__c,
                    column.Required_CC__c != true
                );
                columnInfo.put('picklistOptions', picklistOptions);

                if (!String.isBlank(column.Default_Value_Field_Path_CC__c)) {
                    String relativePath = parentRelativePath(
                        config,
                        column.Default_Value_Field_Path_CC__c
                    );
                    Object defaultValue = pathValue(parent, relativePath);
                    if (isActivePicklistApiValue(picklistOptions, defaultValue)) {
                        // Send only a valid picklist API value to the LWC.
                        columnInfo.put('defaultValue', String.valueOf(defaultValue));
                    }
                }
                continue;
            }

            if (dataType == 'date' || dataType == 'date-local') {
                if (!String.isBlank(column.Default_Value_Field_Path_CC__c)) {
                    String relativePath = parentRelativePath(
                        config,
                        column.Default_Value_Field_Path_CC__c
                    );
                    validateDateDefaultPath(config, column.Field_API_Name_CC__c, relativePath);
                    Object defaultValue = pathValue(parent, relativePath);
                    if (defaultValue != null) {
                        columnInfo.put('defaultValue', String.valueOf(defaultValue));
                    }
                }
                continue;
            }

            if (dataType != 'lookup') {
                continue;
            }

            Map<String, Object> lookupInfo = lookupInfoForField(
                config.Line_Item_Object_API_Name_CC__c,
                column.Field_API_Name_CC__c
            );
            columnInfo.put('lookupObjectApiName', lookupInfo.get('objectApiName'));
            columnInfo.put('labelFieldName', 'f' + i + 'Label');
            columnInfo.put('urlFieldName', 'f' + i + 'Url');

            if (!String.isBlank(column.Default_Value_Field_Path_CC__c)) {
                String relativePath = parentRelativePath(
                    config,
                    column.Default_Value_Field_Path_CC__c
                );
                Map<String, Object> defaultLookupInfo = lookupInfoForPath(
                    config.Parent_Object_API_Name_CC__c,
                    relativePath
                );

                if ((String) defaultLookupInfo.get('objectApiName') !=
                    (String) lookupInfo.get('objectApiName')) {
                    throw new AuraHandledException(
                        'Default Value Field Path for ' + column.Field_API_Name_CC__c +
                        ' must reference ' + lookupInfo.get('objectApiName') + '.'
                    );
                }

                columnInfo.put('defaultValue', pathValue(parent, relativePath));
                columnInfo.put(
                    'defaultLabel',
                    canReadField((String) defaultLookupInfo.get('objectApiName'), 'Name')
                        ? pathValue(parent, (String) defaultLookupInfo.get('namePath'))
                        : null
                );
            }
        }

        return result;
    }

    private static Boolean hasField(String objectName, String fieldName) {
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectName);
        return objectType != null && objectType.getDescribe().fields.getMap().containsKey(fieldName);
    }

    private static Boolean canReadField(String objectName, String fieldName) {
        if (!hasField(objectName, fieldName)) {
            return false;
        }

        return Schema.getGlobalDescribe()
            .get(objectName)
            .getDescribe()
            .fields.getMap()
            .get(fieldName)
            .getDescribe()
            .isAccessible();
    }

    private static Decimal margin(Object salesValue, Object costValue) {
        if (salesValue == null || costValue == null) {
            return null;
        }

        Decimal salesPrice = Decimal.valueOf(String.valueOf(salesValue));
        Decimal landingCost = Decimal.valueOf(String.valueOf(costValue));

        if (salesPrice == 0) {
            return null;
        }

        return (salesPrice - landingCost) / salesPrice;
    }

    private static Boolean isLandingCostColumn(String apiName, String fieldName) {
        return apiName == fieldName ||
            apiName == 'Product2.' + fieldName ||
            apiName == 'PricebookEntry.Product2.' + fieldName;
    }

    private static String productFieldApiName(String apiName) {
        if (apiName != null && apiName.startsWith('PricebookEntry.Product2.')) {
            return apiName.substring('PricebookEntry.Product2.'.length());
        }

        if (apiName != null && apiName.startsWith('Product2.')) {
            return apiName.substring('Product2.'.length());
        }

        return apiName;
    }

    private static Map<Id, Map<String, Object>> productLandingCostData(
        Set<Id> productIds,
        Product_Config_CC__mdt config
    ) {
        Map<Id, Map<String, Object>> result = new Map<Id, Map<String, Object>>();
        Boolean canReadLandingCost = canReadField('Product2', config.Landing_Cost_Field_API_Name_CC__c);

        if (productIds.isEmpty() || !canReadLandingCost) {
            return result;
        }

        Boolean isMultiCurrency = UserInfo.isMultiCurrencyOrganization();
        Boolean canReadProductCurrency = canReadField('Product2', 'CurrencyIsoCode');
        Set<String> fields = new Set<String>{
            'Id',
            config.Landing_Cost_Field_API_Name_CC__c
        };

        if (isMultiCurrency && canReadProductCurrency) {
            fields.add('CurrencyIsoCode');
            fields.add(
                'convertCurrency(' +
                config.Landing_Cost_Field_API_Name_CC__c +
                ') convertedLandingCost'
            );
        }

        String soql = 'SELECT ' + String.join(new List<String>(fields), ',') +
            ' FROM Product2 WHERE Id IN :productIds';
        List<SObject> products = Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'productIds' => productIds },
            AccessLevel.USER_MODE
        );

        String userCurrencyIsoCode = UserInfo.getDefaultCurrency();

        for (SObject product : products) {
            Object convertedLandingCost = isMultiCurrency && canReadProductCurrency
                ? product.get('convertedLandingCost')
                : null;

            result.put((Id) product.get('Id'), new Map<String, Object>{
                'landingCost' => product.get(config.Landing_Cost_Field_API_Name_CC__c),
                'landingCostCurrencyIsoCode' => isMultiCurrency
                    ? (canReadProductCurrency ? product.get('CurrencyIsoCode') : null)
                    : userCurrencyIsoCode,
                'convertedLandingCost' => convertedLandingCost,
                'convertedCurrencyIsoCode' => isMultiCurrency && canReadProductCurrency
                    ? userCurrencyIsoCode
                    : null
            });
        }

        return result;
    }

    private static void addLineItemColumnFields(
        Set<String> fields,
        List<Product_Column_Config_CC__mdt> configs,
        String lineItemObjectName
    ) {
        for (Product_Column_Config_CC__mdt column : configs) {
            Boolean isUrl = String.valueOf(column.Data_Type_CC__c).toLowerCase() == 'url';

            if (column.Field_Source_Type_CC__c != SOURCE_LINE_ITEM && !isUrl) {
                continue;
            }

            fields.add(column.Field_API_Name_CC__c);

            if (isUrl) {
                if (String.isBlank(column.URL_Field_Source_CC__c)) {
                    throw new AuraHandledException(
                        'Configure URL Field Source for the ' + column.Label_CC__c + ' column.'
                    );
                }

                validateUrlFieldSource(lineItemObjectName, column.URL_Field_Source_CC__c);
                fields.add(column.URL_Field_Source_CC__c);
            }

            if (column.Field_Source_Type_CC__c == SOURCE_LINE_ITEM &&
                String.valueOf(column.Data_Type_CC__c).toLowerCase() == 'lookup') {
                Map<String, Object> lookupInfo = lookupInfoForField(
                    lineItemObjectName,
                    column.Field_API_Name_CC__c
                );
                String targetObjectName = (String) lookupInfo.get('objectApiName');
                if (canReadField(targetObjectName, 'Name')) {
                    fields.add((String) lookupInfo.get('relationshipName') + '.Name');
                }
            }
        }
    }

    private static List<Map<String, Object>> lineRows(
        List<SObject> records,
        List<Product_Column_Config_CC__mdt> configs,
        Product_Config_CC__mdt config,
        Map<Id, Map<String, Object>> landingCostData,
        Boolean includeCurrencyIsoCode,
        Boolean isMultiCurrency
    ) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        // Resolve all schema and lookup metadata once, outside the row-processing loop.
        List<Map<String, Object>> columnPlans = new List<Map<String, Object>>();
        for (Integer i = 0; i < configs.size(); i++) {
            Product_Column_Config_CC__mdt column = configs[i];
            String dataType = String.valueOf(column.Data_Type_CC__c).toLowerCase();
            Boolean isUrl = dataType == 'url';
            Boolean isLookup = column.Field_Source_Type_CC__c == SOURCE_LINE_ITEM &&
                dataType == 'lookup';
            Boolean isLandingCost = isLandingCostColumn(
                column.Field_API_Name_CC__c,
                config.Landing_Cost_Field_API_Name_CC__c
            );
            Boolean isCalculated = column.Field_Source_Type_CC__c == SOURCE_CALCULATED;
            Map<String, Object> plan = new Map<String, Object>{
                'isLandingCost' => isLandingCost,
                'isCalculated' => isCalculated,
                'isUrl' => isUrl,
                'isLookup' => isLookup
            };

            if (!isLandingCost && !isCalculated &&
                !String.isBlank(column.Field_API_Name_CC__c)) {
                plan.put('fieldPathParts', column.Field_API_Name_CC__c.split('\\.'));
            }
            if (isUrl && !String.isBlank(column.URL_Field_Source_CC__c)) {
                plan.put('urlFieldPathParts', column.URL_Field_Source_CC__c.split('\\.'));
            }

            if (isLookup) {
                Map<String, Object> lookupInfo = lookupInfoForField(
                    config.Line_Item_Object_API_Name_CC__c,
                    column.Field_API_Name_CC__c
                );
                String lookupObjectName = (String) lookupInfo.get('objectApiName');
                String lookupNamePath = (String) lookupInfo.get('relationshipName') + '.Name';
                plan.put('lookupNamePathParts', lookupNamePath.split('\\.'));
                plan.put('canReadLookupName', canReadField(lookupObjectName, 'Name'));
            }

            columnPlans.add(plan);
        }

        String userCurrencyIsoCode = UserInfo.getDefaultCurrency();

        for (SObject record : records) {
            SObject pricebookEntry = record.getSObject('PricebookEntry');
            SObject product = pricebookEntry == null ? null : pricebookEntry.getSObject('Product2');
            Id productId = product == null ? null : (Id) product.get('Id');
            Map<String, Object> costData = landingCostData.get(productId);
            Object landingCost = costData == null ? null : costData.get('landingCost');
            Object convertedLandingCost = costData == null
                ? null
                : costData.get('convertedLandingCost');
            Object marginLandingCost = convertedLandingCost;
            String landingCostCurrencyIsoCode = costData == null
                ? null
                : (String) costData.get('landingCostCurrencyIsoCode');

            if (marginLandingCost == null &&
                landingCostCurrencyIsoCode == userCurrencyIsoCode) {
                marginLandingCost = landingCost;
            }

            Object marginSalesPrice = isMultiCurrency
                ? record.get('convertedUnitPrice')
                : record.get('UnitPrice');

            Map<String, Object> row = new Map<String, Object>{
                'Id' => record.get('Id'),
                'lineItemId' => record.get('Id'),
                'pricebookEntryId' => record.get('PricebookEntryId'),
                'unitPrice' => record.get('UnitPrice'),
                'convertedUnitPrice' => isMultiCurrency
                    ? record.get('convertedUnitPrice')
                    : null,
                'productId' => productId,
                'productName' => product == null ? null : product.get('Name'),
                'landingCost' => landingCost,
                'landingCostCurrencyIsoCode' => costData == null
                    ? null
                    : costData.get('landingCostCurrencyIsoCode'),
                'convertedLandingCost' => costData == null
                    ? null
                    : costData.get('convertedLandingCost'),
                'convertedCurrencyIsoCode' => costData == null
                    ? null
                    : costData.get('convertedCurrencyIsoCode')
            };

            if (includeCurrencyIsoCode) {
                row.put('currencyIsoCode', record.get('CurrencyIsoCode'));
            }

            for (Integer i = 0; i < configs.size(); i++) {
                Product_Column_Config_CC__mdt column = configs[i];
                Map<String, Object> plan = columnPlans[i];
                Object value;

                if ((Boolean) plan.get('isLandingCost')) {
                    value = landingCost;
                } else if ((Boolean) plan.get('isCalculated')) {
                    value = marginLandingCost == null || marginSalesPrice == null
                        ? null
                        : margin(marginSalesPrice, marginLandingCost);
                } else if ((Boolean) plan.get('isUrl')) {
                    Object targetId = pathValue(record, (List<String>) plan.get('urlFieldPathParts'));
                    row.put('f' + i + 'Label', pathValue(record, (List<String>) plan.get('fieldPathParts')));
                    value = targetId == null ? null : '/' + String.valueOf(targetId);
                } else {
                    value = pathValue(record, (List<String>) plan.get('fieldPathParts'));
                }

                row.put('f' + i, value);

                if ((Boolean) plan.get('isLookup')) {
                    Boolean canReadLookupName = (Boolean) plan.get('canReadLookupName');
                    row.put(
                        'f' + i + 'Label',
                        canReadLookupName
                            ? pathValue(record, (List<String>) plan.get('lookupNamePathParts'))
                            : null
                    );
                    row.put('f' + i + 'Url', value == null ? null : '/' + String.valueOf(value));
                }
            }

            result.add(row);
        }

        return result;
    }

    @AuraEnabled
    public static Map<String, Object> getInitialData(Id recordId) {
        Product_Config_CC__mdt config = configFor(recordId);
        List<Product_Column_Config_CC__mdt> relatedColumns = columns(config, SCREEN_RELATED_LIST);
        List<Product_Column_Config_CC__mdt> editColumns = columns(config, SCREEN_EDIT_PRODUCTS);
        SObject parent = parentFor(config, recordId, editColumns);
        // FUTURE PHASE: Load SITE ALLOCATION columns from Product_Column_Config_CC__mdt.
        // List<Product_Column_Config_CC__mdt> siteAllocationColumns = columns(config, SCREEN_SITE_ALLOCATION);

        Set<String> fields = new Set<String>{
            'Id', 'PricebookEntryId', 'UnitPrice',
            'PricebookEntry.Product2.Id', 'PricebookEntry.Product2.Name'
        };

        addLineItemColumnFields(
            fields,
            relatedColumns,
            config.Line_Item_Object_API_Name_CC__c
        );
        addLineItemColumnFields(
            fields,
            editColumns,
            config.Line_Item_Object_API_Name_CC__c
        );

        Boolean includeCurrencyIsoCode = canReadField(
            config.Line_Item_Object_API_Name_CC__c,
            'CurrencyIsoCode'
        );
        Boolean isMultiCurrency = UserInfo.isMultiCurrencyOrganization();
        if (includeCurrencyIsoCode) {
            fields.add('CurrencyIsoCode');
        }

        // FUTURE PHASE: Query Quantity separately for aggregate-driven Site allocation.
        // if (config.Show_Sites_Warehouses_Selection_CC__c == true &&
        //     canReadField(config.Line_Item_Object_API_Name_CC__c, 'Quantity')) {
        //     fields.add('Quantity');
        // }

        if (isMultiCurrency) {
            fields.add('convertCurrency(UnitPrice) convertedUnitPrice');
        }

        String soql = 'SELECT ' + String.join(new List<String>(fields), ',') +
            ' FROM ' + config.Line_Item_Object_API_Name_CC__c +
            ' WHERE ' + config.Parent_Lookup_Field_API_Name_CC__c + ' = :recordId' +
            ' ORDER BY CreatedDate DESC LIMIT 5000';

        List<SObject> lines = Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'recordId' => recordId },
            AccessLevel.USER_MODE
        );

        List<SObject> preview = new List<SObject>();
        Set<Id> productIds = new Set<Id>();
        for (Integer i = 0; i < lines.size(); i++) {
            SObject pricebookEntry = lines[i].getSObject('PricebookEntry');
            SObject product = pricebookEntry == null ? null : pricebookEntry.getSObject('Product2');
            Id productId = product == null ? null : (Id) product.get('Id');

            if (i < 5) {
                preview.add(lines[i]);
            }
            if (productId != null) {
                productIds.add(productId);
            }
        }

        Map<Id, Map<String, Object>> landingCostData = productLandingCostData(productIds, config);

        Schema.DescribeSObjectResult lineDescribe =
            Schema.getGlobalDescribe().get(config.Line_Item_Object_API_Name_CC__c).getDescribe();
        Schema.DescribeSObjectResult parentDescribe =
            Schema.getGlobalDescribe().get(config.Parent_Object_API_Name_CC__c).getDescribe();

        Boolean canChangePricebook = parentDescribe.isUpdateable() &&
            parentDescribe.fields.getMap()
                .get(config.Parent_Pricebook_Field_API_Name_CC__c)
                .getDescribe()
                .isUpdateable();

        if (parent.get(config.Parent_Pricebook_Field_API_Name_CC__c) != null &&
            !lines.isEmpty() && !lineDescribe.isDeletable()) {
            canChangePricebook = false;
        }

        return new Map<String, Object>{
            'header' => config.Header_Label_CC__c,
            'headerIcon' => config.Header_Icon_CC__c,
            'landingCostFieldApiName' => config.Landing_Cost_Field_API_Name_CC__c,
            'userCurrencyIsoCode' => UserInfo.getDefaultCurrency(),
            // FUTURE PHASE: Return the feature flag and SITE ALLOCATION column configuration.
            // 'showSitesWarehousesSelection' => config.Show_Sites_Warehouses_Selection_CC__c == true,
            // 'siteAllocationColumns' => columnData(siteAllocationColumns, SCREEN_SITE_ALLOCATION),
            'relationshipApiName' => config.Relationship_API_Name_CC__c,
            'parentObjectApiName' => config.Parent_Object_API_Name_CC__c,
            'lineItemObjectApiName' => config.Line_Item_Object_API_Name_CC__c,
            'isRestrictedEditMode' => isRestrictedNewBusinessOrder(config, parent),
            'pricebookId' => parent.get(config.Parent_Pricebook_Field_API_Name_CC__c),
            'pricebookName' => pathValue(parent, 'Pricebook2.Name'),
            'accountId' => parent.get(config.Parent_Account_Field_API_Name_CC__c),
            'canCreate' => lineDescribe.isCreateable(),
            'canEdit' => lineDescribe.isUpdateable(),
            'canDelete' => lineDescribe.isDeletable(),
            'canChangePricebook' => canChangePricebook,
            'relatedColumns' => columnData(relatedColumns, SCREEN_RELATED_LIST),
            'editColumns' => editColumnData(editColumns, config, parent),
            'totalCount' => lines.size(),
            'rows' => lineRows(
                preview, relatedColumns, config, landingCostData, includeCurrencyIsoCode, isMultiCurrency
            ),
            'editRows' => lineRows(
                lines, editColumns, config, landingCostData, includeCurrencyIsoCode, isMultiCurrency
            )
        };
    }

    private static List<SObject> eligiblePricebooks(Product_Config_CC__mdt config, Id accountId) {
        String entityField = config.Pricebook_Entity_Field_API_Name_CC__c;
        Boolean hasEntity = accountId != null && canReadField('Pricebook2', entityField);

        String soql = 'SELECT Id, Name FROM Pricebook2' +
            ' WHERE IsActive = true AND Name = :standardName';
        Map<String, Object> binds = new Map<String, Object>{
            'standardName' => 'Standard Price Book'
        };

        if (hasEntity) {
            soql = 'SELECT Id, Name FROM Pricebook2' +
                ' WHERE IsActive = true AND (Name = :standardName OR ' + entityField + ' = :accountId)';
            binds.put('accountId', accountId);
        }

        return Database.queryWithBinds(soql + ' ORDER BY Name', binds, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static List<Map<String, Object>> getPricebooks(Id recordId) {
        Product_Config_CC__mdt config = configFor(recordId);
        SObject parent = parentFor(config, recordId);
        Id accountId = (Id) parent.get(config.Parent_Account_Field_API_Name_CC__c);

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (SObject pricebook : eligiblePricebooks(config, accountId)) {
            result.add(new Map<String, Object>{
                'label' => pricebook.get('Name'),
                'value' => pricebook.get('Id')
            });
        }

        return result;
    }

    @AuraEnabled
    public static Map<String, Object> getProducts(
        Id recordId,
        String searchTerm,
        String cursorName,
        Id cursorEntryId,
        Integer pageSize
    ) {
        Product_Config_CC__mdt config = configFor(recordId);
        SObject parent = parentFor(config, recordId);
        Id pricebookId = (Id) parent.get(config.Parent_Pricebook_Field_API_Name_CC__c);

        if (pricebookId == null) {
            throw new AuraHandledException('Choose a Price Book first.');
        }
        if ((cursorName == null) != (cursorEntryId == null)) {
            throw new AuraHandledException('Invalid product pagination cursor.');
        }

        Integer safePageSize = pageSize == null ? 30 : pageSize;
        if (safePageSize < 1) safePageSize = 1;
        if (safePageSize > 200) safePageSize = 200;
        Boolean isMultiCurrency = UserInfo.isMultiCurrencyOrganization();
        Boolean canReadPricebookCurrency = canReadField('PricebookEntry', 'CurrencyIsoCode');
        List<Product_Column_Config_CC__mdt> productColumns = columns(config, SCREEN_ADD_PRODUCT);
        Set<String> fields = new Set<String>{
            'Id', 'Product2Id', 'UnitPrice', 'Product2.Name'
        };

        if (isMultiCurrency) {
            fields.add('convertCurrency(UnitPrice) convertedUnitPrice');
        }

        // Resolve configured fields and URL paths once; reuse this metadata for every row.
        List<Map<String, Object>> columnPlans = new List<Map<String, Object>>();
        for (Product_Column_Config_CC__mdt column : productColumns) {
            String source = column.Field_Source_Type_CC__c;
            String dataType = String.valueOf(column.Data_Type_CC__c).toLowerCase();
            Boolean isUrl = dataType == 'url';
            Boolean isLandingCost = source == SOURCE_PRODUCT && isLandingCostColumn(
                column.Field_API_Name_CC__c,
                config.Landing_Cost_Field_API_Name_CC__c
            );
            String fieldPath;
            String urlFieldPath;

            if (source == SOURCE_PRODUCT) {
                fieldPath = productFieldApiName(column.Field_API_Name_CC__c);
                if (!isLandingCost) {
                    fields.add('Product2.' + fieldPath);
                }

                if (isUrl) {
                    if (String.isBlank(column.URL_Field_Source_CC__c)) {
                        throw new AuraHandledException(
                            'Configure URL Field Source for the ' + column.Label_CC__c + ' column.'
                        );
                    }
                    urlFieldPath = productFieldApiName(column.URL_Field_Source_CC__c);
                    validateUrlFieldSource('Product2', urlFieldPath);
                    fields.add('Product2.' + urlFieldPath);
                }
            } else if (source == SOURCE_PRICEBOOK_ENTRY) {
                fieldPath = column.Field_API_Name_CC__c;
                fields.add(fieldPath);

                if (isUrl) {
                    if (String.isBlank(column.URL_Field_Source_CC__c)) {
                        throw new AuraHandledException(
                            'Configure URL Field Source for the ' + column.Label_CC__c + ' column.'
                        );
                    }
                    urlFieldPath = column.URL_Field_Source_CC__c;
                    validateUrlFieldSource('PricebookEntry', urlFieldPath);
                    fields.add(urlFieldPath);
                }
            }

            Map<String, Object> plan = new Map<String, Object>{
                'source' => source,
                'isUrl' => isUrl,
                'isLandingCost' => isLandingCost,
                'fieldPath' => fieldPath,
                'urlFieldPath' => urlFieldPath
            };
            if (!String.isBlank(fieldPath)) {
                plan.put('fieldPathParts', fieldPath.split('\\.'));
            }
            if (!String.isBlank(urlFieldPath)) {
                plan.put('urlFieldPathParts', urlFieldPath.split('\\.'));
            }
            columnPlans.add(plan);
        }

        if (canReadPricebookCurrency) {
            fields.add('CurrencyIsoCode');
        }

        String soql = 'SELECT ' + String.join(new List<String>(fields), ',') +
            ' FROM PricebookEntry' +
            ' WHERE Pricebook2Id = :pricebookId' +
            ' AND IsActive = true AND Product2.IsActive = true';
        Map<String, Object> binds = new Map<String, Object>{ 'pricebookId' => pricebookId };
        String parentCurrency = parentCurrencyIsoCode(parent);

        if (!String.isBlank(parentCurrency) && canReadPricebookCurrency) {
            soql += ' AND CurrencyIsoCode = :parentCurrency';
            binds.put('parentCurrency', parentCurrency);
        }

        if (!String.isBlank(searchTerm)) {
            soql += ' AND (Product2.Name LIKE :term OR Product2.ProductCode LIKE :term)';
            binds.put('term', '%' + searchTerm.trim() + '%');
        }

        if (cursorEntryId != null) {
            soql += ' AND (Product2.Name > :cursorName OR ' +
                '(Product2.Name = :cursorName AND Id > :cursorEntryId))';
            binds.put('cursorName', cursorName);
            binds.put('cursorEntryId', cursorEntryId);
        }

        // Keyset pagination avoids OFFSET and its 2,000-row limit.
        List<SObject> entries = Database.queryWithBinds(
            soql + ' ORDER BY Product2.Name ASC, Id ASC LIMIT ' + String.valueOf(safePageSize + 1),
            binds,
            AccessLevel.USER_MODE
        );
        Boolean hasMore = entries.size() > safePageSize;
        if (hasMore) {
            entries.remove(entries.size() - 1);
        }

        Set<Id> productIds = new Set<Id>();
        for (SObject entry : entries) {
            productIds.add((Id) entry.get('Product2Id'));
        }

        Map<Id, Map<String, Object>> landingCostData = productLandingCostData(productIds, config);
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        String userCurrency = UserInfo.getDefaultCurrency();

        for (SObject entry : entries) {
            SObject product = entry.getSObject('Product2');
            Map<String, Object> costData = landingCostData.get((Id) entry.get('Product2Id'));
            Object landingCost = costData == null ? null : costData.get('landingCost');
            Object convertedLandingCost = costData == null
                ? null
                : costData.get('convertedLandingCost');
            Object marginLandingCost = convertedLandingCost;
            String landingCostCurrencyIsoCode = costData == null
                ? null
                : (String) costData.get('landingCostCurrencyIsoCode');

            if (marginLandingCost == null && landingCostCurrencyIsoCode == userCurrency) {
                marginLandingCost = landingCost;
            }

            Object convertedUnitPrice = isMultiCurrency ? entry.get('convertedUnitPrice') : null;
            Object marginSalesPrice = isMultiCurrency ? convertedUnitPrice : entry.get('UnitPrice');
            Decimal marginValue = margin(marginSalesPrice, marginLandingCost);

            Map<String, Object> row = new Map<String, Object>{
                'Id' => entry.get('Id'),
                'pricebookEntryId' => entry.get('Id'),
                'productId' => entry.get('Product2Id'),
                'productName' => product.get('Name'),
                'listPrice' => entry.get('UnitPrice'),
                'unitPrice' => entry.get('UnitPrice'),
                'convertedUnitPrice' => convertedUnitPrice,
                'margin' => marginValue,
                'landingCost' => landingCost,
                'landingCostCurrencyIsoCode' => landingCostCurrencyIsoCode,
                'convertedLandingCost' => convertedLandingCost,
                'convertedCurrencyIsoCode' => costData == null
                    ? null
                    : costData.get('convertedCurrencyIsoCode')
            };

            if (canReadPricebookCurrency) {
                row.put('currencyIsoCode', entry.get('CurrencyIsoCode'));
            }

            for (Integer i = 0; i < columnPlans.size(); i++) {
                Map<String, Object> plan = columnPlans[i];
                Object value;
                String source = (String) plan.get('source');
                Boolean isUrl = (Boolean) plan.get('isUrl');

                if ((Boolean) plan.get('isLandingCost')) {
                    value = landingCost;
                } else if (source == SOURCE_PRODUCT) {
                    Object fieldValue = pathValue(product, (List<String>) plan.get('fieldPathParts'));
                    if (isUrl) {
                        Object targetId = pathValue(product, (List<String>) plan.get('urlFieldPathParts'));
                        value = targetId == null ? null : '/' + String.valueOf(targetId);
                        row.put('f' + i + 'Label', fieldValue);
                    } else {
                        value = fieldValue;
                    }
                } else if (source == SOURCE_PRICEBOOK_ENTRY) {
                    Object fieldValue = pathValue(entry, (List<String>) plan.get('fieldPathParts'));
                    if (isUrl) {
                        Object targetId = pathValue(entry, (List<String>) plan.get('urlFieldPathParts'));
                        value = targetId == null ? null : '/' + String.valueOf(targetId);
                        row.put('f' + i + 'Label', fieldValue);
                    } else {
                        value = fieldValue;
                    }
                } else {
                    value = marginValue;
                }

                row.put('f' + i, value);
            }

            rows.add(row);
        }

        String nextCursorName;
        Id nextCursorEntryId;
        if (hasMore && !entries.isEmpty()) {
            SObject lastEntry = entries[entries.size() - 1];
            nextCursorName = (String) lastEntry.getSObject('Product2').get('Name');
            nextCursorEntryId = (Id) lastEntry.get('Id');
        }

        return new Map<String, Object>{
            'columns' => cursorEntryId == null
                ? columnData(productColumns, SCREEN_ADD_PRODUCT)
                : new List<Map<String, Object>>(),
            'rows' => rows,
            'hasMore' => hasMore,
            'nextCursorName' => nextCursorName,
            'nextCursorEntryId' => nextCursorEntryId
        };
    }

    @AuraEnabled
    public static void changePricebook(Id recordId, Id pricebookId) {
        Product_Config_CC__mdt config = configFor(recordId);
        SObject parent = parentFor(config, recordId);
        if (isRestrictedNewBusinessOrder(config, parent)) {
            throw new AuraHandledException('Price Book changes are not allowed for New Business Orders.');
        }
        Id accountId = (Id) parent.get(config.Parent_Account_Field_API_Name_CC__c);
        Boolean isEligible = false;

        for (SObject pricebook : eligiblePricebooks(config, accountId)) {
            if ((Id) pricebook.get('Id') == pricebookId) {
                isEligible = true;
                break;
            }
        }

        if (!isEligible) {
            throw new AuraHandledException('This Price Book is not available for this record.');
        }

        Id oldPricebookId = (Id) parent.get(config.Parent_Pricebook_Field_API_Name_CC__c);
        if (oldPricebookId == pricebookId) {
            return;
        }

        String lineQuery = 'SELECT Id FROM ' + config.Line_Item_Object_API_Name_CC__c +
            ' WHERE ' + config.Parent_Lookup_Field_API_Name_CC__c + ' = :recordId';
        List<SObject> lines = Database.queryWithBinds(
            lineQuery,
            new Map<String, Object>{ 'recordId' => recordId },
            AccessLevel.USER_MODE
        );

        SObject parentUpdate = Schema.getGlobalDescribe()
            .get(config.Parent_Object_API_Name_CC__c)
            .newSObject(recordId);
        parentUpdate.put(config.Parent_Pricebook_Field_API_Name_CC__c, pricebookId);

        try {
            if (!lines.isEmpty()) {
                Database.delete(lines, true, AccessLevel.USER_MODE);
            }
            Database.update(parentUpdate, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            List<String> errorMessages = new List<String>();
            for (Integer i = 0; i < e.getNumDml(); i++) {
                String errorMessage = e.getDmlMessage(i);
                if (!String.isBlank(errorMessage) && !errorMessages.contains(errorMessage)) {
                    errorMessages.add(errorMessage);
                }
            }

            String message = errorMessages.isEmpty()
                ? e.getMessage()
                : String.join(errorMessages, '. ');
            AuraHandledException handledException = new AuraHandledException(message);
            handledException.setMessage(message);
            throw handledException;
        }
    }

    @AuraEnabled
    public static void saveProducts(
        Id recordId,
        String payloadJson,
        String deleteIdsJson
        // FUTURE PHASE: Add String siteAllocationJson when Site/Warehouse allocation becomes active.
    ) {
        Product_Config_CC__mdt config = configFor(recordId);
        List<Product_Column_Config_CC__mdt> editColumns = columns(config, SCREEN_EDIT_PRODUCTS);
        SObject parent = parentFor(config, recordId, editColumns);
        Boolean isRestrictedEditMode = isRestrictedNewBusinessOrder(config, parent);
        Id pricebookId = (Id) parent.get(config.Parent_Pricebook_Field_API_Name_CC__c);
        String parentCurrency = parentCurrencyIsoCode(parent);
        Map<String, Object> defaultValues = new Map<String, Object>();

        for (Product_Column_Config_CC__mdt column : editColumns) {
            String dataType = String.valueOf(column.Data_Type_CC__c).toLowerCase();
            Boolean isDate = dataType == 'date' || dataType == 'date-local';
            if (column.Field_Source_Type_CC__c != SOURCE_LINE_ITEM ||
                column.Editable_CC__c != true ||
                (isRestrictedEditMode && !isNewBusinessEditableField(column.Field_API_Name_CC__c)) ||
                (dataType != 'lookup' && dataType != 'picklist' && !isDate) ||
                String.isBlank(column.Default_Value_Field_Path_CC__c)) {
                continue;
            }

            String relativePath = parentRelativePath(
                config,
                column.Default_Value_Field_Path_CC__c
            );
            Object candidateValue = pathValue(parent, relativePath);

            if (dataType == 'lookup') {
                Map<String, Object> lineLookupInfo = lookupInfoForField(
                    config.Line_Item_Object_API_Name_CC__c,
                    column.Field_API_Name_CC__c
                );
                Map<String, Object> defaultLookupInfo = lookupInfoForPath(
                    config.Parent_Object_API_Name_CC__c,
                    relativePath
                );
                if ((String) lineLookupInfo.get('objectApiName') !=
                    (String) defaultLookupInfo.get('objectApiName')) {
                    throw new AuraHandledException(
                        'Default Value Field Path for ' + column.Field_API_Name_CC__c +
                        ' must reference ' + lineLookupInfo.get('objectApiName') + '.'
                    );
                }
                defaultValues.put(column.Field_API_Name_CC__c, candidateValue);
            } else if (dataType == 'picklist') {
                List<Map<String, Object>> options = picklistOptionsForField(
                    config.Line_Item_Object_API_Name_CC__c,
                    column.Field_API_Name_CC__c,
                    false
                );
                if (isActivePicklistApiValue(options, candidateValue)) {
                    defaultValues.put(
                        column.Field_API_Name_CC__c,
                        String.valueOf(candidateValue)
                    );
                }
            } else {
                validateDateDefaultPath(config, column.Field_API_Name_CC__c, relativePath);
                if (candidateValue != null) {
                    defaultValues.put(
                        column.Field_API_Name_CC__c,
                        String.valueOf(candidateValue)
                    );
                }
            }
        }

        Schema.SObjectType lineType =
            Schema.getGlobalDescribe().get(config.Line_Item_Object_API_Name_CC__c);
        Map<String, Schema.SObjectField> fieldMap = lineType.getDescribe().fields.getMap();
        Set<String> restrictedEditableConfigFields = new Set<String>();
        if (isRestrictedEditMode) {
            for (Product_Column_Config_CC__mdt column : editColumns) {
                if (column.Field_Source_Type_CC__c == SOURCE_LINE_ITEM &&
                    column.Editable_CC__c == true &&
                    isNewBusinessEditableField(column.Field_API_Name_CC__c)) {
                    restrictedEditableConfigFields.add(column.Field_API_Name_CC__c);
                }
            }
        }

        List<SObject> inserts = new List<SObject>();
        List<SObject> updates = new List<SObject>();
        List<SObject> deletes = new List<SObject>();
        Set<Id> entryIds = new Set<Id>();
        Set<Id> touchedIds = new Set<Id>();

        List<Object> payload = (List<Object>) JSON.deserializeUntyped(
            String.isBlank(payloadJson) ? '[]' : payloadJson
        );

        for (Object itemObject : payload) {
            Map<String, Object> item = (Map<String, Object>) itemObject;
            Id lineId = item.get('lineItemId') == null
                ? null
                : (Id) String.valueOf(item.get('lineItemId'));
            SObject line = lineType.newSObject();

            if (isRestrictedEditMode && lineId == null) {
                throw new AuraHandledException('Adding products is not allowed for New Business Orders.');
            }

            if (lineId == null) {
                Id entryId = (Id) String.valueOf(item.get('pricebookEntryId'));
                line.put(config.Parent_Lookup_Field_API_Name_CC__c, recordId);
                line.put('PricebookEntryId', entryId);
                entryIds.add(entryId);
            } else {
                if (lineId.getSObjectType().getDescribe().getName() !=
                    config.Line_Item_Object_API_Name_CC__c) {
                    throw new AuraHandledException('Invalid line item id.');
                }

                touchedIds.add(lineId);
                line.put('Id', lineId);
            }

            Map<String, Object> values = (Map<String, Object>) item.get('values');
            if (values == null) {
                values = new Map<String, Object>();
            }

            if (isRestrictedEditMode) {
                for (String submittedFieldName : values.keySet()) {
                    if (!isNewBusinessEditableField(submittedFieldName) ||
                        !restrictedEditableConfigFields.contains(submittedFieldName)) {
                        throw new AuraHandledException(
                            'Only Warehouse, Shipment Date and Location Code can be updated for New Business Orders.'
                        );
                    }
                }
            }

            for (Product_Column_Config_CC__mdt column : editColumns) {
                String dataType = String.valueOf(column.Data_Type_CC__c).toLowerCase();
                Boolean isDate = dataType == 'date' || dataType == 'date-local';
                if (column.Field_Source_Type_CC__c != SOURCE_LINE_ITEM ||
                    column.Editable_CC__c != true ||
                    (isRestrictedEditMode && !isNewBusinessEditableField(column.Field_API_Name_CC__c)) ||
                    (dataType != 'lookup' && dataType != 'picklist' && !isDate) ||
                    String.isBlank(column.Default_Value_Field_Path_CC__c)) {
                    continue;
                }

                Object currentValue = values.get(column.Field_API_Name_CC__c);
                if (currentValue == null || String.isBlank(String.valueOf(currentValue))) {
                    Object defaultValue = defaultValues.get(column.Field_API_Name_CC__c);
                    if (defaultValue != null) {
                        values.put(column.Field_API_Name_CC__c, defaultValue);
                    }
                }
            }

            for (Product_Column_Config_CC__mdt column : editColumns) {
                if (column.Field_Source_Type_CC__c == SOURCE_LINE_ITEM &&
                    column.Editable_CC__c == true &&
                    (!isRestrictedEditMode || isNewBusinessEditableField(column.Field_API_Name_CC__c)) &&
                    column.Required_CC__c == true &&
                    (values.get(column.Field_API_Name_CC__c) == null ||
                     String.isBlank(String.valueOf(values.get(column.Field_API_Name_CC__c))))) {
                    throw new AuraHandledException(column.Label_CC__c + ' is required.');
                }
            }

            for (String fieldName : values.keySet()) {
                if (!fieldMap.containsKey(fieldName)) {
                    throw new AuraHandledException('Invalid line item field: ' + fieldName);
                }

                Schema.DescribeFieldResult fieldInfo = fieldMap.get(fieldName).getDescribe();
                Boolean canWrite = lineId == null
                    ? fieldInfo.isCreateable()
                    : fieldInfo.isUpdateable();

                if (!canWrite) {
                    throw new AuraHandledException('Insufficient access to ' + fieldName);
                }

                line.put(
                    fieldName,
                    convertFieldValue(values.get(fieldName), fieldInfo.getType())
                );
            }

            if (lineId == null) {
                inserts.add(line);
            } else {
                updates.add(line);
            }
        }

        if (!entryIds.isEmpty()) {
            String entryQuery = 'SELECT Id, Pricebook2Id' +
                (String.isBlank(parentCurrency) ? '' : ', CurrencyIsoCode') +
                ' FROM PricebookEntry WHERE Id IN :entryIds';
            List<SObject> entries = Database.queryWithBinds(
                entryQuery,
                new Map<String, Object>{ 'entryIds' => entryIds },
                AccessLevel.USER_MODE
            );

            if (entries.size() != entryIds.size()) {
                throw new AuraHandledException('One or more selected products are unavailable.');
            }

            for (SObject entry : entries) {
                if ((Id) entry.get('Pricebook2Id') != pricebookId) {
                    throw new AuraHandledException(
                        'Selected products must belong to the record Price Book.'
                    );
                }

                if (!String.isBlank(parentCurrency) &&
                    (String) entry.get('CurrencyIsoCode') != parentCurrency) {
                    throw new AuraHandledException(
                        'The selected product currency must match the record currency (' +
                        parentCurrency + ').'
                    );
                }
            }
        }

        List<Object> deleteIds = (List<Object>) JSON.deserializeUntyped(
            String.isBlank(deleteIdsJson) ? '[]' : deleteIdsJson
        );

        if (isRestrictedEditMode && !deleteIds.isEmpty()) {
            throw new AuraHandledException('Deleting products is not allowed for New Business Orders.');
        }

        for (Object rawId : deleteIds) {
            Id lineId = (Id) String.valueOf(rawId);
            if (lineId.getSObjectType().getDescribe().getName() !=
                config.Line_Item_Object_API_Name_CC__c) {
                throw new AuraHandledException('Invalid line item id.');
            }

            touchedIds.add(lineId);
            deletes.add(lineType.newSObject(lineId));
        }

        if (!touchedIds.isEmpty()) {
            String ownedQuery = 'SELECT Id FROM ' + config.Line_Item_Object_API_Name_CC__c +
                ' WHERE Id IN :touchedIds' +
                ' AND ' + config.Parent_Lookup_Field_API_Name_CC__c + ' = :recordId';
            List<SObject> ownedLines = Database.queryWithBinds(
                ownedQuery,
                new Map<String, Object>{ 'touchedIds' => touchedIds, 'recordId' => recordId },
                AccessLevel.USER_MODE
            );

            if (ownedLines.size() != touchedIds.size()) {
                throw new AuraHandledException('One or more line items do not belong to this record.');
            }
        }

        try {
            if (!deletes.isEmpty()) {
                Database.delete(deletes, true, AccessLevel.USER_MODE);
            }
            if (!inserts.isEmpty()) {
                Database.insert(inserts, AccessLevel.USER_MODE);
            }
            if (!updates.isEmpty()) {
                Database.update(updates, AccessLevel.USER_MODE);
            }
        } catch (DmlException e) {
            List<String> errorMessages = new List<String>();
            for (Integer i = 0; i < e.getNumDml(); i++) {
                String errorMessage = e.getDmlMessage(i);
                if (!String.isBlank(errorMessage) && !errorMessages.contains(errorMessage)) {
                    errorMessages.add(errorMessage);
                }
            }

            String message = errorMessages.isEmpty()
                ? e.getMessage()
                : String.join(errorMessages, '. ');
            AuraHandledException handledException = new AuraHandledException(message);
            handledException.setMessage(message);
            throw handledException;
        }
    }

    private static Object convertFieldValue(
        Object value,
        Schema.DisplayType fieldType
    ) {
        if (value == null) {
            return null;
        }

        String rawValue = String.valueOf(value);

        if (fieldType == Schema.DisplayType.Date) {
            return Date.valueOf(rawValue);
        }

        if (fieldType == Schema.DisplayType.Double) {
            return Double.valueOf(rawValue);
        }

        if (fieldType == Schema.DisplayType.Currency ||
            fieldType == Schema.DisplayType.Percent) {
            return Decimal.valueOf(rawValue);
        }

        if (fieldType == Schema.DisplayType.Integer) {
            return Integer.valueOf(rawValue);
        }

        if (fieldType == Schema.DisplayType.Boolean) {
            return Boolean.valueOf(rawValue);
        }

        if (fieldType == Schema.DisplayType.Reference) {
            return Id.valueOf(rawValue);
        }

        return value;
    }


    // -------------------------------------------------------------------------
    // FUTURE SCOPE: Site/Warehouse allocation (parked until this phase is active)
    // -------------------------------------------------------------------------
    // FUTURE PHASE: private static final String SCREEN_SITE_ALLOCATION = 'SITE ALLOCATION';

    // FUTURE PHASE: Site/Warehouse schema helpers, Account Site/Entity retrieval, inventory lookup,
    // existing allocation retrieval, and getSiteAllocationData endpoint.
//     private static final String SITE_DELIVERABILITY_OBJECT = 'Line_Item_Deliverability_For_Sites_CC__c';
//
//     private static String deliverabilityLineLookupField(String lineItemObjectName) {
//         if (lineItemObjectName == 'OpportunityLineItem') {
//             return 'Opportunity_Line_Item_CC__c';
//         }
//         if (lineItemObjectName == 'QuoteLineItem') {
//             return 'Quote_Line_Item_CC__c';
//         }
//         if (lineItemObjectName == 'OrderItem') {
//             return 'Order_Product_CC__c';
//         }
//
//         throw new AuraHandledException(
//             'Site allocation is not configured for line item object ' + lineItemObjectName + '.'
//         );
//     }
//
//     private static void validateSiteDeliverabilitySchema(
//         String lineItemObjectName,
//         Boolean requireDeleteAccess
//     ) {
//         Schema.SObjectType allocationType = Schema.getGlobalDescribe().get(SITE_DELIVERABILITY_OBJECT);
//
//         if (allocationType == null) {
//             throw new AuraHandledException(
//                 'Create the ' + SITE_DELIVERABILITY_OBJECT + ' object before saving Site allocations.'
//             );
//         }
//
//         Schema.DescribeSObjectResult allocationDescribe = allocationType.getDescribe();
//         if (!allocationDescribe.isAccessible() || !allocationDescribe.isCreateable() ||
//             (requireDeleteAccess && !allocationDescribe.isDeletable())) {
//             throw new AuraHandledException(
//                 'You need Read, Create and Delete access to ' + SITE_DELIVERABILITY_OBJECT + '.'
//             );
//         }
//
//         String lineLookupField = deliverabilityLineLookupField(lineItemObjectName);
//         Map<String, Schema.SObjectField> fields = allocationDescribe.fields.getMap();
//         List<String> requiredFields = new List<String>{
//             'Sites_CC__c',
//             'Warehouse_CC__c',
//             'Quantity_CC__c',
//             lineLookupField
//         };
//
//         for (String fieldName : requiredFields) {
//             if (!fields.containsKey(fieldName)) {
//                 throw new AuraHandledException(
//                     'Create the ' + fieldName + ' field on ' + SITE_DELIVERABILITY_OBJECT +
//                     ' before using Site allocations.'
//                 );
//             }
//             Schema.DescribeFieldResult fieldInfo = fields.get(fieldName).getDescribe();
//             if (!fieldInfo.isAccessible() || !fieldInfo.isCreateable()) {
//                 throw new AuraHandledException(
//                     'You need Read and Create access to ' + fieldName + ' on ' + SITE_DELIVERABILITY_OBJECT + '.'
//                 );
//             }
//         }
//     }
//
//     private static String accountShippingAddress(Account site) {
//         List<String> addressLines = new List<String>();
//         List<String> localityParts = new List<String>();
//
//         if (!String.isBlank(site.ShippingStreet)) {
//             addressLines.add(site.ShippingStreet);
//         }
//         if (!String.isBlank(site.ShippingCity)) {
//             localityParts.add(site.ShippingCity);
//         }
//         if (!String.isBlank(site.ShippingState)) {
//             localityParts.add(site.ShippingState);
//         }
//         if (!String.isBlank(site.ShippingPostalCode)) {
//             localityParts.add(site.ShippingPostalCode);
//         }
//         if (!localityParts.isEmpty()) {
//             addressLines.add(String.join(localityParts, ', '));
//         }
//         if (!String.isBlank(site.ShippingCountry)) {
//             addressLines.add(site.ShippingCountry);
//         }
//
//         return String.join(addressLines, ', ');
//     }
//
//     /**
//      * Loads Site, Warehouse, inventory and existing line-item allocations in one request.
//      */
//     @AuraEnabled
//     public static Map<String, Object> getSiteAllocationData(
//         Id recordId,
//         List<Id> productIds,
//         List<Id> lineItemIds
//     ) {
//         Product_Config_CC__mdt config = configFor(recordId);
//         if (config.Show_Sites_Warehouses_Selection_CC__c != true) {
//             throw new AuraHandledException(
//                 'Site and Warehouse selection is not enabled for this record.'
//             );
//         }
//
//         // Validate the junction object only when loading existing allocations.
//         // New products do not have line item IDs until the final Save operation.
//         if (lineItemIds != null && !lineItemIds.isEmpty()) {
//             validateSiteDeliverabilitySchema(
//                 config.Line_Item_Object_API_Name_CC__c,
//                 false
//             );
//         }
//
//         SObject parent = parentFor(config, recordId);
//         Id entityAccountId = (Id) parent.get(config.Parent_Account_Field_API_Name_CC__c);
//         if (entityAccountId == null) {
//             throw new AuraHandledException('The parent record is not associated with an Entity.');
//         }
//
//         List<RecordType> siteRecordTypes = [
//             SELECT Id
//             FROM RecordType
//             WHERE SobjectType = 'Account'
//               AND DeveloperName = 'Site'
//             LIMIT 1
//         ];
//         if (siteRecordTypes.isEmpty()) {
//             throw new AuraHandledException('The Site Account record type was not found.');
//         }
//
//         Id siteRecordTypeId = siteRecordTypes[0].Id;
//         Set<String> siteFields = new Set<String>{
//             'Id', 'Name', 'ShippingStreet', 'ShippingCity', 'ShippingState',
//             'ShippingPostalCode', 'ShippingCountry'
//         };
//         Boolean canReadDefaultWarehouse = canReadField('Account', 'Warehouse_CC__c');
//         if (canReadDefaultWarehouse) {
//             siteFields.add('Warehouse_CC__c');
//             siteFields.add('Warehouse_CC__r.Name');
//         }
//
//         String siteQuery = 'SELECT ' + String.join(new List<String>(siteFields), ',') +
//             ' FROM Account WHERE ParentId = :entityAccountId' +
//             ' AND RecordTypeId = :siteRecordTypeId ORDER BY Name';
//         List<SObject> siteAccounts = Database.queryWithBinds(
//             siteQuery,
//             new Map<String, Object>{
//                 'entityAccountId' => entityAccountId,
//                 'siteRecordTypeId' => siteRecordTypeId
//             },
//             AccessLevel.USER_MODE
//         );
//
//         List<Map<String, Object>> sites = new List<Map<String, Object>>();
//         for (SObject siteRecord : siteAccounts) {
//             Account site = (Account) siteRecord;
//             Map<String, Object> siteData = new Map<String, Object>{
//                 'Id' => site.Id,
//                 'name' => site.Name,
//                 'shippingAddress' => accountShippingAddress(site)
//             };
//
//             if (canReadDefaultWarehouse) {
//                 siteData.put('defaultWarehouseId', siteRecord.get('Warehouse_CC__c'));
//                 siteData.put('defaultWarehouseName', pathValue(siteRecord, 'Warehouse_CC__r.Name'));
//             }
//             sites.add(siteData);
//         }
//
//         List<Warehouse_CC__c> warehouseRecords = [
//             SELECT Id, Name
//             FROM Warehouse_CC__c
//             WITH USER_MODE
//             ORDER BY Name
//         ];
//
//         List<Map<String, Object>> warehouses = new List<Map<String, Object>>();
//         for (Warehouse_CC__c warehouse : warehouseRecords) {
//             warehouses.add(new Map<String, Object>{
//                 'Id' => warehouse.Id,
//                 'name' => warehouse.Name
//             });
//         }
//
//         Set<Id> selectedProductIds = new Set<Id>();
//         if (productIds != null) {
//             selectedProductIds.addAll(productIds);
//         }
//
//         List<Map<String, Object>> inventory = new List<Map<String, Object>>();
//         if (!selectedProductIds.isEmpty()) {
//             for (Product_Warehouse_Inventory_CC__c item : [
//                 SELECT Product_CC__c, Warehouse_CC__c, Available_CC__c
//                 FROM Product_Warehouse_Inventory_CC__c
//                 WHERE Product_CC__c IN :selectedProductIds
//                 WITH USER_MODE
//             ]) {
//                 inventory.add(new Map<String, Object>{
//                     'productId' => item.Product_CC__c,
//                     'warehouseId' => item.Warehouse_CC__c,
//                     'available' => item.Available_CC__c == null ? 0 : item.Available_CC__c
//                 });
//             }
//         }
//
//         Set<Id> ownedLineItemIds = new Set<Id>();
//         if (lineItemIds != null && !lineItemIds.isEmpty()) {
//             String lineQuery = 'SELECT Id FROM ' + config.Line_Item_Object_API_Name_CC__c +
//                 ' WHERE Id IN :lineItemIds AND ' +
//                 config.Parent_Lookup_Field_API_Name_CC__c + ' = :recordId';
//             for (SObject lineItem : Database.queryWithBinds(
//                 lineQuery,
//                 new Map<String, Object>{ 'lineItemIds' => lineItemIds, 'recordId' => recordId },
//                 AccessLevel.USER_MODE
//             )) {
//                 ownedLineItemIds.add((Id) lineItem.get('Id'));
//             }
//
//             if (ownedLineItemIds.size() != lineItemIds.size()) {
//                 throw new AuraHandledException('One or more line items do not belong to this record.');
//             }
//         }
//
//         List<Map<String, Object>> allocations = new List<Map<String, Object>>();
//         if (!ownedLineItemIds.isEmpty()) {
//             String lineLookupField = deliverabilityLineLookupField(
//                 config.Line_Item_Object_API_Name_CC__c
//             );
//             String allocationQuery = 'SELECT Id, Sites_CC__c, Sites_CC__r.Name,' +
//                 ' Warehouse_CC__c, Warehouse_CC__r.Name, Quantity_CC__c, ' + lineLookupField +
//                 ' FROM ' + SITE_DELIVERABILITY_OBJECT +
//                 ' WHERE ' + lineLookupField + ' IN :ownedLineItemIds ORDER BY CreatedDate';
//
//             for (SObject allocation : Database.queryWithBinds(
//                 allocationQuery,
//                 new Map<String, Object>{ 'ownedLineItemIds' => ownedLineItemIds },
//                 AccessLevel.USER_MODE
//             )) {
//                 allocations.add(new Map<String, Object>{
//                     'id' => allocation.get('Id'),
//                     'lineItemId' => allocation.get(lineLookupField),
//                     'siteId' => allocation.get('Sites_CC__c'),
//                     'siteName' => pathValue(allocation, 'Sites_CC__r.Name'),
//                     'warehouseId' => allocation.get('Warehouse_CC__c'),
//                     'warehouseName' => pathValue(allocation, 'Warehouse_CC__r.Name'),
//                     'quantity' => allocation.get('Quantity_CC__c')
//                 });
//             }
//         }
//
//         return new Map<String, Object>{
//             'entityAccountId' => entityAccountId,
//             'siteRecordTypeId' => siteRecordTypeId,
//             'sites' => sites,
//             'warehouses' => warehouses,
//             'inventory' => inventory,
//             'allocations' => allocations
//         };
//     }
//

    /* FUTURE PHASE: Site/Warehouse allocation persistence.
    @AuraEnabled
    public static void saveProducts(
        Id recordId,
        String payloadJson,
        String deleteIdsJson,
        String siteAllocationJson
    ) {
        Product_Config_CC__mdt config = configFor(recordId);
        Boolean saveSiteAllocations = config.Show_Sites_Warehouses_Selection_CC__c == true;
        Id pricebookId = (Id) parentFor(config, recordId)
            .get(config.Parent_Pricebook_Field_API_Name_CC__c);

        if (saveSiteAllocations && String.isBlank(siteAllocationJson)) {
            throw new AuraHandledException('Site allocation data is required before saving these products.');
        }
        if (saveSiteAllocations) {
            validateSiteDeliverabilitySchema(config.Line_Item_Object_API_Name_CC__c, true);
        }

        Schema.SObjectType lineType =
            Schema.getGlobalDescribe().get(config.Line_Item_Object_API_Name_CC__c);
        Map<String, Schema.SObjectField> fieldMap = lineType.getDescribe().fields.getMap();

        List<SObject> inserts = new List<SObject>();
        List<SObject> updates = new List<SObject>();
        List<SObject> deletes = new List<SObject>();
        List<String> insertClientKeys = new List<String>();
        Set<Id> entryIds = new Set<Id>();
        Set<Id> touchedIds = new Set<Id>();
        Set<Id> allocationLineIds = new Set<Id>();
        Map<String, Id> lineIdsByClientKey = new Map<String, Id>();

        List<Object> payload = (List<Object>) JSON.deserializeUntyped(
            String.isBlank(payloadJson) ? '[]' : payloadJson
        );

        for (Object itemObject : payload) {
            Map<String, Object> item = (Map<String, Object>) itemObject;
            Id lineId = item.get('lineItemId') == null
                ? null
                : (Id) String.valueOf(item.get('lineItemId'));
            String clientKey = item.get('clientKey') == null
                ? (lineId == null ? String.valueOf(item.get('pricebookEntryId')) : String.valueOf(lineId))
                : String.valueOf(item.get('clientKey'));
            SObject line = lineType.newSObject();

            if (lineId == null) {
                Id entryId = (Id) String.valueOf(item.get('pricebookEntryId'));
                line.put(config.Parent_Lookup_Field_API_Name_CC__c, recordId);
                line.put('PricebookEntryId', entryId);
                entryIds.add(entryId);
                insertClientKeys.add(clientKey);
            } else {
                if (lineId.getSObjectType().getDescribe().getName() !=
                    config.Line_Item_Object_API_Name_CC__c) {
                    throw new AuraHandledException('Invalid line item id.');
                }

                touchedIds.add(lineId);
                if (saveSiteAllocations) {
                    allocationLineIds.add(lineId);
                }
                lineIdsByClientKey.put(clientKey, lineId);
                line.put('Id', lineId);
            }

            Map<String, Object> values = (Map<String, Object>) item.get('values');
            if (values != null) {
                for (String fieldName : values.keySet()) {
                    if (!fieldMap.containsKey(fieldName)) {
                        throw new AuraHandledException('Invalid line item field: ' + fieldName);
                    }

                    Schema.DescribeFieldResult fieldInfo = fieldMap.get(fieldName).getDescribe();
                    Boolean canWrite = lineId == null
                        ? fieldInfo.isCreateable()
                        : fieldInfo.isUpdateable();

                    if (!canWrite) {
                        throw new AuraHandledException('Insufficient access to ' + fieldName);
                    }

                    line.put(
                        fieldName,
                        convertFieldValue(values.get(fieldName), fieldInfo.getType())
                    );
                }
            }

            if (lineId == null) {
                inserts.add(line);
            } else {
                updates.add(line);
            }
        }

        if (!entryIds.isEmpty()) {
            List<SObject> entries = Database.queryWithBinds(
                'SELECT Id, Pricebook2Id FROM PricebookEntry WHERE Id IN :entryIds',
                new Map<String, Object>{ 'entryIds' => entryIds },
                AccessLevel.USER_MODE
            );

            if (entries.size() != entryIds.size()) {
                throw new AuraHandledException('One or more selected products are unavailable.');
            }

            for (SObject entry : entries) {
                if ((Id) entry.get('Pricebook2Id') != pricebookId) {
                    throw new AuraHandledException(
                        'Selected products must belong to the record Price Book.'
                    );
                }
            }
        }

        List<Object> deleteIds = (List<Object>) JSON.deserializeUntyped(
            String.isBlank(deleteIdsJson) ? '[]' : deleteIdsJson
        );

        for (Object rawId : deleteIds) {
            Id lineId = (Id) String.valueOf(rawId);
            if (lineId.getSObjectType().getDescribe().getName() !=
                config.Line_Item_Object_API_Name_CC__c) {
                throw new AuraHandledException('Invalid line item id.');
            }

            touchedIds.add(lineId);
            if (saveSiteAllocations) {
                allocationLineIds.add(lineId);
            }
            deletes.add(lineType.newSObject(lineId));
        }

        if (!touchedIds.isEmpty()) {
            String ownedQuery = 'SELECT Id FROM ' + config.Line_Item_Object_API_Name_CC__c +
                ' WHERE Id IN :touchedIds' +
                ' AND ' + config.Parent_Lookup_Field_API_Name_CC__c + ' = :recordId';
            List<SObject> ownedLines = Database.queryWithBinds(
                ownedQuery,
                new Map<String, Object>{ 'touchedIds' => touchedIds, 'recordId' => recordId },
                AccessLevel.USER_MODE
            );

            if (ownedLines.size() != touchedIds.size()) {
                throw new AuraHandledException('One or more line items do not belong to this record.');
            }
        }

        List<Object> allocationPayload = new List<Object>();
        if (saveSiteAllocations) {
            allocationPayload = (List<Object>) JSON.deserializeUntyped(siteAllocationJson);
            if (allocationPayload.size() != payload.size()) {
                throw new AuraHandledException('Every saved product must have Site allocation information.');
            }

            for (Object allocationObject : allocationPayload) {
                Map<String, Object> productAllocation = (Map<String, Object>) allocationObject;
                String clientKey = String.valueOf(productAllocation.get('clientKey'));
                if (String.isBlank(clientKey)) {
                    throw new AuraHandledException('A product allocation is missing its client key.');
                }
                List<Object> siteRows = (List<Object>) productAllocation.get('siteRows');
                if (siteRows == null || siteRows.isEmpty()) {
                    throw new AuraHandledException('Add at least one Site allocation for every product.');
                }

                for (Object siteObject : siteRows) {
                    Map<String, Object> siteData = (Map<String, Object>) siteObject;
                    if (siteData.get('siteId') == null || siteData.get('warehouseId') == null ||
                        siteData.get('quantity') == null) {
                        throw new AuraHandledException('Every Site allocation requires a Site, Warehouse and Quantity.');
                    }

                    Decimal quantity = Decimal.valueOf(String.valueOf(siteData.get('quantity')));
                    if (quantity <= 0 || quantity != quantity.setScale(0)) {
                        throw new AuraHandledException('Site allocation Quantity must be a positive whole number.');
                    }
                }
            }
        }

        // Replace existing allocations for updated line items and remove allocations
        // for line items deleted in this same save transaction.
        if (saveSiteAllocations && !allocationLineIds.isEmpty()) {
            String lineLookupField = deliverabilityLineLookupField(
                config.Line_Item_Object_API_Name_CC__c
            );
            String allocationDeleteQuery = 'SELECT Id FROM ' + SITE_DELIVERABILITY_OBJECT +
                ' WHERE ' + lineLookupField + ' IN :allocationLineIds';
            List<SObject> oldAllocations = Database.queryWithBinds(
                allocationDeleteQuery,
                new Map<String, Object>{ 'allocationLineIds' => allocationLineIds },
                AccessLevel.USER_MODE
            );
            if (!oldAllocations.isEmpty()) {
                Database.delete(oldAllocations, true, AccessLevel.USER_MODE);
            }
        }

        if (!deletes.isEmpty()) {
            Database.delete(deletes, true, AccessLevel.USER_MODE);
        }
        if (!inserts.isEmpty()) {
            Database.insert(inserts, AccessLevel.USER_MODE);
            for (Integer i = 0; i < inserts.size(); i++) {
                Id insertedLineId = (Id) inserts[i].get('Id');
                lineIdsByClientKey.put(insertClientKeys[i], insertedLineId);
                if (saveSiteAllocations) {
                    allocationLineIds.add(insertedLineId);
                }
            }
        }
        if (!updates.isEmpty()) {
            Database.update(updates, AccessLevel.USER_MODE);
        }

        if (saveSiteAllocations) {
            saveSiteDeliverabilityRecords(
                config,
                allocationPayload,
                lineIdsByClientKey,
                recordId
            );
        }
    }

    private static void saveSiteDeliverabilityRecords(
        Product_Config_CC__mdt config,
        List<Object> allocationPayload,
        Map<String, Id> lineIdsByClientKey,
        Id recordId
    ) {
        SObject parent = parentFor(config, recordId);
        Id entityAccountId = (Id) parent.get(config.Parent_Account_Field_API_Name_CC__c);
        Id siteRecordTypeId;
        List<RecordType> siteRecordTypes = [
            SELECT Id
            FROM RecordType
            WHERE SobjectType = 'Account' AND DeveloperName = 'Site'
            LIMIT 1
        ];
        if (siteRecordTypes.isEmpty()) {
            throw new AuraHandledException('The Site Account record type was not found.');
        }
        siteRecordTypeId = siteRecordTypes[0].Id;

        String lineLookupField = deliverabilityLineLookupField(
            config.Line_Item_Object_API_Name_CC__c
        );
        Set<Id> siteIds = new Set<Id>();
        Set<Id> warehouseIds = new Set<Id>();
        List<Map<String, Object>> normalizedRows = new List<Map<String, Object>>();

        for (Object productObject : allocationPayload) {
            Map<String, Object> productData = (Map<String, Object>) productObject;
            String clientKey = String.valueOf(productData.get('clientKey'));
            Id lineItemId = lineIdsByClientKey.get(clientKey);
            if (lineItemId == null) {
                throw new AuraHandledException('Unable to find the saved line item for a Site allocation.');
            }

            List<Object> siteRows = (List<Object>) productData.get('siteRows');
            for (Object siteObject : siteRows) {
                Map<String, Object> siteData = (Map<String, Object>) siteObject;
                Id siteId = (Id) String.valueOf(siteData.get('siteId'));
                Id warehouseId = (Id) String.valueOf(siteData.get('warehouseId'));
                Decimal quantity = Decimal.valueOf(String.valueOf(siteData.get('quantity')));

                siteIds.add(siteId);
                warehouseIds.add(warehouseId);
                normalizedRows.add(new Map<String, Object>{
                    'lineItemId' => lineItemId,
                    'siteId' => siteId,
                    'warehouseId' => warehouseId,
                    'quantity' => quantity
                });
            }
        }

        Map<Id, Account> validSites = new Map<Id, Account>([
            SELECT Id, ParentId, RecordTypeId
            FROM Account
            WHERE Id IN :siteIds
              AND ParentId = :entityAccountId
              AND RecordTypeId = :siteRecordTypeId
            WITH USER_MODE
        ]);
        if (validSites.size() != siteIds.size()) {
            throw new AuraHandledException('Select Sites that belong to the Entity on this record.');
        }

        Set<Id> validWarehouses = new Set<Id>();
        for (Warehouse_CC__c warehouse : [
            SELECT Id
            FROM Warehouse_CC__c
            WHERE Id IN :warehouseIds
            WITH USER_MODE
        ]) {
            validWarehouses.add(warehouse.Id);
        }
        if (validWarehouses.size() != warehouseIds.size()) {
            throw new AuraHandledException('One or more selected Warehouses are unavailable.');
        }

        Schema.SObjectType allocationType =
            Schema.getGlobalDescribe().get(SITE_DELIVERABILITY_OBJECT);
        List<SObject> recordsToInsert = new List<SObject>();

        for (Map<String, Object> rowData : normalizedRows) {
            SObject allocation = allocationType.newSObject();
            allocation.put('Sites_CC__c', rowData.get('siteId'));
            allocation.put('Warehouse_CC__c', rowData.get('warehouseId'));
            allocation.put('Quantity_CC__c', rowData.get('quantity'));
            allocation.put(lineLookupField, rowData.get('lineItemId'));
            recordsToInsert.add(allocation);
        }

        if (!recordsToInsert.isEmpty()) {
            Database.insert(recordsToInsert, AccessLevel.USER_MODE);
        }
    }

    */
}