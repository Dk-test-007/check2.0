public without sharing class ContractTriggerHandler_CC extends BaseTriggerHandler_CC {
    
    public void run() {
        super.run(this, 'Contract');
    }
    
    public override void beforeInsert() {
        validateQuoteSource((List<Contract>) Trigger.new);
        syncAddressAndContractDetails((List<Contract>) Trigger.new);
    }
    
    public override void afterInsert() {
        createSalesContractLines((List<Contract>)Trigger.new);
    }

    public static void createSalesContractLines(List<Contract> newContracts) {
        Set<Id> quoteIds = new Set<Id>();
        Set<Id> contractIds = new Set<Id>();
        
        for (Contract contractRecord : newContracts) {
            if (contractRecord.SourceQuoteId != null) {
                quoteIds.add(contractRecord.SourceQuoteId);
                contractIds.add(contractRecord.Id);
            }
        }
        
        if (quoteIds.isEmpty()) return;
        
        Map<Id, Quote> quotesById = new Map<Id, Quote>([SELECT Id, Pricebook2Id FROM Quote WHERE Id IN :quoteIds WITH SYSTEM_MODE]);
        List<Contract> contractsToUpdate = new List<Contract>();
        
        for (Contract contractRecord : newContracts) {
            Quote quoteRecord = quotesById.get(contractRecord.SourceQuoteId);
            if (quoteRecord != null && quoteRecord.Pricebook2Id != null && contractRecord.Pricebook2Id == null) {
                contractsToUpdate.add(new Contract(Id = contractRecord.Id, Pricebook2Id = quoteRecord.Pricebook2Id));
            }
        }
        
        if (!contractsToUpdate.isEmpty()) update contractsToUpdate;
        
        List<QuoteLineItem> quoteLineItems = [SELECT Id, QuoteId, Product2Id, Product2.Name, Quantity, UnitPrice, TotalPrice, Description FROM QuoteLineItem WHERE QuoteId IN :quoteIds WITH SYSTEM_MODE];
        
        if (quoteLineItems.isEmpty()) return;
        
        Map<Id, List<QuoteLineItem>> quoteToLineItems = new Map<Id, List<QuoteLineItem>>();
        Set<Id> quoteLineItemIds = new Set<Id>();
        
        for (QuoteLineItem quoteLineItem : quoteLineItems) {
            quoteLineItemIds.add(quoteLineItem.Id);
            if (!quoteToLineItems.containsKey(quoteLineItem.QuoteId)) {
                quoteToLineItems.put(quoteLineItem.QuoteId, new List<QuoteLineItem>());
            }
            quoteToLineItems.get(quoteLineItem.QuoteId).add(quoteLineItem);
        }
        
        Set<String> existingLineKeys = new Set<String>();
        
        for (SalesContractLine existingLine : [SELECT ContractId, QuoteLineItemId FROM SalesContractLine WHERE ContractId IN :contractIds AND QuoteLineItemId IN :quoteLineItemIds WITH SYSTEM_MODE]) {
            existingLineKeys.add(existingLine.ContractId + '-' + existingLine.QuoteLineItemId);
        }
        
        List<SalesContractLine> linesToInsert = new List<SalesContractLine>();
        
        for (Contract contractRecord : newContracts) {
            if (contractRecord.SourceQuoteId == null) continue;
            
            List<QuoteLineItem> sourceLineItems = quoteToLineItems.get(contractRecord.SourceQuoteId);
            if (sourceLineItems == null) continue;
            
            for (QuoteLineItem sourceLineItem : sourceLineItems) {
                String lineKey = contractRecord.Id + '-' + sourceLineItem.Id;
                if (existingLineKeys.contains(lineKey)) continue;
                
                String lineName = sourceLineItem.Product2 != null ? sourceLineItem.Product2.Name : 'Contract Line';
                lineName = lineName.length() > 80 ? lineName.substring(0, 80) : lineName;
                
                linesToInsert.add(new SalesContractLine(
                    ContractId = contractRecord.Id,
                    QuoteLineItemId = sourceLineItem.Id,
                    Product2Id = sourceLineItem.Product2Id,
                    Quantity = sourceLineItem.Quantity,
                    UnitPrice = sourceLineItem.UnitPrice,
                    TotalPrice = sourceLineItem.TotalPrice,
                    Description = sourceLineItem.Description,
                    Remaining_SKU_CC__c = sourceLineItem.Quantity,
                    Name = lineName
                ));
            }
        }
        
        if (!linesToInsert.isEmpty()) {
            Database.insert(linesToInsert, AccessLevel.SYSTEM_MODE);
        }
    }
    
    public static void syncAddressAndContractDetails(List<Contract> newContracts) {
        Set<Id> quoteIds = new Set<Id>();
        
        for (Contract contractRecord : newContracts) {
            if (contractRecord.SourceQuoteId != null) quoteIds.add(contractRecord.SourceQuoteId);
        }
        
        if (quoteIds.isEmpty()) return;
        
        Map<Id, Quote> quotesById = new Map<Id, Quote>([ SELECT Id, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry, ShippingStreet, ShippingCity, ShippingState,
                                                         ShippingPostalCode, ShippingCountry , OpportunityId , AccountId
                                                        FROM Quote WHERE Id IN :quoteIds]);
        
        for (Contract contractRecord : newContracts) {
            Quote quoteRecord = quotesById.get(contractRecord.SourceQuoteId);
            if (quoteRecord == null) {
                contractRecord.addError('A valid Source Quote is required for creating Contract.');
                continue;
            }
            
            contractRecord.BillingStreet = quoteRecord.BillingStreet;
            contractRecord.BillingCity = quoteRecord.BillingCity;
            contractRecord.BillingState = quoteRecord.BillingState;
            contractRecord.BillingPostalCode = quoteRecord.BillingPostalCode;
            contractRecord.BillingCountry = quoteRecord.BillingCountry;
            contractRecord.ShippingStreet = quoteRecord.ShippingStreet;
            contractRecord.ShippingCity = quoteRecord.ShippingCity;
            contractRecord.ShippingState = quoteRecord.ShippingState;
            contractRecord.ShippingPostalCode = quoteRecord.ShippingPostalCode;
            contractRecord.ShippingCountry = quoteRecord.ShippingCountry;
            contractRecord.SourceOpportunityId = quoteRecord.OpportunityId;
            contractRecord.AccountId = quoteRecord.AccountId;
        }
    }

    public static void validateQuoteSource(List<Contract> newContracts) {
        Set<Id> quoteIds = new Set<Id>();

        for (Contract contractRecord : newContracts) {
            if (contractRecord.SourceQuoteId != null) quoteIds.add(contractRecord.SourceQuoteId);
        }

        if (quoteIds.isEmpty()) return;
        Set<Id> quoteIdsWithOrders = new Set<Id>();

        for (Order orderRecord : [SELECT Id, QuoteId FROM Order WHERE QuoteId IN :quoteIds]) {
            quoteIdsWithOrders.add(orderRecord.QuoteId);
        }
        for (Contract contractRecord : newContracts) {
            if (contractRecord.SourceQuoteId != null && quoteIdsWithOrders.contains(contractRecord.SourceQuoteId)) {
                contractRecord.addError('An Order already exists for this Quote.');
            }
        }
    }   
}