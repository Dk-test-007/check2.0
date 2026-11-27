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

    private static final String INTEGRATION_USER_NAME = 'Integration User';


    // Set while OrderTriggerHandler_CC copies header dates onto blank item dates, so that system update isn't blocked on Activated Orders
    public static Boolean bypassActivatedItemValidation = false;

    public void run() {
        super.run(this, 'OrderItem');
    }

    public override void beforeUpdate() {
        validateActivatedOrderItemUpdate((List<OrderItem>) Trigger.new, (Map<Id, OrderItem>) Trigger.oldMap);
    }

    
    public override void beforeInsert() {
        populateUnitCostFromProduct((List<OrderItem>)Trigger.new);
        updateWarehouseForNewBusinessOrder((List<OrderItem>)Trigger.new);
        updatePricebookEntryForBulkSalesOrder((List<OrderItem>)Trigger.new);
        defaultDatesFromOrder((List<OrderItem>)Trigger.new);
    }

    // Order Shipment Date defaults the item Shipment / Planned Shipment Dates, and the Order Due Date (EndDate) defaults the item Delivery Dates, only where the item value is blank
    public static void defaultDatesFromOrder(List<OrderItem> newItems) {
        Set<Id> orderIds = new Set<Id>();
        for (OrderItem item : newItems) {
            if (item.OrderId != null) {
                orderIds.add(item.OrderId);
            }
        }
        if (orderIds.isEmpty()) return;

        Map<Id, Order> ordersById = new Map<Id, Order>([SELECT Id, Shipment_Date_CC__c, EndDate FROM Order WHERE Id IN :orderIds WITH SYSTEM_MODE]);

        for (OrderItem item : newItems) {
            Order parentOrder = ordersById.get(item.OrderId);
            if (parentOrder != null) {
                applyOrderDates(item, parentOrder);
            }
        }
    }

    // Fills only the blank item dates from the Order header and returns true if any value was set
    public static Boolean applyOrderDates(OrderItem item, Order parentOrder) {
        Boolean isChanged = false;
        if (parentOrder.Shipment_Date_CC__c != null) {
            if (item.Shipment_Date_CC__c == null) { item.Shipment_Date_CC__c = parentOrder.Shipment_Date_CC__c; isChanged = true; }
            if (item.Planned_Shipment_Date_CC__c == null) { item.Planned_Shipment_Date_CC__c = parentOrder.Shipment_Date_CC__c; isChanged = true; }
        }
        if (parentOrder.EndDate != null) {
            if (item.Planned_Delivery_Date_CC__c == null) { item.Planned_Delivery_Date_CC__c = parentOrder.EndDate; isChanged = true; }
            if (item.Promised_Delivery_Date_CC__c == null) { item.Promised_Delivery_Date_CC__c = parentOrder.EndDate; isChanged = true; }
            if (item.Requested_Delivery_Date_CC__c == null) { item.Requested_Delivery_Date_CC__c = parentOrder.EndDate; isChanged = true; }
        }
        return isChanged;
    }

    public static void validateActivatedOrderItemUpdate(List<OrderItem> newItems, Map<Id, OrderItem> oldItems) {
        if (bypassActivatedItemValidation) return;

        // Integration Code: the Integration User can make any change to an Activated Order
        if (UserInfo.getName() == INTEGRATION_USER_NAME) return;

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
    
    public static void updateWarehouseForNewBusinessOrder(List<OrderItem> newItems) {
        Set<Id> orderIds = new Set<Id>();
        for(OrderItem ordItem: newItems) {
            orderIds.add(ordItem.OrderId);
        }
        
        Map<Id, Order> parentOrders = new Map<Id, Order>([SELECT Id, Ship_to_Customer_No_CC__r.Warehouse_CC__c FROM Order WHERE Id IN: orderIds AND Order_Source_CC__c IN ('Quote', 'Contract') WITH SYSTEM_MODE]);
        for(OrderItem ordItem: newItems) {
            if(parentOrders.containsKey(ordItem.OrderId) && parentOrders.get(ordItem.OrderId).Ship_to_Customer_No_CC__c != NULL) {
            	ordItem.Warehouse_CC__c = parentOrders.get(ordItem.OrderId).Ship_to_Customer_No_CC__r.Warehouse_CC__c;
            }
        }
    }
    


    public static void updatePricebookEntryForBulkSalesOrder(List<OrderItem> newItems) {
        
        Set<Id> orderIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();
        
        for (OrderItem item : newItems) {
            if (item.PricebookEntryId == null) {
                orderIds.add(item.OrderId);
                productIds.add(item.Product2Id);
            }        
        }
        
        Map<Id, Order> orderMap = new Map<Id, Order>([SELECT Id, Pricebook2Id, CurrencyIsoCode FROM Order WHERE Id IN :orderIds]);
        Map<String, PricebookEntry> pricebookEntryMap = new Map<String, PricebookEntry>();
        
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, Pricebook2Id, CurrencyIsoCode, UnitPrice
            FROM PricebookEntry
            WHERE Pricebook2Id IN (
                SELECT Pricebook2Id FROM Order WHERE Id IN :orderIds
            )
            AND Product2Id IN :productIds
            AND IsActive = true
        ]) {
            String key = pbe.Pricebook2Id + '-' + pbe.Product2Id + '-' + pbe.CurrencyIsoCode;
            pricebookEntryMap.put(key, pbe);
        }
        
        for (OrderItem item : newItems) {
            Order ord = orderMap.get(item.OrderId);
            
            if (ord != null && ord.Pricebook2Id != null) {
                String key = ord.Pricebook2Id + '-' + item.Product2Id + '-' + ord.CurrencyIsoCode;
                PricebookEntry pbe = pricebookEntryMap.get(key);
                
                if (pbe != null) {
                    item.PricebookEntryId = pbe.Id;
                    item.UnitPrice = pricebookEntryMap.get(key).UnitPrice;
                } else {
                    item.addError('No matching Price Book Entry found for this product and currency.');
                }
            }
        }
    }

}