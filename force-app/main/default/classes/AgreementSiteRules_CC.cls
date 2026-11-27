/**
 * Opportunity UI2: which Sites may carry an Entity's Sales Agreement business.
 * A Site is allowed when it is a Site-record-type child Account of the agreement's billing Entity (the existing
 * Entity/Site hierarchy). Sites are queried in user mode, so a user only sees Sites they can see.
 */
public with sharing class AgreementSiteRules_CC {

    public static final String SITE_RECORD_TYPE = 'Site';

    public static List<Account> sitesOfEntity(Id entityId) {
        if (entityId == null) {
            return new List<Account>();
        }
        return [SELECT Id, Name, ShippingStreet, ShippingCity, ShippingStateCode, ShippingPostalCode, ShippingCountryCode
                FROM Account WHERE ParentId = :entityId AND RecordType.DeveloperName = :SITE_RECORD_TYPE
                WITH USER_MODE ORDER BY Name LIMIT 500];
    }

    /** Throws unless every Site is a Site of the Entity. */
    public static void requireSitesOfEntity(Id entityId, Set<Id> siteIds) {
        if (siteIds == null || siteIds.isEmpty()) {
            return;
        }
        Set<Id> allowed = new Map<Id, Account>(sitesOfEntity(entityId)).keySet();
        for (Id siteId : siteIds) {
            if (!allowed.contains(siteId)) {
                throw SalesAgreementPlanService_CC.error('Site ' + siteId + ' is not a Site of this Entity.');
            }
        }
    }

    /** Sites an agreement's Orders may ship to: its listed Sites when Site-scoped, otherwise any Site of the Entity. */
    public static Set<Id> allowedShipToSites(SalesAgreement agreement) {
        Set<Id> entitySites = new Map<Id, Account>(sitesOfEntity(agreement.AccountId)).keySet();
        if (agreement.Commercial_Scope_CC__c != SalesAgreementPlanService_CC.SCOPE_SITE) {
            return entitySites;
        }
        Set<Id> scoped = new Set<Id>();
        for (Sales_Agreement_Site_CC__c scope : [SELECT Site_CC__c FROM Sales_Agreement_Site_CC__c
                                                 WHERE Sales_Agreement_CC__c = :agreement.Id WITH USER_MODE]) {
            if (entitySites.contains(scope.Site_CC__c)) {
                scoped.add(scope.Site_CC__c);
            }
        }
        return scoped;
    }
}