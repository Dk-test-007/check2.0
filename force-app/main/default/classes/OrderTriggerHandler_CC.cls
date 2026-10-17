public without sharing class OrderTriggerHandler_CC extends BaseTriggerHandler_CC {
    
    private static final String NEW_BUSINESS_RECORD_TYPE = 'New_Business';
    private static final String INTEGRATION_USER_NAME = 'Integration User';
    
    public void run() {
        super.run(this, 'Order');
    }
    
    public override void beforeInsert() {
        validateQuoteSource((List<Order>) Trigger.new);
        syncAddressAndContractDetails((List<Order>) Trigger.new);
        syncCustomerNumberLookups();
        syncCustomerPriceGroup((List<Order>) Trigger.new);
        setContractOrderStatus((List<Order>) Trigger.new);
    }

    public override void beforeUpdate() {
        validateActivatedOrderUpdate((List<Order>)Trigger.new, (Map<Id, Order>)Trigger.oldMap);
        preventMultipleActivatedOrders((List<Order>)Trigger.new, (Map<Id, Order>)Trigger.oldMap);

    }
    
    public override void afterInsert() {
        createOrderItems((List<Order>) Trigger.new);
        updateShippingHandling((List<Order>) Trigger.new);
        recalculateBAUOpportunityAmounts((List<Order>)Trigger.new, null);
    }

    public override void afterUpdate(){
        publishActivatedOrdersToBusinessCentral((List<Order>) trigger.new, (Map<Id, Order>) trigger.oldMap);
        publishRelatedOrderItemsOnOrderSync((List<Order>) trigger.new, (Map<Id, Order>) trigger.oldMap);
        publishOrderUpdatesToBusinessCentral((List<Order>) trigger.new, (Map<Id, Order>) trigger.oldMap);
        recalculateBAUOpportunityAmounts((List<Order>)Trigger.new, null);
    }

    public override void afterDelete() {
        recalculateBAUOpportunityAmounts(null, (List<Order>)Trigger.old);
    }

    public override void afterUndelete() {
        recalculateBAUOpportunityAmounts((List<Order>)Trigger.new, null);
    }

    public static void publishActivatedOrdersToBusinessCentral(List<Order> newList, Map<Id, Order> oldMap) {
        if (UserInfo.getName() == INTEGRATION_USER_NAME) return;
        Set<Id> ordersToSync = new Set<Id>();
        for (Order ord : newList) {
            Order oldOrd = oldMap.get(ord.Id);
            if (ord.Status == 'Activated' && oldOrd.Status != 'Activated') {
                ordersToSync.add(ord.Id);
            }
        }

        if (!ordersToSync.isEmpty()) {
            CalloutService_CC.send(ordersToSync, 'Create');
        }
    }

    public static void publishOrderUpdatesToBusinessCentral(List<Order> newList, Map<Id, Order> oldMap) {
        if (UserInfo.getName() == INTEGRATION_USER_NAME) return;
        Set<String> trackedFields = new Set<String>();
        List<Integration_Config__mdt> configs = [SELECT Request_Mapping__c FROM Integration_Config__mdt WHERE SObject_API_Name__c = 'Order' AND Operation__c = 'Update' WITH SYSTEM_MODE LIMIT 1
        ];

        if (!configs.isEmpty() && String.isNotBlank(configs[0].Request_Mapping__c)) {
            List<String> mappedFieldsList = (List<String>) JSON.deserialize(configs[0].Request_Mapping__c, List<String>.class);
            for (String field : mappedFieldsList) {
                if (field != 'Id' && !field.contains('.')) {
                    trackedFields.add(field);
                }
            }
        }
        if (trackedFields.isEmpty()) return;

        Map<Id, List<String>> orderToChangedFields = new Map<Id, List<String>>();

        for (Order ord : newList) {
            Order oldOrd = oldMap.get(ord.Id);
            if (oldOrd == null) continue;
            
            if (String.isNotBlank(ord.External_Id_CC__c)) {
                List<String> changedFields = new List<String>();
                
                for (String field : trackedFields) {
                    if (ord.get(field) != oldOrd.get(field)) {
                        changedFields.add(field);
                    }
                }
                
                if (!changedFields.isEmpty()) {
                    orderToChangedFields.put(ord.Id, changedFields);
                }
            }
        }
        if (!orderToChangedFields.isEmpty()) {
            CalloutService_CC.send(orderToChangedFields, 'Update');
        }
    }

    public static void publishRelatedOrderItemsOnOrderSync(List<Order> newList, Map<Id, Order> oldMap) {
        Set<Id> syncedOrderIds = new Set<Id>();

        for (Order ord : newList) {
            Order oldOrd = oldMap.get(ord.Id);
            
            if (String.isBlank(oldOrd.External_Id_CC__c) && String.isNotBlank(ord.External_Id_CC__c)) {
                syncedOrderIds.add(ord.Id);
            }
        }

        if (syncedOrderIds.isEmpty()) return;

        Map<Id, OrderItem> relatedOrderItems = new Map<Id, OrderItem>([SELECT Id  FROM OrderItem  WHERE OrderId IN :syncedOrderIds]);
        if (!relatedOrderItems.isEmpty()) {
            CalloutService_CC.send(relatedOrderItems.keySet(), 'Create');
        }
    }
    
    public static void setContractOrderStatus(List<Order> newOrders) {
        for (Order orderRecord : newOrders) {
            if (orderRecord.ContractId != null) {
                orderRecord.Status = 'Draft';
            }
        }
    }
    
    public static void createOrderItems(List<Order> newOrders) {
        Set<Id> quoteIds = new Set<Id>();
        
        for (Order orderRecord : newOrders) {
            if (orderRecord.ContractId == null && orderRecord.QuoteId != null) {
                quoteIds.add(orderRecord.QuoteId);
            }
        }
        
        if (!quoteIds.isEmpty()) {
            createOrderItemsFromQuotes(newOrders, quoteIds);
        }
    }
    
    public static void createOrderItemsFromQuotes(List<Order> newOrders, Set<Id> quoteIds) {
        Map<Id, Quote> quotesById = new Map<Id, Quote>([SELECT Id, Pricebook2Id, OpportunityId, Opportunity.RecordType.DeveloperName FROM Quote WHERE Id IN :quoteIds]);
        Set<Id> newBusinessQuoteIds = new Set<Id>();
        
        for (Quote quoteRecord : quotesById.values()) {
            if (quoteRecord.OpportunityId != null && quoteRecord.Opportunity.RecordType.DeveloperName == NEW_BUSINESS_RECORD_TYPE) {
                newBusinessQuoteIds.add(quoteRecord.Id);
            }
        }
        
        if (newBusinessQuoteIds.isEmpty()) return;
        
        List<QuoteLineItem> quoteLineItems = [ SELECT Id, QuoteId, PricebookEntryId, Quantity, UnitPrice, Description, ServiceDate FROM QuoteLineItem WHERE QuoteId IN :newBusinessQuoteIds];
        if (quoteLineItems.isEmpty()) return;
        
        Map<Id, List<QuoteLineItem>> quoteToLineItems = new Map<Id, List<QuoteLineItem>>();
        
        for (QuoteLineItem quoteLineItem : quoteLineItems) {
            if (!quoteToLineItems.containsKey(quoteLineItem.QuoteId)) {
                quoteToLineItems.put(quoteLineItem.QuoteId, new List<QuoteLineItem>());
            }
            
            quoteToLineItems.get(quoteLineItem.QuoteId).add(quoteLineItem);
        }
        
        List<Order> ordersToUpdate = new List<Order>();
        
        for (Order orderRecord : newOrders) {
            Quote quoteRecord = quotesById.get(orderRecord.QuoteId);
            
            if (quoteRecord != null && orderRecord.Pricebook2Id == null && quoteRecord.Pricebook2Id != null) { 
                ordersToUpdate.add(new Order( Id = orderRecord.Id, Pricebook2Id = quoteRecord.Pricebook2Id));
            }
        }
        
        if (!ordersToUpdate.isEmpty()) update ordersToUpdate;
        
        List<OrderItem> orderItemsToInsert = new List<OrderItem>();
        
        for (Order orderRecord : newOrders) {
            List<QuoteLineItem> sourceLineItems = quoteToLineItems.get(orderRecord.QuoteId);
            
            if (sourceLineItems == null) continue;
            
            for (QuoteLineItem sourceLineItem : sourceLineItems) {
                orderItemsToInsert.add(new OrderItem(OrderId = orderRecord.Id, PricebookEntryId = sourceLineItem.PricebookEntryId, Quantity = sourceLineItem.Quantity,
                                                    UnitPrice = sourceLineItem.UnitPrice, Description = sourceLineItem.Description, ServiceDate = sourceLineItem.ServiceDate,
                                                    QuoteLineItemId = sourceLineItem.Id));
            }
        }
        
        //if (!orderItemsToInsert.isEmpty()) insert orderItemsToInsert;
        if (!orderItemsToInsert.isEmpty()) {
            Database.insert(orderItemsToInsert, AccessLevel.SYSTEM_MODE);
        }
    }
    
    public static void syncAddressAndContractDetails(List<Order> newOrders) {
        Set<Id> quoteIds = new Set<Id>();
        Set<Id> contractIds = new Set<Id>();
        Set<Id> oppIds = new Set<Id>();
        
        for (Order orderRecord : newOrders) {
            if (orderRecord.QuoteId != null) quoteIds.add(orderRecord.QuoteId);
            else if (orderRecord.ContractId != null) contractIds.add(orderRecord.ContractId);
            else if (orderRecord.OpportunityId != null) oppIds.add(orderRecord.OpportunityId);
        }
        
        Map<Id, Quote> quotesById = new Map<Id, Quote>([
            SELECT Id, BillingStreet, CurrencyIsoCode, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                   ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry,
                   OpportunityId
            FROM Quote
            WHERE Id IN :quoteIds
        ]);
        
        Map<Id, Contract> contractsById = new Map<Id, Contract>([
            SELECT Id, BillingStreet,CurrencyIsoCode, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                   ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry,
                   SourceQuoteId, SourceOpportunityId
            FROM Contract
            WHERE Id IN :contractIds
        ]);
        
        Map<Id, Opportunity> opportunitiesById = new Map<Id, Opportunity>([
            SELECT Id, AccountId, RecordType.DeveloperName, Account.BillingStreet, Account.BillingCity, Account.BillingState,
                   Account.BillingPostalCode, Account.BillingCountry
            FROM Opportunity
            WHERE Id IN :oppIds
        ]);
        
        Map<Id, Opportunity_Site__c> primarySitesByOppId = new Map<Id, Opportunity_Site__c>();
        
        for (Opportunity_Site__c site : [
            SELECT Id, Opportunity__c, Site__r.ShippingStreet, Site__r.ShippingCity,
                   Site__r.ShippingState, Site__r.ShippingPostalCode, Site__r.ShippingCountry
            FROM Opportunity_Site__c
            WHERE Opportunity__c IN :oppIds
            AND Primary__c = TRUE
        ]) {
            primarySitesByOppId.put(site.Opportunity__c, site);
        }
        
        for (Order orderRecord : newOrders) {
            if (orderRecord.QuoteId != null && quotesById.containsKey(orderRecord.QuoteId)) {
                Quote source = quotesById.get(orderRecord.QuoteId);
                
                orderRecord.CurrencyIsoCode = source.CurrencyIsoCode;
                orderRecord.BillingStreet = source.BillingStreet;
                orderRecord.BillingCity = source.BillingCity;
                orderRecord.BillingState = source.BillingState;
                orderRecord.BillingPostalCode = source.BillingPostalCode;
                orderRecord.BillingCountry = source.BillingCountry;
                orderRecord.ShippingStreet = source.ShippingStreet;
                orderRecord.ShippingCity = source.ShippingCity;
                orderRecord.ShippingState = source.ShippingState;
                orderRecord.ShippingPostalCode = source.ShippingPostalCode;
                orderRecord.ShippingCountry = source.ShippingCountry;
                orderRecord.OpportunityId = source.OpportunityId;
                
            } else if (orderRecord.ContractId != null && contractsById.containsKey(orderRecord.ContractId)) {
                Contract source = contractsById.get(orderRecord.ContractId);
                
                orderRecord.CurrencyIsoCode = source.CurrencyIsoCode;
                orderRecord.BillingStreet = source.BillingStreet;
                orderRecord.BillingCity = source.BillingCity;
                orderRecord.BillingState = source.BillingState;
                orderRecord.BillingPostalCode = source.BillingPostalCode;
                orderRecord.BillingCountry = source.BillingCountry;
                orderRecord.ShippingStreet = source.ShippingStreet;
                orderRecord.ShippingCity = source.ShippingCity;
                orderRecord.ShippingState = source.ShippingState;
                orderRecord.ShippingPostalCode = source.ShippingPostalCode;
                orderRecord.ShippingCountry = source.ShippingCountry;

                orderRecord.QuoteId = source.SourceQuoteId;
                orderRecord.OpportunityId = source.SourceOpportunityId;
                
            } else if (orderRecord.OpportunityId != null && opportunitiesById.containsKey(orderRecord.OpportunityId)) {
                Opportunity opp = opportunitiesById.get(orderRecord.OpportunityId);
                Opportunity_Site__c site = primarySitesByOppId.get(orderRecord.OpportunityId);
                
                
                if (site == null) {
                    orderRecord.addError('A Primary Site needs to be added to the Opportunity for creating Order.');
                    continue;
                }

                if (opp.RecordType.DeveloperName == 'BAU' && String.isBlank(opp.Account.BillingStreet) && String.isBlank(opp.Account.BillingCity) &&
                    String.isBlank(opp.Account.BillingState) && String.isBlank(opp.Account.BillingPostalCode) && String.isBlank(opp.Account.BillingCountry)) {
                        orderRecord.addError('Please add Billing Address to the Entity before creating an Order.');
                        continue;
                    }

                if (opp.RecordType.DeveloperName == 'BAU' && String.isBlank(site.Site__r.ShippingStreet) && String.isBlank(site.Site__r.ShippingCity) && String.isBlank(site.Site__r.ShippingState) &&
                    String.isBlank(site.Site__r.ShippingPostalCode) && String.isBlank(site.Site__r.ShippingCountry)) {
                        orderRecord.addError('Please add Shipping Address to the Primary Site before creating an Order.');
                        continue;
                    }
                
                orderRecord.BillingStreet = opp.Account.BillingStreet;
                orderRecord.BillingCity = opp.Account.BillingCity;
                orderRecord.BillingState = opp.Account.BillingState;
                orderRecord.BillingPostalCode = opp.Account.BillingPostalCode;
                orderRecord.BillingCountry = opp.Account.BillingCountry;
                orderRecord.ShippingStreet = site.Site__r.ShippingStreet;
                orderRecord.ShippingCity = site.Site__r.ShippingCity;
                orderRecord.ShippingState = site.Site__r.ShippingState;
                orderRecord.ShippingPostalCode = site.Site__r.ShippingPostalCode;
                orderRecord.ShippingCountry = site.Site__r.ShippingCountry;
            }
        }
    }

    public static void syncCustomerPriceGroup(List<Order> newOrders) {
        Set<Id> accountIds = new Set<Id>();

        for (Order orderRecord : newOrders) {
            if (orderRecord.AccountId != null) {
                accountIds.add(orderRecord.AccountId);
            }
        }
        if (accountIds.isEmpty()) return;

        Map<Id, Account> accountsById = new Map<Id, Account>([ SELECT Id, Customer_Price_Group_CC__c FROM Account WHERE Id IN :accountIds WITH SYSTEM_MODE]);
        for (Order orderRecord : newOrders) {
            Account accountRecord = accountsById.get(orderRecord.AccountId);
            if (accountRecord != null) {
                orderRecord.Customer_Price_Group_CC__c = accountRecord.Customer_Price_Group_CC__c;
            }
        }
    }
    
    public static void updateShippingHandling(List<Order> newOrders) {
        Map<Id, Decimal> orderShippingAmountMap = new Map<Id, Decimal>();
        
        for (Order ord : [
            SELECT Id, QuoteId, Quote.ShippingHandling, ContractId,
                   Contract.SourceQuoteId, Contract.SourceQuote.ShippingHandling
            FROM Order
            WHERE Id IN :newOrders
        ]) {
            if (ord.QuoteId != null && ord.Quote.ShippingHandling != null) {
                orderShippingAmountMap.put(ord.Id, ord.Quote.ShippingHandling);
            } else if (ord.ContractId != null &&
                       ord.Contract.SourceQuoteId != null &&
                       ord.Contract.SourceQuote.ShippingHandling != null) {
                orderShippingAmountMap.put(ord.Id, ord.Contract.SourceQuote.ShippingHandling);
            }
        }
        
        List<Order> ordersToUpdate = new List<Order>();
        
        for (Order ord : newOrders) {
            Order updatedOrd = new Order();
            updatedOrd.Id = ord.Id;
            updatedOrd.Shipping_and_Handling__c = orderShippingAmountMap.get(ord.Id);
            ordersToUpdate.add(updatedOrd);
        }
        
        if (!ordersToUpdate.isEmpty()) Database.update(ordersToUpdate);
    }
    
    public static void validateQuoteSource(List<Order> newOrders) {
        Set<Id> quoteIds = new Set<Id>();
        
        for (Order orderRecord : newOrders) {
            if (orderRecord.QuoteId != null) quoteIds.add(orderRecord.QuoteId);
        }
        
        if (quoteIds.isEmpty()) return;
        
        Set<Id> quoteIdsWithContracts = new Set<Id>();
        
        for (Contract contractRecord : [
            SELECT Id, SourceQuoteId
            FROM Contract
            WHERE SourceQuoteId IN :quoteIds
        ]) {
            quoteIdsWithContracts.add(contractRecord.SourceQuoteId);
        }
        
        for (Order orderRecord : newOrders) {
            if (orderRecord.QuoteId != null && quoteIdsWithContracts.contains(orderRecord.QuoteId)) {
                orderRecord.addError('A Contract already exists for this Quote.');
            }
        }
    }

    public static void validateActivatedOrderUpdate(List<Order> newOrders, Map<Id, Order> oldOrders) {

        List<Profile> currentProfile = [SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() LIMIT 1];
        if (!currentProfile.isEmpty() && currentProfile[0].Name == 'System Administrator') return;

        Set<String> allowedFields = new Set<String>();
        String allowedLabel = System.Label.Accepted_Order_Allowed_Fields_CC;

        if (String.isNotBlank(allowedLabel)) {
            for (String fieldName : allowedLabel.split(',')) {
                if (String.isNotBlank(fieldName)) {
                    allowedFields.add(fieldName.trim().toLowerCase());
                }
            }
        }

        Map<String, Schema.SObjectField> orderFields = Schema.SObjectType.Order.fields.getMap();
        List<String> fieldsToValidate = new List<String>();

        for (String fieldName : orderFields.keySet()) {
            if (allowedFields.contains(fieldName.toLowerCase())) continue;

            Schema.DescribeFieldResult fieldDescribe = orderFields.get(fieldName).getDescribe();

            if (!fieldDescribe.isUpdateable() || fieldDescribe.isCalculated()) continue;

            fieldsToValidate.add(fieldName);
        }

        for (Order newOrder : newOrders) {
            Order oldOrder = oldOrders.get(newOrder.Id);

            if (oldOrder == null || oldOrder.Status != 'Activated') continue;

            for (String fieldName : fieldsToValidate) {
                Object oldValue = oldOrder.get(fieldName);
                Object newValue = newOrder.get(fieldName);
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
                    newOrder.addError('Commercial Changes are not allowed on Activated Order.');
                    break;
                }
            }
        }
    }

    public static void preventMultipleActivatedOrders(List<Order> newOrders, Map<Id, Order> oldOrders) {
        Set<Id> quoteIds = new Set<Id>();
        Set<Id> activatingOrderIds = new Set<Id>();

        for (Order newOrder : newOrders) {
            Order oldOrder = oldOrders.get(newOrder.Id);

            if (newOrder.QuoteId != null && newOrder.Status == 'Activated' && oldOrder.Status != 'Activated') {
                quoteIds.add(newOrder.QuoteId);
                activatingOrderIds.add(newOrder.Id);
            }
        }

        if (quoteIds.isEmpty()) return;

        Map<Id, Id> activatedQuoteByOrder = new Map<Id, Id>();

        for (Order orderRecord : [ SELECT Id, QuoteId FROM Order WHERE QuoteId IN :quoteIds AND Status = 'Activated' AND Id NOT IN :activatingOrderIds]) {
            activatedQuoteByOrder.put(orderRecord.Id, orderRecord.QuoteId);
        }

        Set<Id> alreadyActivatedQuoteIds = new Set<Id>(activatedQuoteByOrder.values());

        for (Order newOrder : newOrders) {
            Order oldOrder = oldOrders.get(newOrder.Id);

            if (newOrder.QuoteId == null || newOrder.Status != 'Activated' || oldOrder.Status == 'Activated') {
                continue;
            }
            if (alreadyActivatedQuoteIds.contains(newOrder.QuoteId)) {
                newOrder.addError('Another Order for the same Quote is already Activated.');
            }
        }

        Map<Id, Integer> quoteActivationCount = new Map<Id, Integer>();

        for (Order newOrder : newOrders) {
            Order oldOrder = oldOrders.get(newOrder.Id);

            if (newOrder.QuoteId != null && newOrder.Status == 'Activated' && oldOrder.Status != 'Activated') {
                Integer count = quoteActivationCount.containsKey(newOrder.QuoteId) ? quoteActivationCount.get(newOrder.QuoteId) : 0;
                quoteActivationCount.put(newOrder.QuoteId, count + 1);
            }
        }

        for (Order newOrder : newOrders) {
            Order oldOrder = oldOrders.get(newOrder.Id);

            if (newOrder.QuoteId != null && newOrder.Status == 'Activated' && oldOrder.Status != 'Activated' && quoteActivationCount.get(newOrder.QuoteId) > 1) {
                newOrder.addError('Only one Order related to the same Quote can be Activated.');
            }
        }
    }

    public static void recalculateBAUOpportunityAmounts(List<Order> newOrders, List<Order> oldOrders) {
        Set<Id> opportunityIds = new Set<Id>();

        if (newOrders != null) {
            for (Order orderRecord : newOrders) {
                if (orderRecord.OpportunityId != null) opportunityIds.add(orderRecord.OpportunityId);
            }
        }

        if (oldOrders != null) {
            for (Order orderRecord : oldOrders) {
                if (orderRecord.OpportunityId != null) opportunityIds.add(orderRecord.OpportunityId);
            }
        }

        if (opportunityIds.isEmpty()) return;

        Map<Id, Opportunity> bauOpportunities = new Map<Id, Opportunity>([ SELECT Id, BAU_Amount_Without_Freight_CC__c, BAU_Amount_With_Freight_CC__c FROM Opportunity WHERE Id IN :opportunityIds AND RecordType.DeveloperName = 'BAU' WITH SYSTEM_MODE]);

        if (bauOpportunities.isEmpty()) return;

        Set<Id> bauOpportunityIds = bauOpportunities.keySet();
        Map<Id, Decimal> amountWithoutFreight = new Map<Id, Decimal>();
        Map<Id, Decimal> amountWithFreight = new Map<Id, Decimal>();

        for (Id opportunityId : bauOpportunityIds) {
            amountWithoutFreight.put(opportunityId, 0);
            amountWithFreight.put(opportunityId, 0);
        }

        for (AggregateResult result : [SELECT OpportunityId opportunityId, SUM(TotalAmount) totalWithoutFreight, SUM(Grand_Total__c) totalWithFreight FROM Order
                                        WHERE OpportunityId IN :bauOpportunityIds WITH SYSTEM_MODE GROUP BY OpportunityId]) {
            Id opportunityId = (Id)result.get('opportunityId');
            amountWithoutFreight.put(opportunityId, result.get('totalWithoutFreight') == null ? 0 : (Decimal)result.get('totalWithoutFreight'));
            amountWithFreight.put(opportunityId, result.get('totalWithFreight') == null ? 0 : (Decimal)result.get('totalWithFreight'));
        }

        List<Opportunity> opportunitiesToUpdate = new List<Opportunity>();

        for (Opportunity opportunityRecord : bauOpportunities.values()) {
            Decimal totalWithoutFreight = amountWithoutFreight.get(opportunityRecord.Id);
            Decimal totalWithFreight = amountWithFreight.get(opportunityRecord.Id);

            if (opportunityRecord.BAU_Amount_Without_Freight_CC__c != totalWithoutFreight ||  opportunityRecord.BAU_Amount_With_Freight_CC__c != totalWithFreight) {
                opportunitiesToUpdate.add(new Opportunity( Id = opportunityRecord.Id, BAU_Amount_Without_Freight_CC__c = totalWithoutFreight,  BAU_Amount_With_Freight_CC__c = totalWithFreight));
            }
        }

        if (!opportunitiesToUpdate.isEmpty()) {
            Database.update(opportunitiesToUpdate, AccessLevel.SYSTEM_MODE);
        }
    }

    public void syncCustomerNumberLookups() {
        List<Order> orders = (List<Order>)Trigger.new;
        Set<Id> opportunityIds = new Set<Id>();

        for (Order ord : orders) {
            if (ord.OpportunityId != null) {
                opportunityIds.add(ord.OpportunityId);
            }
        }

        Map<Id, Opportunity> opportunitiesById = new Map<Id, Opportunity>();

        if (!opportunityIds.isEmpty()) {
            opportunitiesById = new Map<Id, Opportunity>([SELECT Id, Ship_To_Site_CC__c FROM Opportunity WHERE Id IN :opportunityIds]);
        }

        for (Order ord : orders) {
            ord.Bill_to_Customer_No_CC__c = ord.AccountId;
            ord.Sell_to_Customer_No_CC__c = ord.AccountId;

            Opportunity opp = opportunitiesById.get(ord.OpportunityId);
            ord.Ship_to_Customer_No_CC__c = opp == null ? null : opp.Ship_To_Site_CC__c;
        }
    }

}