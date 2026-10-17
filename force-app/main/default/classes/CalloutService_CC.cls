public without sharing class CalloutService_CC implements Queueable, Database.AllowsCallouts {
    
    private Set<Id> recordIds;
    private Map<Id, List<String>> changedFieldsMap; // New state variable
    private String operation;
    private Integer retryCount;
    private Integer maxRetries = 3;
    
    // Existing Constructors...
    public CalloutService_CC(Set<Id> recordIds, String operation) {
        this(recordIds, operation, 0);
    }
    
    private CalloutService_CC(Set<Id> recordIds, String operation, Integer retryCount) {
        this.recordIds = recordIds;
        this.operation = operation;
        this.retryCount = retryCount;
    }

    // NEW Constructors for dynamic field mapping
    public CalloutService_CC(Map<Id, List<String>> changedFieldsMap, String operation) {
        this(changedFieldsMap, operation, 0);
    }

    private CalloutService_CC(Map<Id, List<String>> changedFieldsMap, String operation, Integer retryCount) {
        this.recordIds = changedFieldsMap.keySet();
        this.changedFieldsMap = changedFieldsMap;
        this.operation = operation;
        this.retryCount = retryCount;
    }
    
    
    // Entry point. Supports both single and bulk records.
    
    public static void send(Id recordId, String operation) {
        send(new Set<Id>{ recordId }, operation);
    }
    public static void send(Map<Id, List<String>> changedFieldsMap, String operation) {
        if (UserInfo.getName() == 'Integration User') return;
        if(!changedFieldsMap.isEmpty()) {
            System.enqueueJob(new CalloutService_CC(changedFieldsMap, operation));
        }
    }
    public static void send(Set<Id> recordIds, String operation) {
        
        if (UserInfo.getName() == 'Integration User') return;
        if(!recordIds.isEmpty()) {
            System.enqueueJob(new CalloutService_CC(recordIds, operation));
        }
    }
    
    public void execute(QueueableContext context) {
        Integration_Config__mdt config = getConfig();
        if (config != null) {            
            try {
                List<SObject> records = getRecords(config);
                if (!records.isEmpty()) {
                    
                    // Build the bulk payload
                    String requestBody = buildBulkRequestBody(records, config);
                    
                    HttpRequest request = new HttpRequest();
                    request.setEndpoint(config.Endpoint__c);
                    request.setMethod('PUT'); // Hardcoded for Anypoint MQ
                    request.setHeader('Content-Type', 'application/json');
                    request.setBody(requestBody);
                    request.setTimeout(120000);
                    
                    HttpResponse response = new Http().send(request);                    
                    
                    if (response.getStatusCode() >= 200 && response.getStatusCode() < 300) {
                        createLogger('SUCCESS', 'MuleSoft bulk callout successful.', requestBody, response.getStatusCode(), response.getBody(), context.getJobId(), null);
                    } else if (config.Retry_Enabled__c && retryCount < maxRetries) {
                        createLogger('INFO', 'MuleSoft callout failed. Retrying.', requestBody, response.getStatusCode(), response.getBody(), context.getJobId(), null);
                        retry();
                    } else {
                        createLogger('ERROR', 'MuleSoft bulk callout failed after max retries.', requestBody, response.getStatusCode(), response.getBody(), context.getJobId(), null);

                        updateAccountSyncStatus(records, 'Callout Failed', config);
                    }
                }
            } catch (Exception e) {
                if (config.Retry_Enabled__c && retryCount < maxRetries) {
                    createLogger('INFO', 'Exception occurred during MuleSoft bulk callout. Retrying.', null, null, e.getMessage(), context.getJobId(), e);
                    retry();
                } else {
                    createLogger('ERROR', 'Fatal exception preparing MuleSoft bulk callout.', null, null, e.getMessage(), context.getJobId(), e);
                }
            }
        }
    }
    
    private Integration_Config__mdt getConfig() {
        
        Id recordId = recordIds.iterator().next();
        String objectName = recordId.getSObjectType().getDescribe().getName();
        System.debug('Contact check '+ objectName+' operation: '+ operation);
        List<Integration_Config__mdt> configs = [
            SELECT SObject_API_Name__c, Operation__c, Endpoint__c, 
            Request_Mapping__c, Payload_Template_CC__c, Active__c, Retry_Enabled__c, Request_Type__c
            FROM Integration_Config__mdt
            WHERE SObject_API_Name__c = :objectName
            AND Operation__c = :operation
            AND Active__c = true WITH SYSTEM_MODE
        ];
        
        return configs.isEmpty() ? null : configs[0];
    }
    

    private List<SObject> getRecords(Integration_Config__mdt config) {
        
        // Deserialize the JSON array (e.g., ["Id", "Name", "Tax_Area_CC__c"])
        List<Object> mappingArray = (List<Object>) JSON.deserializeUntyped(config.Request_Mapping__c);
        
        Set<String> fields = new Set<String>();
        for (Object fieldName : mappingArray) {
            fields.add((String) fieldName);
        }
        
        // Ensure Id is always queried just in case it was omitted from the mapping
        fields.add('Id');
        
        String objectName = config.SObject_API_Name__c;
        String soql = 'SELECT ' + String.join(new List<String>(fields), ',') + ' FROM ' + objectName + ' WHERE Id IN :recordIds WITH SYSTEM_MODE';
        return Database.query(soql);
    }
    /*
     * Dynamically builds the bulk payload using the new CDM format.
     */
    private String buildBulkRequestBody(List<SObject> records, Integration_Config__mdt config) {
        
        String template = config.Payload_Template_CC__c;
		String payloadOperation = (this.operation == 'SiteCreate') ? 'Create' : (this.operation == 'SiteUpdate' ? 'Update' : this.operation);        
        List<String> innerRecords = new List<String>();
        
        for (SObject record : records) {
            String escapedFieldsArray;
            
            // If we have a map of changed fields for this record (e.g., from an Update trigger)
            if (this.changedFieldsMap != null && this.changedFieldsMap.containsKey(record.Id)) {
                List<String> fieldsList = this.changedFieldsMap.get(record.Id);
                // Format directly to [\"Field1\",\"Field2\"]
                escapedFieldsArray = '[\\"' + String.join(fieldsList, '\\",\\"') + '\\"]';
            } else {
                // Fallback to the Custom Metadata mapping (e.g., for Create callouts)
                escapedFieldsArray = config.Request_Mapping__c.deleteWhitespace().replace('"', '\\"');
            }
            
            String innerRec = '{\\"recordId\\":\\"' + String.valueOf(record.Id) + '\\",\\"operation\\":\\"' + payloadOperation + '\\",\\"fields\\":' + escapedFieldsArray + '}';
            innerRecords.add(innerRec);
        }
        
        String innerRecordsJsonArray = '[' + String.join(innerRecords, ',') + ']';
        
        String eventId = UUID.randomUUID().toString();
        String timestampStr = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
        
        String payload = template
            .replace('{{eventId}}', eventId)
            .replace('{{timestamp}}', timestampStr)
            .replace('{{objectName}}', config.SObject_API_Name__c)
            .replace('{{records}}', innerRecordsJsonArray);
            
        return '[' + payload + ']';
    }

    private void retry() {
        if (this.changedFieldsMap != null) {
            System.enqueueJob(new CalloutService_CC(changedFieldsMap, operation, retryCount + 1));
        } else {
            System.enqueueJob(new CalloutService_CC(recordIds, operation, retryCount + 1));
        }
    }
    private void updateAccountSyncStatus(List<SObject> records, String status, Integration_Config__mdt config) {
        // Only update if the object is Account
        if (config.SObject_API_Name__c != 'Account') return;
        
        // ONLY track the status for top-level Entities ('Create')
        // Explicitly ignores 'SiteCreate', 'Update', and 'SiteUpdate'
        if (this.operation != 'Create') return;

        List<Account> accountsToUpdate = new List<Account>();
        for (SObject rec : records) {
            accountsToUpdate.add(new Account(
                Id = (Id)rec.get('Id'),
                BC_Sync_Status_CC__c = status
            ));
        }

        if (!accountsToUpdate.isEmpty()) {
            // Use Database.update with false to prevent one locked record from failing the whole status update
            Database.update(accountsToUpdate, false);
        }
    }
    // Create integration logger record.
    private void createLogger(String logLevel, String message, String requestBody, Integer statusCode, String responseBody, String transactionId, Exception exp) {
        
        Logger_CC__c logger = new Logger_CC__c();
        logger.Log_Level_CC__c = logLevel;
        logger.Message_CC__c = message;
        logger.Source_Type_CC__c = 'Integration';
        logger.Source_Class_CC__c = 'CalloutService_CC';
        logger.Origin_Location_CC__c = exp != null ? 'CalloutService_CC.execute - Line ' + exp.getLineNumber() : 'CalloutService_CC.execute';
        logger.Transaction_Id_CC__c = transactionId;
        logger.Related_Record_Ids_CC__c = getRelatedRecordIds();
        logger.Integration_Name_CC__c = 'MuleSoft';
        logger.Comments_CC__c = buildLogComments(requestBody, statusCode, responseBody, exp);
        
        insert logger;
    }
    
    private String getRelatedRecordIds() {
        List<String> ids = new List<String>();
        for(Id recordId : recordIds) {
            ids.add(String.valueOf(recordId));
        }
        return String.join(ids, ';');
    }
    
    private String buildLogComments(String requestBody, Integer statusCode, String responseBody, Exception exp) {
        
        List<String> comments = new List<String>();
        comments.add('Operation: ' + operation);
        if(statusCode != null) {
            comments.add('HTTP Status Code: ' + statusCode);
        }
        if(requestBody != null) {
            comments.add('Request Body: ' + requestBody);
        }
        if(responseBody != null) {
            comments.add('Response Body: ' + responseBody);
        }
        if(exp != null) {
            comments.add('Exception: ' + exp.getTypeName());
            comments.add('Line Number: ' + exp.getLineNumber());
            comments.add('Stack Trace: ' + exp.getStackTraceString());
        }
        return String.join(comments, '\n');
    }
}