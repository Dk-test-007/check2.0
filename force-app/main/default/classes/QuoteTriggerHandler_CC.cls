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
        defaultPhoneEmail((List<Quote>)Trigger.new, (Map<Id, Quote>)Trigger.oldMap);
    }
    
    public override void beforeInsert() {
        updateAddress((List<Quote>) Trigger.new);
        defaultPhoneEmail((List<Quote>) Trigger.new, NULL);
    }
    
    public override void afterInsert() {
        markQuoteActive((Map<Id, Quote>) Trigger.newMap);
        syncSitesOnQuote((List<Quote>) Trigger.new);
    }
    
    public override void afterUpdate() {
        List<Guidance_Refresh_CC__e> guidanceEvents = new List<Guidance_Refresh_CC__e>();
        for(Quote acc: (List<Quote>)Trigger.new) {
            guidanceEvents.add(new Guidance_Refresh_CC__e(
                Record_Id_CC__c = String.valueOf(acc.Id),
                Object_API_Name_CC__c = 'Quote'
            ));
        }
        
        if (!guidanceEvents.isEmpty()) {
            EventBus.publish(guidanceEvents);
        }

    }
    
    public static void defaultPhoneEmail(List<Quote> newQuotes, Map<Id, Quote> oldQuoteMap) {
        Set<Id> contactIds = new Set<Id>();
        for(Quote qt: newQuotes) {
            if(qt.ContactId != NULL && (oldQuoteMap == NULL || qt.ContactId != oldQuoteMap.get(qt.Id).ContactId)) {
                contactIds.add(qt.ContactId);
            }
        }
        
        if(!contactIds.isEmpty()) {
        	Map<Id, Contact> contactMap = new Map<Id, Contact>([SELECT Id, Phone, Email FROM Contact WHERE Id IN: contactIds]);
            for(Quote qt: newQuotes) {
                if(contactMap.containsKey(qt.ContactId)) {
                    qt.Phone = contactMap.get(qt.ContactId).Phone;
                    qt.Email = contactMap.get(qt.ContactId).Email;
                }
            }
        }
    } 
    
    public static void updateAddress(List<Quote> newQuotes) {
        Set<Id> oppIds = new Set<Id>();
        Map<Id, Id> quoteToOppIds = new Map<Id, Id>();
        for(Quote qt: newQuotes) {
            oppIds.add(qt.OpportunityId);
            quoteToOppIds.put(qt.Id, qt.OpportunityId);
        }
        Map<Id, Opportunity> parentOppMap = new Map<Id, Opportunity>([SELECT Id, Account.BillingStreet, Account.BillingCity, Account.BillingState, Account.BillingPostalCode, Account.BillingCountry FROM Opportunity WHERE Id IN: oppIds]);
        
        Map<Id, Opportunity_Site__c> oppToSiteMap = new Map<Id, Opportunity_Site__c>();
        for(Opportunity_Site__c site : [SELECT Id, Opportunity__c,Opportunity__r.RecordType.DeveloperName, Opportunity__r.Account.BillingStreet, Opportunity__r.Account.BillingCity, Opportunity__r.Account.BillingState, Opportunity__r.Account.BillingPostalCode, Opportunity__r.Account.BillingCountry, Site__c, Site__r.Name, Site__r.ShippingStreet, Site__r.ShippingCity, Site__r.ShippingState, Site__r.ShippingPostalCode, Site__r.ShippingCountry FROM Opportunity_Site__c WHERE Opportunity__c IN: oppIds AND Primary__c = TRUE WITH SYSTEM_MODE]) {
            oppToSiteMap.put(site.Opportunity__c, site);
        }
        
        Map<Id, Integer> oppToAcceptedQuoteCount = new Map<Id, Integer>();
        for(AggregateResult res: [SELECT OpportunityId, COUNT(Id) acceptedQuotes FROM Quote WHERE OpportunityId IN: oppIds AND Status = 'Accepted' GROUP BY OpportunityId ]) {
            oppToAcceptedQuoteCount.put((Id)res.get('OpportunityId'), (Integer)res.get('acceptedQuotes'));
        }

        for(Quote qt: newQuotes) {
            Opportunity_Site__c site = oppToSiteMap.get(qt.OpportunityId);

            if(site != NULL && site.Opportunity__r.RecordType.DeveloperName == 'New_Business' && oppToAcceptedQuoteCount.containsKey(qt.OpportunityId) && oppToAcceptedQuoteCount.get(qt.OpportunityId) > 0) {
                qt.addError('An Accepted Quote already exists for this Opportunity');
            }/*else if(!oppToSiteMap.containsKey(qt.OpportunityId)) {
                qt.addError('A Primary Site needs to be added to the Opportunity for creating Quote');
            } else if(site.Opportunity__r.Account.BillingStreet == NULL || site.Opportunity__r.Account.BillingCity == NULL || site.Opportunity__r.Account.BillingState == NULL || site.Opportunity__r.Account.BillingPostalCode == NULL || site.Opportunity__r.Account.BillingCountry == NULL) {
                qt.addError('Please add the complete Billing Address to the Entity before creating a Quote');
            } else if(site.Site__r.ShippingStreet == NULL || site.Site__r.ShippingCity == NULL || site.Site__r.ShippingState == NULL || site.Site__r.ShippingPostalCode == NULL || site.Site__r.ShippingCountry == NULL){
                qt.addError('Please add the complete Shipping Address to the Primary Site before creating a Quote');
            }*/ else  {
                
                Opportunity parentOpp = parentOppMap.get(qt.OpportunityId);
                qt.BillingStreet = parentOpp.Account.BillingStreet != null ? parentOpp.Account.BillingStreet : null;
                qt.BillingCity = parentOpp.Account.BillingCity != null ? parentOpp.Account.BillingCity : null;
                qt.BillingState = parentOpp.Account.BillingState != null ? parentOpp.Account.BillingState : null;
                qt.BillingPostalCode = parentOpp.Account.BillingPostalCode != null ? parentOpp.Account.BillingPostalCode : null;
                qt.BillingCountry = parentOpp.Account.BillingCountry != null ? parentOpp.Account.BillingCountry : null;
                
                if(site != NULL) {
                    qt.ShippingName = site.Site__r.Name;
                    qt.Ship_to_Site_CC__c = site.Site__c;
                    qt.ShippingStreet = site.Site__r.ShippingStreet != null ? site.Site__r.ShippingStreet : null;
                    qt.ShippingCity = site.Site__r.ShippingCity != null ? site.Site__r.ShippingCity : null;
                    qt.ShippingState = site.Site__r.ShippingState != null ? site.Site__r.ShippingState : null;
                    qt.ShippingPostalCode = site.Site__r.ShippingPostalCode != null ? site.Site__r.ShippingPostalCode : null;
                    qt.ShippingCountry = site.Site__r.ShippingCountry != null ? site.Site__r.ShippingCountry : null;
                } else  {
                    qt.ShippingName = NULL;
                    qt.ShippingStreet = NULL;
                    qt.ShippingCity = NULL;
                    qt.ShippingState = NULL;
                    qt.ShippingPostalCode = NULL;
                    qt.ShippingCountry = NULL;
                    qt.ShippingCountryCode = NULL;
                    qt.ShippingStateCode = NULL;
                }
            }
        }
        
    }
    
    public static void checkForQuoteStatusesAndActivation(List<Quote> newQuotes, Map<Id, Quote> oldQuoteMap) {
        Set<Id> oppIds = new Set<Id>();
        /*Set<Id> quotesWithSites = new Set<Id>();
        for(AggregateResult res: [SELECT Quote_CC__c, COUNT(Id) countOfSites FROM Opportunity_Site__c WHERE Quote_CC__c IN: newQuotes GROUP BY Quote_CC__c]) {
            quotesWithSites.add((String)res.get('Quote_CC__c'));
        }*/

        for(Quote qt: newQuotes) {
            if(!isUpdatingLatestQuotes && qt.Latest_Quote__c && !oldQuoteMap.get(qt.Id).Latest_Quote__c && qt.OpportunityId != null) {
                oppIds.add(qt.OpportunityId);
            }

            if(qt.Status != oldQuoteMap.get(qt.Id).Status) {
                /*if(oldQuoteMap.get(qt.Id).Status == 'Draft' && !quotesWithSites.contains(qt.Id)) {
                    qt.addError('Please add a Site from the "Select Sites" action before progressing the Quote');
                }*/
                if(qt.Status == 'Presented') {
                    qt.StartDate = System.today();
                    qt.Validity_Period_Days__c = qt.Validity_Period_Days__c == NULL ? 30 : qt.Validity_Period_Days__c;
                }else if(qt.Status == 'Accepted') {
                    qt.Quote_Accepted_Date__c = System.today();
                }else if(qt.Status == 'Cancelled') {
                    qt.Cancelled_Date__c = System.today();
                }
            }
            if((qt.StartDate != oldQuoteMap.get(qt.Id).StartDate || qt.Validity_Period_Days__c != oldQuoteMap.get(qt.Id).Validity_Period_Days__c) && qt.Validity_Period_Days__c != null && qt.StartDate != null) {
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
    
    public static void syncSitesOnQuote(List<Quote> newQuotes) {
        Map<Id, Set<Id>> oppToQuoteIds = new Map<Id, Set<Id>>();
        List<Opportunity_Site__c> newSites = new List<Opportunity_Site__c>();
        List<Quote> quotes = new List<Quote>();
        
        for(Quote qt: newQuotes) {
            if(oppToQuoteIds.containsKey(qt.OpportunityId)) {
                oppToQuoteIds.get(qt.OpportunityId).add(qt.Id);
            } else {
                oppToQuoteIds.put(qt.OpportunityId, new Set<Id>{qt.Id});
            }
        }
        
        for(Opportunity_Site__c site: [SELECT Id, Opportunity__c, Site__c, Site__r.Name, Site__r.ShippingStreet, Site__r.ShippingCity, Site__r.ShippingState, Site__r.ShippingPostalCode, Site__r.ShippingCountry, Primary__c FROM Opportunity_Site__c WHERE Opportunity__c IN: oppToQuoteIds.keySet()]) {
            for(Id quoteId: oppToQuoteIds.get(site.Opportunity__c)) {
                Opportunity_Site__c quoteSite = new Opportunity_Site__c();
                quoteSite.Site__c = site.Site__c;
                quoteSite.Primary__c = site.Primary__c;
                quoteSite.Quote_CC__c = quoteId;
                
                if(site.Primary__c) {
                    Quote qt = new Quote();
                    qt.Id = quoteId;
                    qt.ShippingStreet = site.Site__r.ShippingStreet != null ? site.Site__r.ShippingStreet : null;
                    qt.ShippingCity = site.Site__r.ShippingCity != null ? site.Site__r.ShippingCity : null;
                    qt.ShippingState = site.Site__r.ShippingState != null ? site.Site__r.ShippingState : null;
                    qt.ShippingPostalCode = site.Site__r.ShippingPostalCode != null ? site.Site__r.ShippingPostalCode : null;
                    qt.ShippingCountry = site.Site__r.ShippingCountry != null ? site.Site__r.ShippingCountry : null;
                    
                    quotes.add(qt);
                }
                newSites.add(quoteSite);
            }
        }
        
        if(!quotes.isEmpty()) {
            Database.update(quotes, AccessLevel.SYSTEM_MODE);
        }
        
        if(!newSites.isEmpty()) {
            Database.insert(newSites, AccessLevel.SYSTEM_MODE);
        }
        
    }
}