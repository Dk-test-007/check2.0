public with sharing class SiteSelectionController_CC {

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getSiteSelectionData(Id recordId) {

        if (recordId == null) {
            throw new AuraHandledException('A record Id is required.');
        }

        Map<String, Object> siteSelectionData = new Map<String, Object>();
        String objectName = getParentObjectName(recordId);

        if (objectName != 'Opportunity' && objectName != 'Quote' && objectName != 'Order') {
            throw new AuraHandledException('This component is not supported for this record type.');
        }

        String parentFields =
            'Id, AccountId, Account.Name, Account.BillingStreet, ' +
            'Account.BillingCity, Account.BillingState, ' +
            'Account.BillingPostalCode, Account.BillingCountry';

        if (objectName == 'Order') {
            parentFields += ', Ship_to_Customer_No_CC__c, Ship_to_Customer_No_CC__r.Name';
        }

        String parentRecordQuery =
            'SELECT ' + parentFields +
            ' FROM ' + objectName +
            ' WHERE Id = :recordId LIMIT 1';

        List<SObject> parentRecords = Database.query(parentRecordQuery, AccessLevel.USER_MODE);
        if (parentRecords.isEmpty()) {
            throw new AuraHandledException('The requested record could not be found or accessed.');
        }

        SObject parentRecord = parentRecords[0];
        Id parentEntityId = (Id) parentRecord.get('AccountId');

        List<Account> relatedSiteAccounts = new List<Account>();
        if (parentEntityId != null) {
            relatedSiteAccounts = [
                SELECT Id, Name, ParentId,
                       ShippingStreet, ShippingCity,
                       ShippingState, ShippingPostalCode,
                       ShippingCountry
                FROM Account
                WHERE ParentId = :parentEntityId
                ORDER BY Name
            ];
        }

        List<Opportunity_Site__c> existingSites = new List<Opportunity_Site__c>();
        if (objectName == 'Opportunity' || objectName == 'Quote') {
            String sitesQuery =
                'SELECT Id, Site__c, Site__r.Name, ' +
                'Site_Name_CC__c, Shipping_Address__c, Primary__c ' +
                'FROM Opportunity_Site__c';

            sitesQuery += objectName == 'Opportunity'
                ? ' WHERE Opportunity__c = :recordId'
                : ' WHERE Quote_CC__c = :recordId';

            sitesQuery += ' ORDER BY Primary__c DESC, Site_Name_CC__c';
            existingSites = Database.query(sitesQuery, AccessLevel.SYSTEM_MODE);
        }

        siteSelectionData.put('parentRecord', parentRecord);
        siteSelectionData.put('parentObjectName', objectName);
        siteSelectionData.put('relatedSiteAccounts', relatedSiteAccounts);
        siteSelectionData.put('existingSites', existingSites);

        if (objectName == 'Order') {
            siteSelectionData.put(
                'currentOrderShipToSiteId',
                (Id) parentRecord.get('Ship_to_Customer_No_CC__c')
            );

            SObject currentShipToSite = parentRecord.getSObject('Ship_to_Customer_No_CC__r');
            siteSelectionData.put(
                'currentOrderShipToSiteName',
                currentShipToSite == null ? null : (String) currentShipToSite.get('Name')
            );
        }

        return siteSelectionData;
    }

    @AuraEnabled
    public static void saveSites(Id recordId, List<Id> siteIds, Id primarySiteId) {

        if (recordId == null || siteIds == null || siteIds.isEmpty()) {
            throw new AuraHandledException('Please select at least one site.');
        }

        String objectName = getParentObjectName(recordId);
        String parentField = objectName == 'Opportunity' ? 'Opportunity__c' : 'Quote_CC__c';
        Set<Id> requestedSiteIds = new Set<Id>(siteIds);

        Id parentOpportunityId;

        if (objectName == 'Quote') {
            parentOpportunityId = [
                SELECT OpportunityId
                FROM Quote
                WHERE Id = :recordId
                WITH USER_MODE
            ].OpportunityId;
        }

        String existingQuery =
            'SELECT Id, Site__c, Primary__c ' +
            'FROM Opportunity_Site__c WHERE ' +
            parentField + ' = :recordId';

        List<Opportunity_Site__c> existingRecords = Database.query(existingQuery, AccessLevel.SYSTEM_MODE);

        Set<Id> existingSiteIds = new Set<Id>();
        Set<Id> existingOpportunitySiteIds = new Set<Id>();
        Id finalPrimarySiteId;

        for (Opportunity_Site__c existingRecord : existingRecords) {
            existingSiteIds.add(existingRecord.Site__c);

            if (existingRecord.Primary__c == true) {
                finalPrimarySiteId = existingRecord.Site__c;
            }
        }

        requestedSiteIds.removeAll(existingSiteIds);

        // Check whether the selected Sites already exist against the parent Opportunity.
        if (objectName == 'Quote' && parentOpportunityId != null && !requestedSiteIds.isEmpty()) {

            for (Opportunity_Site__c opportunitySite : [
                SELECT Site__c
                FROM Opportunity_Site__c
                WHERE Opportunity__c = :parentOpportunityId
                AND Site__c IN :requestedSiteIds
            ]) {
                existingOpportunitySiteIds.add(opportunitySite.Site__c);
            }
        }

        // Use the newly selected Shipment Site when provided.
        // Otherwise preserve any Shipment Site already designated on this record.
        // If neither exists, the records are saved without a primary designation.
        finalPrimarySiteId = primarySiteId != null ? primarySiteId : finalPrimarySiteId;

        List<Opportunity_Site__c> recordsToInsert = new List<Opportunity_Site__c>();

        for (Id siteId : requestedSiteIds) {

            // Create the Opportunity Site record associated with the current record.
            Opportunity_Site__c siteRecord = new Opportunity_Site__c();
            siteRecord.Site__c = siteId;
            siteRecord.Primary__c = finalPrimarySiteId != null &&
                siteId == finalPrimarySiteId;
            siteRecord.put(parentField, recordId);
            recordsToInsert.add(siteRecord);

            // Create a separate Opportunity Site record when the selected Site
            // is not already associated with the Quote's parent Opportunity.
            if (objectName == 'Quote' && parentOpportunityId != null &&
                !existingOpportunitySiteIds.contains(siteId)) {

                Opportunity_Site__c opportunitySiteRecord = new Opportunity_Site__c();
                opportunitySiteRecord.Site__c = siteId;
                opportunitySiteRecord.Opportunity__c = parentOpportunityId;
                opportunitySiteRecord.Primary__c = false;

                recordsToInsert.add(opportunitySiteRecord);
            }
        }

        List<Opportunity_Site__c> recordsToUpdate = new List<Opportunity_Site__c>();

        // Only recalculate existing primary flags when a Shipment Site has been
        // designated. With no Shipment Site, leave existing flags unchanged.
        if (finalPrimarySiteId != null) {
            for (Opportunity_Site__c existingRecord : existingRecords) {
                Boolean shouldBePrimary = existingRecord.Site__c == finalPrimarySiteId;

                if (existingRecord.Primary__c != shouldBePrimary) {
                    existingRecord.Primary__c = shouldBePrimary;
                    recordsToUpdate.add(existingRecord);
                }
            }
        }

        if (!recordsToInsert.isEmpty()) {
            Database.insert(recordsToInsert, AccessLevel.USER_MODE);
        }

        if (!recordsToUpdate.isEmpty()) {
            Database.update(recordsToUpdate, AccessLevel.USER_MODE);
        }

        // Do not sync the parent Shipment Site lookup when no Shipment Site
        // was selected and none was previously designated.
        if (finalPrimarySiteId != null) {
            syncPrimarySite(recordId, objectName, finalPrimarySiteId);
        }
    }

    @AuraEnabled
    public static void updateOrderShipToSite(Id orderId, Id siteId) {

        if (orderId == null || siteId == null) {
            throw new AuraHandledException('Please select a Site for this Order.');
        }

        if (orderId.getSObjectType() != Order.SObjectType) {
            throw new AuraHandledException('This action is only available for Orders.');
        }

        Order orderRecord = [
            SELECT Id, AccountId
            FROM Order
            WHERE Id = :orderId
            WITH USER_MODE
            LIMIT 1
        ];

        if (orderRecord.AccountId == null) {
            throw new AuraHandledException('The Order must have an Account before a Site can be selected.');
        }

        // Only allow a Site that belongs to the Order's Account.
        List<Account> selectedSites = [
            SELECT Id, ParentId, Warehouse_CC__c,
                   Warehouse_CC__r.Location_CC__c
            FROM Account
            WHERE Id = :siteId
            AND ParentId = :orderRecord.AccountId
            WITH USER_MODE
            LIMIT 1
        ];

        if (selectedSites.isEmpty()) {
            throw new AuraHandledException('The selected Site is not associated with the Order Account.');
        }

        Account selectedSite = selectedSites[0];
        String locationCode = selectedSite.Warehouse_CC__r == null
            ? null
            : selectedSite.Warehouse_CC__r.Location_CC__c;

        // Update only the Order. Order Products are intentionally not modified.
        Database.update(
            new Order(
                Id = orderId,
                Ship_to_Customer_No_CC__c = selectedSite.Id,
                Location_Code_CC__c = locationCode
            ),
            AccessLevel.USER_MODE
        );
    }

    @AuraEnabled
    public static void updatePrimarySite(Id recordId, Id siteId) {

        if (recordId == null || siteId == null) {
            throw new AuraHandledException('Invalid site selection.');
        }

        String objectName = getParentObjectName(recordId);
        String parentField = objectName == 'Opportunity' ? 'Opportunity__c' : 'Quote_CC__c';

        String existingQuery = 'SELECT Id, Site__c, Primary__c ' +
                                'FROM Opportunity_Site__c WHERE ' +
                                parentField + ' = :recordId';

        List<Opportunity_Site__c> existingRecords = Database.query(existingQuery, AccessLevel.SYSTEM_MODE);
        List<Opportunity_Site__c> recordsToUpdate = new List<Opportunity_Site__c>();

        for (Opportunity_Site__c existingRecord : existingRecords) {
            Boolean shouldBePrimary = existingRecord.Site__c == siteId;

            if (existingRecord.Primary__c != shouldBePrimary) {
                existingRecord.Primary__c = shouldBePrimary;
                recordsToUpdate.add(existingRecord);
            }
        }

        if (!recordsToUpdate.isEmpty()) {
            Database.update(recordsToUpdate, AccessLevel.USER_MODE);
        }

        syncPrimarySite(recordId, objectName, siteId);
    }

    private static void syncPrimarySite(Id recordId, String objectName, Id siteId) {

        // A null Shipment Site is valid during site association. Never attempt
        // to query Account or update parent shipping fields with a null site.
        if (siteId == null) {
            return;
        }

        if (objectName == 'Opportunity') {

            Database.update(
                new Opportunity(
                    Id = recordId,
                    Ship_To_Site_CC__c = siteId
                ),
                AccessLevel.USER_MODE
            );

        } else {
            Account siteRecord = [
                SELECT Name, ShippingStreet, ShippingCity, ShippingState,
                       ShippingPostalCode, ShippingCountry
                FROM Account
                WHERE Id = :siteId
            ];

            Database.update(
                new Quote(
                    Id = recordId,
                    Ship_to_Site_CC__c = siteId,
                    ShippingName = siteRecord.Name,
                    ShippingStreet = siteRecord.ShippingStreet,
                    ShippingCity = siteRecord.ShippingCity,
                    ShippingState = siteRecord.ShippingState,
                    ShippingPostalCode = siteRecord.ShippingPostalCode,
                    ShippingCountry = siteRecord.ShippingCountry
                ),
                AccessLevel.USER_MODE
            );
        }
    }

    private static String getParentObjectName(Id recordId) {
        if (recordId == null) {
            throw new AuraHandledException('A record Id is required.');
        }
        return recordId.getSObjectType().getDescribe().getName();
    }
}