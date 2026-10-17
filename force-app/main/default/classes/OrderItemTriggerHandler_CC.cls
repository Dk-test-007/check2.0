/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : OrderItemTriggerHandler_CC
 * Author          : <YourName>
 * Created Date    : Oct 7, 2026
 * Last Modified By: <YourName>
 * Last Modified On: Oct 7, 2026
 * Description     : This class implements for......
 *  
 * Change History  :
 *  Date          │   Author     │   Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  Oct 7, 2026  │ <YourName>   │ Initial version
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */

public without sharing class OrderItemTriggerHandler_CC extends BaseTriggerHandler_CC {

    public void run() {
        super.run(this, 'OrderItem');
    }

    public override void beforeUpdate() {
        validateActivatedOrderItemUpdate((List<OrderItem>) Trigger.new, (Map<Id, OrderItem>) Trigger.oldMap);
    }

    
    public override void beforeInsert() {
        populateUnitCostFromProduct((List<OrderItem>)Trigger.new);
    }

    public static void validateActivatedOrderItemUpdate(List<OrderItem> newItems, Map<Id, OrderItem> oldItems) {

        List<Profile> currentProfile = [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() LIMIT 1];
        if (!currentProfile.isEmpty() && currentProfile[0].Name == 'System Administrator') return;

        Set<Id> orderIds = new Set<Id>();

        for (OrderItem newItem : newItems) {
            if (newItem.OrderId != null) {
                orderIds.add(newItem.OrderId);
            }
        }

        if (orderIds.isEmpty()) return;

        Set<Id> activatedOrderIds = new Map<Id, Order>([SELECT Id FROM Order WHERE Id IN :orderIds AND Status = 'Activated']).keySet();

        if (activatedOrderIds.isEmpty()) return;

        Set<String> allowedFields = new Set<String>();
        String allowedLabel = System.Label.Accepted_OrderItem_Allowed_Fields_CC;

        if (String.isNotBlank(allowedLabel)) {
            for (String fieldName : allowedLabel.split(',')) {
                if (String.isNotBlank(fieldName)) {
                    allowedFields.add(fieldName.trim().toLowerCase());
                }
            }
        }

        Map<String, Schema.SObjectField> orderItemFields = Schema.SObjectType.OrderItem.fields.getMap();
        List<String> fieldsToValidate = new List<String>();

        for (String fieldName : orderItemFields.keySet()) {
            if (allowedFields.contains(fieldName.toLowerCase())) continue;

            Schema.DescribeFieldResult fieldDescribe = orderItemFields.get(fieldName).getDescribe();

            if (!fieldDescribe.isUpdateable() || fieldDescribe.isCalculated()) continue;

            fieldsToValidate.add(fieldName);
        }

        for (OrderItem newItem : newItems) {
            if (!activatedOrderIds.contains(newItem.OrderId)) continue;

            OrderItem oldItem = oldItems.get(newItem.Id);
            if (oldItem == null) continue;

            for (String fieldName : fieldsToValidate) {
                Object oldValue = oldItem.get(fieldName);
                Object newValue = newItem.get(fieldName);
                Boolean isChanged = false;

                if (oldValue == null && newValue == null) {
                    isChanged = false;
                } else if (oldValue == null || newValue == null) {
                    isChanged = true;
                } else if (oldValue instanceof String) {
                    isChanged = !((String) oldValue).equals((String) newValue);
                } else {
                    isChanged = oldValue != newValue;
                }

                if (isChanged) {
                    newItem.addError('Changes are not allowed on Order Products of an Activated Order.');
                    break;
                }
            }
        }
    }

    public static void populateUnitCostFromProduct(List<OrderItem> newItems) {
        Set<Id> pricebookEntryIds = new Set<Id>();

        for (OrderItem item : newItems) {
            if (item.PricebookEntryId != null) {
                pricebookEntryIds.add(item.PricebookEntryId);
            }
        }
        if (pricebookEntryIds.isEmpty()) return;

        Map<Id, PricebookEntry> entriesById = new Map<Id, PricebookEntry>([SELECT Id, Product2.Unit_Cost_CC__c FROM PricebookEntry WHERE Id IN :pricebookEntryIds WITH SYSTEM_MODE]);
        for (OrderItem item : newItems) {
            PricebookEntry entry = entriesById.get(item.PricebookEntryId);

            if (entry != null && entry.Product2 != null) {
                item.UnitCost = entry.Product2.Unit_Cost_CC__c;
            }
        }
    }

}