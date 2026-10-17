/**
 * =============================================================================
 * Class Name    : QuoteTriggerHandler_CC
 * Description   : Trigger handler for Quote object
 *
 * Author        : Nipun Jain
 * Created Date  : Sept 2026
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Central trigger handler for Quote object.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public class QuoteTriggerHandler_CC extends BaseTriggerHandler_CC {
    
    private static Boolean isUpdatingLatestQuotes = false;
    
    public void run() {
        super.run(this, 'Quote');
    }
    
    public override void beforeUpdate() {
        //lockGeneratedQuotes((List<Quote>)Trigger.new, (Map<Id, Quote>)Trigger.oldMap);
        checkForQuoteStatusesAndActivation((List<Quote>)Trigger.new, (Map<Id, Quote>)Trigger.oldMap);
    }
    
    public override void beforeInsert() {
        updateAddress((List<Quote>) Trigger.new);
    }
    
    public override void afterInsert() {
        markQuoteActive((Map<Id, Quote>) Trigger.newMap);
    }
    
    public static void updateAddress(List<Quote> newQuotes) {
        Set<Id> oppIds = new Set<Id>();
        Set<Id> accIds = new Set<Id>();
        for(Quote qt: newQuotes) {
            oppIds.add(qt.OpportunityId);
            accIds.add(qt.AccountId);
        }
        
        Map<Id, Opportunity_Site__c> oppToSiteMap = new Map<Id, Opportunity_Site__c>();
        for(Opportunity_Site__c site : [SELECT Id, Opportunity__c,Opportunity__r.RecordType.DeveloperName, Opportunity__r.Account.BillingStreet, Opportunity__r.Account.BillingCity, Opportunity__r.Account.BillingState, Opportunity__r.Account.BillingPostalCode, Opportunity__r.Account.BillingCountry, Site__c, Site__r.Name, Site__r.ShippingStreet, Site__r.ShippingCity, Site__r.ShippingState, Site__r.ShippingPostalCode, Site__r.ShippingCountry FROM Opportunity_Site__c WHERE Opportunity__c IN: oppIds AND Primary__c = TRUE WITH SYSTEM_MODE]) {
            oppToSiteMap.put(site.Opportunity__c, site);
        }
        
        Map<Id, Account> accMap = new Map<Id, Account>([SELECT Id, Entity_CC__c FROM Account WHERE Id IN: accIds]);
        
        Map<Id, Integer> oppToAcceptedQuoteCount = new Map<Id, Integer>();
        for(AggregateResult res: [SELECT OpportunityId, COUNT(Id) acceptedQuotes FROM Quote WHERE OpportunityId IN: oppIds AND Status = 'Accepted' GROUP BY OpportunityId ]) {
            oppToAcceptedQuoteCount.put((Id)res.get('OpportunityId'), (Integer)res.get('acceptedQuotes'));
        }

        for(Quote qt: newQuotes) {
            Opportunity_Site__c site = oppToSiteMap.get(qt.OpportunityId);

            if(site != NULL && site.Opportunity__r.RecordType.DeveloperName == 'New_Business' && oppToAcceptedQuoteCount.containsKey(qt.OpportunityId) && oppToAcceptedQuoteCount.get(qt.OpportunityId) > 0) {
                qt.addError('An Accepted Quote already exists for this Opportunity');
            }else if(!oppToSiteMap.containsKey(qt.OpportunityId)) {
                qt.addError('A Primary Site needs to be added to the Opportunity for creating Quote');
            } else if(site.Opportunity__r.Account.BillingStreet == NULL && site.Opportunity__r.Account.BillingCity == NULL && site.Opportunity__r.Account.BillingState == NULL && site.Opportunity__r.Account.BillingPostalCode == NULL && site.Opportunity__r.Account.BillingCountry == NULL) {
                qt.addError('Please add Billing Address to the Entity before creating a Quote');
            } else if(site.Site__r.ShippingStreet == NULL && site.Site__r.ShippingCity == NULL && site.Site__r.ShippingState == NULL && site.Site__r.ShippingPostalCode == NULL && site.Site__r.ShippingCountry == NULL){
                qt.addError('Please add Shipping Address to the Primary Site before creating a Quote');
            } else  {
                qt.BillingStreet = site.Opportunity__r.Account.BillingStreet != null ? site.Opportunity__r.Account.BillingStreet : null;
                qt.BillingCity = site.Opportunity__r.Account.BillingCity != null ? site.Opportunity__r.Account.BillingCity : null;
                qt.BillingState = site.Opportunity__r.Account.BillingState != null ? site.Opportunity__r.Account.BillingState : null;
                qt.BillingPostalCode = site.Opportunity__r.Account.BillingPostalCode != null ? site.Opportunity__r.Account.BillingPostalCode : null;
                qt.BillingCountry = site.Opportunity__r.Account.BillingCountry != null ? site.Opportunity__r.Account.BillingCountry : null;
                
                qt.ShippingName = site.Site__r.Name;
                qt.Ship_to_Site_CC__c = site.Site__c;
                qt.ShippingStreet = site.Site__r.ShippingStreet != null ? site.Site__r.ShippingStreet : null;
                qt.ShippingCity = site.Site__r.ShippingCity != null ? site.Site__r.ShippingCity : null;
                qt.ShippingState = site.Site__r.ShippingState != null ? site.Site__r.ShippingState : null;
                qt.ShippingPostalCode = site.Site__r.ShippingPostalCode != null ? site.Site__r.ShippingPostalCode : null;
                qt.ShippingCountry = site.Site__r.ShippingCountry != null ? site.Site__r.ShippingCountry : null;
            }
            
            qt.Owning_Entity__c = qt.Owning_Entity__c == NULL && accMap.containsKey(qt.AccountId) ? accMap.get(qt.AccountId).Entity_CC__c : qt.Owning_Entity__c;
        }
        
    }
    
    /*public static void lockGeneratedQuotes(List<Quote> newQuotes, Map<Id, Quote> oldQuoteMap) {
        Set<Id> quoteIds = new Set<Id>();
        for (Quote quoteRecord : newQuotes) {
            if(quoteRecord.Latest_Quote__c == oldQuoteMap.get(quoteRecord.Id).Latest_Quote__c) {
            	quoteIds.add(quoteRecord.Id);
            }
        }
        
        Set<Id> lockedQuoteIds = new Set<Id>();
        
        List<Order> orders = [SELECT QuoteId FROM Order WHERE QuoteId IN :quoteIds];
        for (Order orderRecord : orders) {
            lockedQuoteIds.add(orderRecord.QuoteId);
        }
        for (Quote quoteRecord : newQuotes) {
            if (lockedQuoteIds.contains(quoteRecord.Id)) {
                quoteRecord.addError('This Quote cannot be updated as an Order has already been generated from it.');
            }
        }
    }*/
    
    public static void checkForQuoteStatusesAndActivation(List<Quote> newQuotes, Map<Id, Quote> oldQuoteMap) {
        Set<Id> oppIds = new Set<Id>();

        for(Quote qt: newQuotes) {
            if(!isUpdatingLatestQuotes && qt.Latest_Quote__c && !oldQuoteMap.get(qt.Id).Latest_Quote__c && qt.OpportunityId != null) {
                oppIds.add(qt.OpportunityId);
            }

            if(qt.Status != oldQuoteMap.get(qt.Id).Status) {
                if(qt.Status == 'Presented') {
                    qt.StartDate = System.today();
                    qt.Validity_Period_Days__c = qt.Validity_Period_Days__c == NULL ? 30 : qt.Validity_Period_Days__c;
                }else if(qt.Status == 'Accepted') {
                    qt.Quote_Accepted_Date__c = System.today();
                }else if(qt.Status == 'Cancelled') {
                    qt.Cancelled_Date__c = System.today();
                }
            }
            if(qt.StartDate != oldQuoteMap.get(qt.Id).StartDate || qt.Validity_Period_Days__c != oldQuoteMap.get(qt.Id).Validity_Period_Days__c) {
                qt.ExpirationDate = qt.StartDate.addDays((Integer)qt.Validity_Period_Days__c);
            } 
        }
        
        if(!oppIds.isEmpty() && !isUpdatingLatestQuotes) {
            for(Quote qt: [SELECT Id, OpportunityId FROM Quote WHERE OpportunityId IN: oppIds AND Latest_Quote__c = true]) {
                for(Quote newQuote: newQuotes) {
                    if(newQuote.OpportunityId == qt.OpportunityId && newQuote.Id != qt.Id && newQuote.Latest_Quote__c) {
                        newQuote.addError('A Latest Quote already exists for this Opportunity.');
                    }
                }
            }
        }

    }
    
    public static void markQuoteActive(Map<Id, Quote> newQuotesMap) {
        List<Quote> quotesToUpdate = new List<Quote>();
        Set<Id> oppIds = new Set<Id>();
        
        for(Quote qt: newQuotesMap.values()) {
            oppIds.add(qt.OpportunityId);
        }
        
        for(Quote qt: [SELECT Id, Latest_Quote__c  FROM Quote WHERE OpportunityId IN: oppIds]) {
            if(newQuotesMap.containsKey(qt.Id) && !qt.Latest_Quote__c) {
                qt.Latest_Quote__c = TRUE;
                quotesToUpdate.add(qt);
            } else if(!newQuotesMap.containsKey(qt.Id) && qt.Latest_Quote__c) {
                qt.Latest_Quote__c = FALSE;
                quotesToUpdate.add(qt);
            }
        }
        
        if(!quotesToUpdate.isEmpty()) {
            isUpdatingLatestQuotes = TRUE;
            Database.update(quotesToUpdate, AccessLevel.SYSTEM_MODE);
            isUpdatingLatestQuotes = FALSE;
        }
    }
    
}