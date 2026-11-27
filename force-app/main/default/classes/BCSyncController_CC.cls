/**
 * Controller for the bcSyncAction_CC quick action.
 *
 * Supports manual sync to Business Central for:
 *   - Account (Entity and Site record types)
 *   - Order
 *
 * CP-446: Accounts and Sites are only sent to Business Central when a user
 * starts the sync manually and confirms the pre-sync check message.
 * Contact sync has been removed from this action.
 */
public without sharing class BCSyncController_CC {

    private static final Set<String> POST_ACTIVATION_STATUSES = new Set<String>{ 'Activated', 'Released', 'Pending_Approval', 'Pending_Prepayment' };
    private static final String SITE_RECORD_TYPE = 'Site';
    private static final String SUCCESS = 'Success';
    private static final String ERROR_PREFIX = 'Error: ';

    // Integration Config records whose Request Mapping lists the fields sent to Business Central.
    private static final Map<String, String> REVIEW_CONFIG_BY_OPERATION = new Map<String, String>{
        'Create'     => 'Account_BC_Create',
        'Update'     => 'Account_BC_Update',
        'SiteCreate' => 'Site_BC_Create',
        'SiteUpdate' => 'Site_BC_Update'
    };

    public class ReviewField {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    /**
     * Details the LWC needs to build the confirmation message before anything is sent.
     * "operation" is server-side only and is not returned to the client.
     */
    public class SyncContext {
        @AuraEnabled public String recordLabel;
        @AuraEnabled public String recordName;
        @AuraEnabled public Boolean isAccount = false;
        @AuraEnabled public Boolean isResync = false;
        @AuraEnabled public Boolean canSync = false;
        @AuraEnabled public String blockingMessage;
        @AuraEnabled public List<ReviewField> reviewFields = new List<ReviewField>();
        // Set when a Site is blocked because its parent Entity is not synced, so the
        // user can be offered a link to the Entity. Only populated if they can read it.
        @AuraEnabled public Id parentRecordId;
        @AuraEnabled public String parentRecordName;
        public String operation;
    }

    /**
     * Called when the quick action opens. Runs the same checks as syncRecord
     * so the user sees any blocking issue before they are asked to confirm.
     * Nothing is sent to Business Central from this method.
     */
    @AuraEnabled
    public static SyncContext getSyncContext(Id recordId) {
        try {
            SyncContext ctx = evaluate(recordId);
            if (ctx.canSync && ctx.isAccount) {
                ctx.reviewFields = getReviewFields(recordId, REVIEW_CONFIG_BY_OPERATION.get(ctx.operation));
            }
            return ctx;
        } catch (Exception e) {
            AuraHandledException ex = new AuraHandledException(e.getMessage());
            ex.setMessage(e.getMessage());
            throw ex;
        }
    }

    /**
     * Called only after the user selects Continue in the confirmation message.
     * Re-runs all checks server-side before sending, so the client is never trusted.
     * objectApiName is kept for backward compatibility; the object is derived from the Id.
     */
    @AuraEnabled
    public static String syncRecord(Id recordId, String objectApiName) {
        try {
            SyncContext ctx = evaluate(recordId);
            if (!ctx.canSync) {
                return ERROR_PREFIX + ctx.blockingMessage;
            }
            CalloutService_CC.send(new Set<Id>{ recordId }, ctx.operation);
            return SUCCESS;
        } catch (Exception e) {
            return ERROR_PREFIX + e.getMessage();
        }
    }

    private static SyncContext evaluate(Id recordId) {
        if (recordId == null) {
            return block(new SyncContext(), 'No record was provided for the sync.');
        }

        Schema.DescribeSObjectResult objDescribe = recordId.getSObjectType().getDescribe();
        switch on objDescribe.getName() {
            when 'Account' {
                return evaluateAccount(recordId);
            }
            when 'Order' {
                return evaluateOrder(recordId);
            }
            when else {
                SyncContext ctx = new SyncContext();
                ctx.recordLabel = objDescribe.getLabel();
                return block(ctx, 'Business Central sync is not configured for the ' + objDescribe.getLabel() + ' object.');
            }
        }
    }

    private static SyncContext evaluateAccount(Id recordId) {
        Account acc = [
            SELECT Id, Name, RecordType.DeveloperName, Site_Synced_CC__c,
                   Business_Central_Customer_ID_CC__c,
                   ParentId, Parent.Name, Parent.Business_Central_Customer_ID_CC__c
            FROM Account
            WHERE Id = :recordId
            WITH SYSTEM_MODE LIMIT 1
        ];

        Boolean isSite = acc.RecordType?.DeveloperName == SITE_RECORD_TYPE;

        SyncContext ctx = new SyncContext();
        ctx.isAccount = true;
        ctx.recordName = acc.Name;
        ctx.recordLabel = isSite ? 'Site' : 'Entity';

        // Business rule: any user who can create or edit the record can sync it.
        if (!userCanEdit(acc.Id)) {
            return block(ctx, 'You do not have permission to edit this ' + ctx.recordLabel + ', so you cannot sync it to Business Central.');
        }

        if (isSite) {
            ctx.isResync = acc.Site_Synced_CC__c == true;
            ctx.operation = ctx.isResync ? 'SiteUpdate' : 'SiteCreate';

            if (String.isBlank(acc.Parent?.Business_Central_Customer_ID_CC__c)) {
                if (acc.ParentId != null && userCanRead(acc.ParentId)) {
                    ctx.parentRecordId = acc.ParentId;
                    ctx.parentRecordName = acc.Parent.Name;
                }
                return block(ctx, 'The parent Entity must be synced to Business Central before syncing this Site.');
            }
        } else {
            ctx.isResync = String.isNotBlank(acc.Business_Central_Customer_ID_CC__c);
            ctx.operation = ctx.isResync ? 'Update' : 'Create';
        }

        ctx.canSync = true;
        return ctx;
    }

    private static SyncContext evaluateOrder(Id recordId) {
        Order ord = [
            SELECT Id, OrderNumber, Status, External_Id_CC__c,
                   Sell_to_Customer_No_CC__r.Business_Central_Customer_ID_CC__c
            FROM Order
            WHERE Id = :recordId
            WITH SYSTEM_MODE LIMIT 1
        ];

        SyncContext ctx = new SyncContext();
        ctx.recordLabel = 'Order';
        ctx.recordName = ord.OrderNumber;
        ctx.isResync = String.isNotBlank(ord.External_Id_CC__c);
        ctx.operation = ctx.isResync ? 'Update' : 'Create';

        if (!POST_ACTIVATION_STATUSES.contains(ord.Status)) {
            return block(ctx, 'Only Activated Orders can be synced to Business Central.');
        }

        if (String.isBlank(ord.Sell_to_Customer_No_CC__r?.Business_Central_Customer_ID_CC__c)) {
            return block(ctx, 'The Sell-to Customer must be synced to Business Central before syncing this Order.');
        }

        ctx.canSync = true;
        return ctx;
    }

    /**
     * The class runs without sharing, so record access is checked explicitly.
     * Covers both object permission (Edit on Account) and record-level sharing.
     */
    private static Boolean userCanEdit(Id recordId) {
        if (!Schema.SObjectType.Account.isUpdateable()) {
            return false;
        }
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :recordId
            LIMIT 1
        ];
        return !access.isEmpty() && access[0].HasEditAccess;
    }

    // Used before offering a link to another record, so the user is never sent to a page they cannot open.
    private static Boolean userCanRead(Id recordId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasReadAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :recordId
            LIMIT 1
        ];
        return !access.isEmpty() && access[0].HasReadAccess;
    }

    /**
     * Reads the Request Mapping of the Integration Config record and returns each mapped
     * field with its current value on the Account. Returns an empty list if the config
     * cannot be read, so the sync itself is never blocked by this.
     */
    private static List<ReviewField> getReviewFields(Id recordId, String configName) {
        List<ReviewField> rows = new List<ReviewField>();
        try {
            SObject config = Database.query(
                'SELECT Request_Mapping__c FROM Integration_Config__mdt WHERE DeveloperName = :configName WITH SYSTEM_MODE LIMIT 1'
            )[0];
            List<String> paths = new List<String>();
            for (Object item : (List<Object>) JSON.deserializeUntyped((String) config.get('Request_Mapping__c'))) {
                String path = String.valueOf(item);
                if (!path.equalsIgnoreCase('Id')) {
                    paths.add(path);
                }
            }
            if (paths.isEmpty()) {
                return rows;
            }

            SObject acc = Database.query(
                'SELECT ' + String.join(paths, ', ') + ' FROM Account WHERE Id = :recordId LIMIT 1'
            )[0];
            Map<String, Schema.SObjectField> accountFields = Schema.SObjectType.Account.fields.getMap();

            for (String path : paths) {
                ReviewField row = new ReviewField();
                row.label = getLabel(path, accountFields);
                Object value = getValue(acc, path);
                row.value = value == null ? null
                    : value instanceof System.Address ? formatAddress((System.Address) value)
                    : String.valueOf(value);
                rows.add(row);
            }
        } catch (Exception e) {
            rows.clear();
        }
        return rows;
    }

    // "GLN_CC__c" -> field label; "Salesperson_Code_CC__r.Salesperson_Code_CC__c" -> lookup field label
    private static String getLabel(String path, Map<String, Schema.SObjectField> accountFields) {
        String fieldName = path;
        if (path.contains('.')) {
            String relationship = path.substringBefore('.');
            fieldName = relationship.endsWithIgnoreCase('__r')
                ? relationship.removeEndIgnoreCase('__r') + '__c'
                : relationship + 'Id';
        }
        Schema.SObjectField field = accountFields.get(fieldName);
        return field == null ? path : field.getDescribe().getLabel().removeEnd(' ID');
    }

    // Compound address fields (e.g. BillingAddress) -> "Street, City, State, Postal Code, Country"
    private static String formatAddress(System.Address address) {
        List<String> parts = new List<String>();
        for (String part : new List<String>{
                address.getStreet(), address.getCity(), address.getState(),
                address.getPostalCode(), address.getCountry() }) {
            if (String.isNotBlank(part)) {
                parts.add(part.replace('\r\n', ', ').replace('\n', ', ').trim());
            }
        }
        return parts.isEmpty() ? null : String.join(parts, ', ');
    }

    private static Object getValue(SObject record, String path) {
        List<String> parts = path.split('\\.');
        SObject current = record;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            current = current.getSObject(parts[i]);
            if (current == null) {
                return null;
            }
        }
        return current.get(parts[parts.size() - 1]);
    }

    private static SyncContext block(SyncContext ctx, String message) {
        ctx.canSync = false;
        ctx.blockingMessage = message;
        return ctx;
    }
}