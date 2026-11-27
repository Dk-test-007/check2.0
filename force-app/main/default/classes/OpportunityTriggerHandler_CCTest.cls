/**
 * =============================================================================
 * Class Name    : OpportunityTriggerHandler_CCTest
 * Description   : Unit test class for OpportunityTriggerHandler. Covers
 *                 Opportunity creation and update scenarios based on Account
 *                 hierarchy, including Corporate Group, Entity, and Site
 *                 validations.
 *
 * Author        : Nipun Jain
 * Created Date  : Sept 2026
 * =============================================================================
 */

@IsTest
private class OpportunityTriggerHandler_CCTest {

    @TestSetup
    static void setupData() {
        Id corporateGroupId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Corporate_Group').getRecordTypeId();
        Id entityId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Entity').getRecordTypeId();
        Id siteId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Site').getRecordTypeId();

        Account corporateGroup = new Account(
            Name = 'Corporate Group',
            RecordTypeId = corporateGroupId
        );
        insert corporateGroup;

        Account entity = new Account(
            Name = 'Entity',
            ParentId = corporateGroup.Id,
            RecordTypeId = entityId
        );

        insert entity;

        Account site = new Account(
            Name = 'Site',
            ParentId = entity.Id,
            RecordTypeId = siteId
        );

        insert site;

        Account siteWithoutEntity = new Account(
            Name = 'Site Without Entity',
            RecordTypeId = siteId
        );

        insert siteWithoutEntity;
    }

    @IsTest
    static void testOpportunityInsertWithCorporateGroup() {
        Account corporateGroup = [
            SELECT Id
            FROM Account
            WHERE Name = 'Corporate Group'
            LIMIT 1
        ];

        Opportunity opp = new Opportunity(
            Name = 'Corporate Group Opportunity',
            AccountId = corporateGroup.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );

        Test.startTest();
        Database.SaveResult result = Database.insert(opp, false);
        Test.stopTest();

        System.assertEquals(false, result.isSuccess());
        System.assertEquals('Opportunity cannot be created for a Corporate Group', result.getErrors()[0].getMessage());
    }

    @IsTest
    static void testOpportunityInsertWithSite() {
        Account site = [
            SELECT Id
            FROM Account
            WHERE Name = 'Site'
            LIMIT 1
        ];

        Opportunity opp = new Opportunity(
            Name = 'Site Opportunity',
            AccountId = site.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        Account entity = [
            SELECT Id
            FROM Account
            WHERE Name = 'Entity'
            LIMIT 1
        ];

        Opportunity insertedOpp = [
            SELECT AccountId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];

        System.assertEquals(entity.Id, insertedOpp.AccountId);
    }

    @IsTest
    static void testOpportunityInsertWithSiteWithoutEntity() {
        Account siteWithoutEntity = [
            SELECT Id
            FROM Account
            WHERE Name = 'Site Without Entity'
            LIMIT 1
        ];

        Opportunity opp = new Opportunity(
            Name = 'Site Without Entity Opportunity',
            AccountId = siteWithoutEntity.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );

        Test.startTest();
        Database.SaveResult result = Database.insert(opp, false);
        Test.stopTest();

        System.assertEquals(false, result.isSuccess());
        System.assertEquals(
            'Opportunity cannot be created for a Site without an Entity',
            result.getErrors()[0].getMessage()
        );
    }

    @IsTest
    static void testOpportunityUpdateWithChangedAccount() {
        Account entity = [
            SELECT Id
            FROM Account
            WHERE Name = 'Entity'
            LIMIT 1
        ];

        Account corporateGroup = [
            SELECT Id
            FROM Account
            WHERE Name = 'Corporate Group'
            LIMIT 1
        ];

        Opportunity opp = new Opportunity(
            Name = 'Update Opportunity',
            AccountId = entity.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );

        insert opp;

        opp.AccountId = corporateGroup.Id;

        Test.startTest();
        Database.SaveResult result = Database.update(opp, false);
        Test.stopTest();

        System.assertEquals(false, result.isSuccess());
        System.assertEquals('Opportunity cannot be created for a Corporate Group', result.getErrors()[0].getMessage());
    }

    @IsTest
    static void testOpportunityUpdateWithoutAccountChange() {
        Account entity = [
            SELECT Id
            FROM Account
            WHERE Name = 'Entity'
            LIMIT 1
        ];

        Opportunity opp = new Opportunity(
            Name = 'No Account Change Opportunity',
            AccountId = entity.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );

        insert opp;

        opp.Name = 'Updated Opportunity';

        Test.startTest();
        update opp;
        Test.stopTest();

        Opportunity updatedOpp = [
            SELECT Name, AccountId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];

        System.assertEquals('Updated Opportunity', updatedOpp.Name);
        System.assertEquals(entity.Id, updatedOpp.AccountId);
    }
}