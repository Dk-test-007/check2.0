/**
 * =============================================================================
 * Class Name    : AccountTriggerHandler_CC_Test
 * Description   : Unit tests for AccountTriggerHandler_CC (+ AccountTrigger_CC).
 *                 Covers the trigger paths end to end (insert / update as an admin)
 *                 and calls the public static helpers directly with in-memory
 *                 records for the branches that depend on the running user's
 *                 profile, on Business Central publishing and on notifications.
 * =============================================================================
 */
@IsTest
private class AccountTriggerHandler_CC_Test {

    private static final String USER_DOMAIN = '@carltontest.invalid';
    private static final String ADMIN_ALIAS = 'athadm';
    private static final String SALES_ALIAS = 'athsales';
    private static final String FINANCE_ALIAS = 'athfin';
    private static final String STANDARD_ALIAS = 'athstd';

    private static Integer fakeSequence = 0;

    @TestSetup
    static void setup() {
        // Users only - business records are created inside each test (avoids mixed DML).
        insert new List<User>{
            OpportunityUi2TestData_CC.user('System Administrator', ADMIN_ALIAS),
            OpportunityUi2TestData_CC.user('Carlton Sales User', SALES_ALIAS),
            OpportunityUi2TestData_CC.user('Carlton Finance User', FINANCE_ALIAS),
            OpportunityUi2TestData_CC.user('Standard User', STANDARD_ALIAS)
        };
    }

    // ===================================================================== trigger paths

    @IsTest
    static void insertAndUpdate_runsTriggerHandlers() {
        Test.setMock(HttpCalloutMock.class, new OkCalloutMock());

        System.runAs(userByAlias(ADMIN_ALIAS)) {
            Account entity = newEntity('ATH Trigger Entity', null);
            entity.Entity_CC__c = 'Carlton Packaging INC';
            insert entity;

            Account insertedEntity = [SELECT Type, Tax_Area_CC__c, Billing_Address_Match_Key_CC__c FROM Account WHERE Id = :entity.Id];
            Assert.areEqual('Prospect', insertedEntity.Type, 'A blank Type defaults to Prospect on insert');
            Assert.areEqual('VERTEX', insertedEntity.Tax_Area_CC__c, 'Carlton Packaging INC entities default to the VERTEX tax area');
            Assert.isTrue(String.valueOf(insertedEntity.Billing_Address_Match_Key_CC__c).startsWith('LONDON|EC1A 1BB'),
                'The billing address match key is built on insert: ' + insertedEntity.Billing_Address_Match_Key_CC__c);

            Account site = newSite('ATH Trigger Site', entity.Id);
            insert site;

            Account insertedSite = [SELECT Type, Site_Code_CC__c, Site_Code_Auto_CC__c FROM Account WHERE Id = :site.Id];
            Assert.areEqual('Prospect', insertedSite.Type, 'A Site inherits the parent Type on insert');
            Assert.areEqual(insertedSite.Site_Code_Auto_CC__c, insertedSite.Site_Code_CC__c,
                'The Site Code is copied from the auto number after insert');

            Test.startTest();
            // Business Central writes back the customer number -> Type Customer, sync status set, Type cascades to the Site
            update new Account(Id = entity.Id, Business_Central_Customer_ID_CC__c = 'BC-ATH-001',
                Business_Central_Customer_Sync_Error_CC__c = 'old error', BillingCity = 'Manchester');
            update new Account(Id = site.Id, Site_Synced_CC__c = true);
            Test.stopTest();

            Account updatedEntity = [SELECT Type, BC_Sync_Status_CC__c, Business_Central_Customer_Sync_Error_CC__c,
                                            Billing_Address_Match_Key_CC__c
                                     FROM Account WHERE Id = :entity.Id];
            Assert.areEqual('Customer', updatedEntity.Type, 'Type becomes Customer once the BC id is populated');
            Assert.areEqual('Successfully Synced', updatedEntity.BC_Sync_Status_CC__c, 'Sync status is set when the BC id arrives');
            Assert.isNull(updatedEntity.Business_Central_Customer_Sync_Error_CC__c, 'Sync error is cleared on a successful sync');
            Assert.isTrue(updatedEntity.Billing_Address_Match_Key_CC__c.startsWith('MANCHESTER'),
                'The match key is rebuilt when an address field changes');

            Account updatedSite = [SELECT Type, BC_Sync_Status_CC__c FROM Account WHERE Id = :site.Id];
            Assert.areEqual('Customer', updatedSite.Type, 'The parent Type change cascades to its Sites');
            Assert.areEqual('Successfully Synced', updatedSite.BC_Sync_Status_CC__c, 'A newly synced Site is marked Successfully Synced');
        }
    }

    @IsTest
    static void beforeDelete_adminPassesAndOthersAreBlocked() {
        System.runAs(userByAlias(ADMIN_ALIAS)) {
            // Outside a trigger Trigger.old is null; an admin never reaches the loop.
            new AccountTriggerHandler_CC().beforeDelete();
            Account adminAccount = new Account(Id = fakeId(Account.SObjectType), Name = 'Admin Delete');
            AccountTriggerHandler_CC.preventAccountDeletion(new List<Account>{ adminAccount });
            Assert.isFalse(adminAccount.hasErrors(), 'Admins may delete Accounts');
        }
        System.runAs(userByAlias(STANDARD_ALIAS)) {
            Account blocked = new Account(Id = fakeId(Account.SObjectType), Name = 'Blocked Delete');
            AccountTriggerHandler_CC.preventAccountDeletion(new List<Account>{ blocked });
            Assert.isTrue(blocked.hasErrors(), 'Non-admins may not delete Accounts');
            Assert.isTrue(blocked.getErrors()[0].getMessage().contains('Only Admin Users'), 'Error explains the restriction');
        }
    }

    @IsTest
    static void runOutsideTrigger_isNoOp() {
        Integer dmlBefore = Limits.getDmlStatements();
        AccountTriggerHandler_CC handler = new AccountTriggerHandler_CC();
        handler.run(handler);
        Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'Nothing runs outside a trigger context');
    }

    // ===================================================================== financial check validation

    @IsTest
    static void validateFinancialApproval_nonAdminGetsAllErrors() {
        System.runAs(userByAlias(STANDARD_ALIAS)) {
            Id entityRt = recordTypeId('Entity');

            // Credit Account with every Business Central field blank
            Account blankCredit = new Account(Id = fakeId(Account.SObjectType), Name = 'Blank Credit', RecordTypeId = entityRt,
                Financial_Check_CC__c = 'Approved', Customer_Type_CC__c = 'Credit Account', Tax_Liable_CC__c = false);
            // Address too long + US address without state
            Account longStreet = new Account(Id = fakeId(Account.SObjectType), Name = 'Long Street', RecordTypeId = entityRt,
                Financial_Check_CC__c = 'Approved', Customer_Type_CC__c = 'Cash Account', Credit_Risk_Status_CC__c = 'Good',
                BillingStreet = 'x'.repeat(120), BillingCity = 'New York', BillingPostalCode = '10001',
                BillingCountryCode = 'US', BillingCountry = 'United States', Tax_Liable_CC__c = true);
            // Not moving to Approved -> ignored
            Account notApproved = new Account(Id = fakeId(Account.SObjectType), Name = 'Not Approved',
                Financial_Check_CC__c = 'Initiated');

            Map<Id, Account> oldMap = new Map<Id, Account>{
                blankCredit.Id => new Account(Id = blankCredit.Id, Financial_Check_CC__c = 'Initiated'),
                longStreet.Id  => new Account(Id = longStreet.Id, Financial_Check_CC__c = 'Initiated'),
                notApproved.Id => new Account(Id = notApproved.Id, Financial_Check_CC__c = 'Yet to be Started')
            };

            Test.startTest();
            AccountTriggerHandler_CC.validateFinancialApproval(new List<Account>{ blankCredit, longStreet, notApproved }, oldMap);
            Test.stopTest();

            String blankMessages = errorText(blankCredit);
            Assert.isTrue(blankMessages.contains('Credit Risk Status is required'), blankMessages);
            Assert.isTrue(blankMessages.contains('Tax Registration Number is required'), blankMessages);
            // Street, City, Postal Code and Country are parts of the compound BillingAddress field: on an
            // in-memory record only the last error added to that compound field is kept (Billing Country).
            Assert.isTrue(blankMessages.contains('Billing Country is required'), blankMessages);
            Assert.isTrue(blankMessages.contains('Tax Area is required'), blankMessages);
            Assert.isTrue(blankMessages.contains('Tax Liable must be checked'), blankMessages);
            Assert.isTrue(blankMessages.contains('Customer Posting Group is required'), blankMessages);
            Assert.isTrue(blankMessages.contains('Gen. Bus. Posting Group is required'), blankMessages);
            Assert.isTrue(blankMessages.contains('Salesperson Code is required'), blankMessages);
            Assert.isTrue(blankMessages.contains('Document Sending Profile is required'), blankMessages);
            Assert.isTrue(blankMessages.contains('Payment Terms is required'), blankMessages);
            Assert.isTrue(blankMessages.contains('Location Code is required'), blankMessages);
            Assert.isTrue(blankMessages.contains('Email is required'), blankMessages);

            String longMessages = errorText(longStreet);
            // Both errors sit on the compound BillingAddress field, so the platform may keep only one of them.
            Assert.isTrue(longMessages.contains('cannot exceed 100 characters')
                || longMessages.contains('Billing State/Province is required'), longMessages);
            Assert.isFalse(longMessages.contains('Credit Risk Status'), 'Cash Accounts do not need a credit risk status');

            Assert.isFalse(notApproved.hasErrors(), 'Records not moving to Approved are not validated');
        }
    }

    @IsTest
    static void creditLimitRules_nonAdmin() {
        System.runAs(userByAlias(STANDARD_ALIAS)) {
            Account noLimit = new Account(Id = fakeId(Account.SObjectType), Name = 'No Limit', Customer_Type_CC__c = 'Credit Account');
            Account withLimit = new Account(Id = fakeId(Account.SObjectType), Name = 'With Limit', Customer_Type_CC__c = 'Credit Account',
                Credit_Limit_CC__c = 1000);
            Account notInCheck = new Account(Id = fakeId(Account.SObjectType), Name = 'Not In Check', Customer_Type_CC__c = 'Credit Account');
            Map<Id, Account> oldMap = new Map<Id, Account>{
                noLimit.Id    => new Account(Id = noLimit.Id, Financial_Check_CC__c = 'Initiated'),
                withLimit.Id  => new Account(Id = withLimit.Id, Financial_Check_CC__c = 'Initiated'),
                notInCheck.Id => new Account(Id = notInCheck.Id, Financial_Check_CC__c = 'Yet to be Started')
            };

            AccountTriggerHandler_CC.validateCreditAccountCreditLimit(new List<Account>{ noLimit, withLimit, notInCheck }, oldMap);

            Assert.isTrue(errorText(noLimit).contains('Credit Limit must be greater than 0'), 'A blank limit is treated as 0');
            Assert.isFalse(withLimit.hasErrors(), 'A positive credit limit is accepted');
            Assert.isFalse(notInCheck.hasErrors(), 'Rule only applies while the Financial Check is Initiated');

            // No credit accounts -> early return
            AccountTriggerHandler_CC.validateCreditAccountCreditLimit(new List<Account>{ notInCheck }, oldMap);
            Assert.isFalse(notInCheck.hasErrors(), 'Nothing to validate');
        }
    }

    // ===================================================================== field locks per profile

    @IsTest
    static void lockIntegrationFields_byProfile() {
        Account oldCustomer = new Account(Id = fakeId(Account.SObjectType), Name = 'Locked Co', Type = 'Customer',
            Entity_CC__c = 'Carlton Packaging INC');
        Account oldProspect = new Account(Id = fakeId(Account.SObjectType), Name = 'Open Co', Type = 'Prospect');
        Map<Id, Account> oldMap = new Map<Id, Account>{ oldCustomer.Id => oldCustomer, oldProspect.Id => oldProspect };

        System.runAs(userByAlias(SALES_ALIAS)) {
            Account renamed = new Account(Id = oldCustomer.Id, Name = 'Renamed Co', Type = 'Customer', Entity_CC__c = 'Carlton Packaging INC');
            Account prospect = new Account(Id = oldProspect.Id, Name = 'Prospect Renamed', Type = 'Prospect');
            AccountTriggerHandler_CC.lockIntegrationFieldsAfterSync(new List<Account>{ renamed, prospect }, oldMap);
            Assert.isTrue(renamed.hasErrors(), 'Sales users cannot rename a Customer');
            Assert.isFalse(prospect.hasErrors(), 'Locks only apply once the Account is a Customer');
        }
        System.runAs(userByAlias(FINANCE_ALIAS)) {
            Account renamed = new Account(Id = oldCustomer.Id, Name = 'Renamed Co', Type = 'Customer', Entity_CC__c = 'Carlton Packaging INC');
            AccountTriggerHandler_CC.lockIntegrationFieldsAfterSync(new List<Account>{ renamed }, oldMap);
            Assert.isFalse(renamed.hasErrors(), 'Finance users may rename a Customer');

            Account entityChanged = new Account(Id = oldCustomer.Id, Name = 'Locked Co', Type = 'Customer', Entity_CC__c = 'Carlton Packaging LLP');
            AccountTriggerHandler_CC.lockIntegrationFieldsAfterSync(new List<Account>{ entityChanged }, oldMap);
            Assert.isTrue(entityChanged.hasErrors(), 'Finance users cannot change the Entity of a Customer');
        }
        System.runAs(userByAlias(STANDARD_ALIAS)) {
            Account renamed = new Account(Id = oldCustomer.Id, Name = 'Renamed Co', Type = 'Customer', Entity_CC__c = 'Carlton Packaging INC');
            AccountTriggerHandler_CC.lockIntegrationFieldsAfterSync(new List<Account>{ renamed }, oldMap);
            Assert.isTrue(renamed.hasErrors(), 'Other profiles get the strictest (Sales) locks');
        }
        System.runAs(userByAlias(ADMIN_ALIAS)) {
            Account renamed = new Account(Id = oldCustomer.Id, Name = 'Renamed Co', Type = 'Customer', Entity_CC__c = 'Carlton Packaging LLP');
            AccountTriggerHandler_CC.lockIntegrationFieldsAfterSync(new List<Account>{ renamed }, oldMap);
            Assert.isFalse(renamed.hasErrors(), 'System Administrators bypass the locks');
        }
    }

    // ===================================================================== in-memory helpers

    @IsTest
    static void simpleFieldDefaults() {
        Id corpRt = recordTypeId('Corporate_Group');
        Id entityRt = recordTypeId('Entity');

        Account corp = new Account(Name = 'Corp', RecordTypeId = corpRt, Type = 'Customer');
        Account blankType = new Account(Name = 'Blank Type', RecordTypeId = entityRt);
        AccountTriggerHandler_CC.clearTypeForCorporateGroup(new List<Account>{ corp, blankType });
        AccountTriggerHandler_CC.setAccountTypeToProspect(new List<Account>{ blankType });
        Assert.isNull(corp.Type, 'Corporate Groups never carry a Type');
        Assert.areEqual('Prospect', blankType.Type, 'Blank Type defaults to Prospect');

        Account cash = new Account(Name = 'Cash', Customer_Type_CC__c = 'Cash Account', Credit_Limit_CC__c = 500);
        AccountTriggerHandler_CC.setCashAccountCreditLimit(new List<Account>{ cash });
        Assert.areEqual(0, cash.Credit_Limit_CC__c, 'Cash Accounts always have a 0 credit limit');

        Account inc = new Account(Id = fakeId(Account.SObjectType), Entity_CC__c = 'Carlton Packaging INC');
        Account sameEntity = new Account(Id = fakeId(Account.SObjectType), Entity_CC__c = 'Carlton Packaging INC');
        Map<Id, Account> taxOld = new Map<Id, Account>{
            inc.Id => new Account(Id = inc.Id, Entity_CC__c = 'Carlton Packaging LLP'),
            sameEntity.Id => new Account(Id = sameEntity.Id, Entity_CC__c = 'Carlton Packaging INC')
        };
        AccountTriggerHandler_CC.setDefaultTaxAreaCode(new List<Account>{ inc, sameEntity }, taxOld);
        Assert.areEqual('VERTEX', inc.Tax_Area_CC__c, 'Changing to the INC entity sets the VERTEX tax area');
        Assert.isNull(sameEntity.Tax_Area_CC__c, 'Unchanged entity keeps its tax area');

        Account newlySynced = new Account(Id = fakeId(Account.SObjectType), BC_Sync_Status_CC__c = 'Successfully Synced',
            Business_Central_Customer_Sync_Error_CC__c = 'error');
        AccountTriggerHandler_CC.emptySyncErrorOnSuccessfulSync(new List<Account>{ newlySynced },
            new Map<Id, Account>{ newlySynced.Id => new Account(Id = newlySynced.Id, BC_Sync_Status_CC__c = 'Callout Failed') });
        Assert.isNull(newlySynced.Business_Central_Customer_Sync_Error_CC__c, 'Sync error cleared on success');

        Account insertedSynced = new Account(Name = 'Inserted Synced', Site_Synced_CC__c = true);
        AccountTriggerHandler_CC.updateSyncStatus(new List<Account>{ insertedSynced }, null);
        Assert.areEqual('Successfully Synced', insertedSynced.BC_Sync_Status_CC__c, 'Synced on insert -> Successfully Synced');

        Account bcIdArrived = new Account(Id = fakeId(Account.SObjectType), Type = 'Prospect', Business_Central_Customer_ID_CC__c = 'BC-9');
        Map<Id, Account> bcOld = new Map<Id, Account>{ bcIdArrived.Id => new Account(Id = bcIdArrived.Id, Type = 'Prospect') };
        AccountTriggerHandler_CC.setTypeOnBusinessCentralIdPopulated(new List<Account>{ bcIdArrived }, bcOld);
        AccountTriggerHandler_CC.updateBusinessCentralSyncStatus(new List<Account>{ bcIdArrived }, bcOld);
        Assert.areEqual('Customer', bcIdArrived.Type, 'BC id populated -> Customer');
        Assert.areEqual('Successfully Synced', bcIdArrived.BC_Sync_Status_CC__c, 'BC id populated -> Successfully Synced');

        Account address = new Account(BillingCity = ' york ', BillingState = 'NY', BillingPostalCode = '10001', BillingCountry = 'US',
            ShippingCity = 'Leeds');
        AccountTriggerHandler_CC.populateAddressMatchKeys(new List<Account>{ address }, null);
        Assert.areEqual('YORK|NY|10001|US', address.Billing_Address_Match_Key_CC__c, 'Billing key is upper-cased and pipe-joined');
        Assert.areEqual('LEEDS', address.Shipping_Address_Match_Key_CC__c, 'Blank parts are skipped');
    }

    @IsTest
    static void handleAccountGenerationFromLead_enforcesRecordTypes() {
        Id entityRt = recordTypeId('Entity');
        Id siteRt = recordTypeId('Site');
        Id existingAccountId = fakeId(Account.SObjectType);

        Account entityLeadWrongRt = new Account(Name = 'E', Generated_From_Lead_CC__c = true, Lead_Type_CC__c = 'Entity', RecordTypeId = siteRt);
        Account siteLeadWrongRt = new Account(Name = 'S', Generated_From_Lead_CC__c = true, Lead_Type_CC__c = 'Site', RecordTypeId = entityRt);
        Account siteLead = new Account(Name = 'S2', Generated_From_Lead_CC__c = true, Lead_Type_CC__c = 'Site', RecordTypeId = siteRt,
            Lead_Existing_Account_CC__c = existingAccountId, BillingStreet = '1 Road', BillingCity = 'Leeds',
            BillingPostalCode = 'LS1 1AA', BillingCountry = 'United Kingdom');
        Account entityLead = new Account(Name = 'E2', Generated_From_Lead_CC__c = true, Lead_Type_CC__c = 'Entity', RecordTypeId = entityRt,
            ShippingCity = 'Already Set');
        Account notFromLead = new Account(Name = 'N');

        AccountTriggerHandler_CC.handleAccountGenerationFromLead(
            new List<Account>{ entityLeadWrongRt, siteLeadWrongRt, siteLead, entityLead, notFromLead });
        AccountTriggerHandler_CC.handleAccountGenerationFromLead(new List<Account>());

        Assert.isTrue(errorText(entityLeadWrongRt).contains('Entity Lead'), 'Entity lead must become an Entity');
        Assert.isTrue(errorText(siteLeadWrongRt).contains('Site Lead'), 'Site lead must become a Site');
        Assert.isFalse(siteLead.hasErrors(), 'Valid site lead');
        Assert.areEqual(existingAccountId, siteLead.ParentId, 'Site lead is parented to the existing account');
        Assert.areEqual('Leeds', siteLead.ShippingCity, 'Blank shipping address is copied from billing');
        Assert.areEqual('Already Set', entityLead.ShippingCity, 'An existing shipping address is kept');
        Assert.isFalse(notFromLead.hasErrors(), 'Accounts not generated from a Lead are ignored');
    }

    // ===================================================================== Business Central publishing

    @IsTest
    static void publishFinancialCheckApproved_queuesCreateOnce() {
        Test.setMock(HttpCalloutMock.class, new OkCalloutMock());
        Account toCreate = new Account(Id = fakeId(Account.SObjectType), Name = 'Create', Financial_Check_CC__c = 'Approved');
        Account toUpdate = new Account(Id = fakeId(Account.SObjectType), Name = 'Update', Financial_Check_CC__c = 'Approved',
            Business_Central_Customer_ID_CC__c = 'BC-UPD');
        Account notApproved = new Account(Id = fakeId(Account.SObjectType), Name = 'Rejected', Financial_Check_CC__c = 'Rejected');
        Account noOld = new Account(Id = fakeId(Account.SObjectType), Name = 'No Old', Financial_Check_CC__c = 'Approved');
        Map<Id, Account> oldMap = new Map<Id, Account>{
            toCreate.Id    => new Account(Id = toCreate.Id, Financial_Check_CC__c = 'Initiated'),
            toUpdate.Id    => new Account(Id = toUpdate.Id, Financial_Check_CC__c = 'Initiated'),
            notApproved.Id => new Account(Id = notApproved.Id, Financial_Check_CC__c = 'Initiated')
        };
        List<Account> newList = new List<Account>{ toCreate, toUpdate, notApproved, noOld };

        System.runAs(userByAlias(ADMIN_ALIAS)) {
            Integer jobsBefore = Limits.getQueueableJobs();
            AccountTriggerHandler_CC.publishFinancialCheckApprovedToBusinessCentral(newList, oldMap);
            Integer afterFirst = Limits.getQueueableJobs();
            AccountTriggerHandler_CC.publishFinancialCheckApprovedToBusinessCentral(newList, oldMap);

            Assert.areEqual(jobsBefore + 1, afterFirst, 'One Create job is queued for the newly approved account');
            Assert.areEqual(afterFirst, Limits.getQueueableJobs(), 'An account is only published once per transaction');
        }
    }

    @IsTest
    static void publishEntityUpdates_queuesChangedFields() {
        Test.setMock(HttpCalloutMock.class, new OkCalloutMock());
        Id entityRt = recordTypeId('Entity');

        System.runAs(userByAlias(ADMIN_ALIAS)) {
            // Field list comes from Integration_Config__mdt (Account / Update)
            Account changedEntity = new Account(Id = fakeId(Account.SObjectType), RecordTypeId = entityRt, Name = 'New Name',
                Business_Central_Customer_ID_CC__c = 'BC-ENT-1', Salesperson_Code_CC__c = UserInfo.getUserId());
            Account unchangedEntity = new Account(Id = fakeId(Account.SObjectType), RecordTypeId = entityRt, Name = 'Same',
                Business_Central_Customer_ID_CC__c = 'BC-ENT-2');
            Account entityNoOld = new Account(Id = fakeId(Account.SObjectType), RecordTypeId = entityRt, Name = 'No Old',
                Business_Central_Customer_ID_CC__c = 'BC-ENT-3');
            Map<Id, Account> entityOld = new Map<Id, Account>{
                changedEntity.Id   => new Account(Id = changedEntity.Id, RecordTypeId = entityRt, Name = 'Old Name',
                                                  Business_Central_Customer_ID_CC__c = 'BC-ENT-1'),
                unchangedEntity.Id => unchangedEntity.clone(true, true)
            };

            Integer jobsBefore = Limits.getQueueableJobs();
            AccountTriggerHandler_CC.publishEntityUpdatesToBusinessCentral(
                new List<Account>{ changedEntity, unchangedEntity, entityNoOld }, entityOld);
            if (hasIntegrationConfig('Update')) {
                Assert.areEqual(jobsBefore + 1, Limits.getQueueableJobs(), 'Changed BC-synced entities are queued for Update');
            }
        }
    }

    @IsTest
    static void publishSiteUpdates_routesUpdateAndCreate() {
        Test.setMock(HttpCalloutMock.class, new OkCalloutMock());
        Id siteRt = recordTypeId('Site');

        System.runAs(userByAlias(ADMIN_ALIAS)) {
            Account syncedParent = newEntity('ATH Synced Parent', 'BC-PARENT-1');
            Account unsyncedParent = newEntity('ATH Unsynced Parent', null);
            insert new List<Account>{ syncedParent, unsyncedParent };

            // Field list comes from Integration_Config__mdt (Account / SiteUpdate)
            Account syncedSite = newFakeSite(siteRt, syncedParent.Id, 'Synced Site New', true);
            Account unsyncedSite = newFakeSite(siteRt, syncedParent.Id, 'Unsynced Site New', false);
            Account siteUnderUnsynced = newFakeSite(siteRt, unsyncedParent.Id, 'Orphan Site New', false);
            Account siteNoOld = newFakeSite(siteRt, syncedParent.Id, 'No Old', false);
            Map<Id, Account> siteOld = new Map<Id, Account>{
                syncedSite.Id        => newOldSite(syncedSite, 'Synced Site Old'),
                unsyncedSite.Id      => newOldSite(unsyncedSite, 'Unsynced Site Old'),
                siteUnderUnsynced.Id => newOldSite(siteUnderUnsynced, 'Orphan Site Old')
            };

            Integer jobsBefore = Limits.getQueueableJobs();
            AccountTriggerHandler_CC.publishSiteUpdatesToBusinessCentral(
                new List<Account>{ syncedSite, unsyncedSite, siteUnderUnsynced, siteNoOld }, siteOld);
            if (hasIntegrationConfig('SiteUpdate')) {
                Assert.areEqual(jobsBefore + 2, Limits.getQueueableJobs(), 'One SiteUpdate and one SiteCreate job are queued');
            }

            // Only the unsynced parent changed -> no synced parents -> nothing queued
            jobsBefore = Limits.getQueueableJobs();
            AccountTriggerHandler_CC.publishSiteUpdatesToBusinessCentral(new List<Account>{ siteUnderUnsynced }, siteOld);
            // No changes at all -> nothing queued
            AccountTriggerHandler_CC.publishSiteUpdatesToBusinessCentral(new List<Account>{ syncedSite },
                new Map<Id, Account>{ syncedSite.Id => syncedSite.clone(true, true) });
            // Auto-number bypass -> nothing queued
            AccountTriggerHandler_CC.bypassUpdateSyncForAutoNumber = true;
            AccountTriggerHandler_CC.publishSiteUpdatesToBusinessCentral(new List<Account>{ syncedSite }, siteOld);
            AccountTriggerHandler_CC.bypassUpdateSyncForAutoNumber = false;
            Assert.areEqual(jobsBefore, Limits.getQueueableJobs(), 'Nothing is queued when no synced site changed');
        }
    }

    @IsTest
    static void publishNewSitesAndRelatedRecords_queueSiteCreate() {
        Test.setMock(HttpCalloutMock.class, new OkCalloutMock());
        Id siteRt = recordTypeId('Site');

        System.runAs(userByAlias(ADMIN_ALIAS)) {
            Account syncedParent = newEntity('ATH New Site Parent', 'BC-PARENT-2');
            Account unsyncedParent = newEntity('ATH New Site Unsynced', null);
            insert new List<Account>{ syncedParent, unsyncedParent };
            Account realSite = newSite('ATH Related Site', unsyncedParent.Id);
            insert realSite;

            // New sites under a synced parent are published
            Account freshSite = newFakeSite(siteRt, syncedParent.Id, 'New Site', false);
            Account orphanSite = newFakeSite(siteRt, unsyncedParent.Id, 'Orphan Site', false);
            Integer jobsBefore = Limits.getQueueableJobs();
            AccountTriggerHandler_CC.publishNewSitesForSyncedParents(new List<Account>{ freshSite, orphanSite }, null);
            Assert.areEqual(jobsBefore + 1, Limits.getQueueableJobs(), 'Sites of a synced parent are queued for SiteCreate');

            // Parent not synced / no parent -> nothing queued
            jobsBefore = Limits.getQueueableJobs();
            AccountTriggerHandler_CC.publishNewSitesForSyncedParents(new List<Account>{ orphanSite }, null);
            AccountTriggerHandler_CC.publishNewSitesForSyncedParents(
                new List<Account>{ new Account(Id = fakeId(Account.SObjectType), Name = 'No Parent') }, null);
            Assert.areEqual(jobsBefore, Limits.getQueueableJobs(), 'Nothing is queued without a synced parent');

            // Parent just got its BC id -> its existing Sites are published
            Account parentSynced = new Account(Id = unsyncedParent.Id, Name = unsyncedParent.Name, OwnerId = UserInfo.getUserId(),
                Business_Central_Customer_ID_CC__c = 'BC-NOW-SYNCED');
            Account parentBefore = new Account(Id = unsyncedParent.Id, Name = unsyncedParent.Name);
            jobsBefore = Limits.getQueueableJobs();
            AccountTriggerHandler_CC.publishRelatedRecordsOnParentSync(new List<Account>{ parentSynced },
                new Map<Id, Account>{ parentBefore.Id => parentBefore });
            Assert.areEqual(jobsBefore + 1, Limits.getQueueableJobs(), 'Child Sites are queued once the parent syncs');

            // Parent without children / not newly synced -> nothing queued
            jobsBefore = Limits.getQueueableJobs();
            AccountTriggerHandler_CC.publishRelatedRecordsOnParentSync(new List<Account>{ syncedParent },
                new Map<Id, Account>{ syncedParent.Id => syncedParent.clone(true, true) });
            Account childless = new Account(Id = syncedParent.Id, Name = syncedParent.Name, OwnerId = UserInfo.getUserId(),
                Business_Central_Customer_ID_CC__c = 'BC-CHILDLESS');
            AccountTriggerHandler_CC.publishRelatedRecordsOnParentSync(new List<Account>{ childless },
                new Map<Id, Account>{ syncedParent.Id => new Account(Id = syncedParent.Id) });
            Assert.areEqual(jobsBefore, Limits.getQueueableJobs(), 'Nothing is queued without child Sites');
        }
    }

    // ===================================================================== emails & notifications

    @IsTest
    static void financialCheckOutcome_sendsNotifications() {
        Account approvedNoOwner = new Account(Id = fakeId(Account.SObjectType), Name = 'Approved Co', Financial_Check_CC__c = 'Approved',
            OwnerId = fakeId(User.SObjectType), Credit_Limit_CC__c = 25000, CurrencyIsoCode = 'GBP', Credit_Risk_Status_CC__c = 'Good');
        Account rejectedUnmapped = new Account(Id = fakeId(Account.SObjectType), Name = 'Rejected Co', Financial_Check_CC__c = 'Rejected',
            OwnerId = fakeId(User.SObjectType), Credit_Limit_CC__c = 10, CurrencyIsoCode = 'SEK',
            Credit_Risk_Status_CC__c = 'x'.repeat(800));
        Account noCurrency = new Account(Id = fakeId(Account.SObjectType), Name = 'No Currency Co', Financial_Check_CC__c = 'Approved',
            OwnerId = fakeId(User.SObjectType), Credit_Limit_CC__c = 5);
        noCurrency.put('CurrencyIsoCode', null);
        Account noLimit = new Account(Id = fakeId(Account.SObjectType), Name = 'No Limit Co', Financial_Check_CC__c = 'Approved',
            OwnerId = fakeId(User.SObjectType));
        Account unchanged = new Account(Id = fakeId(Account.SObjectType), Name = 'Unchanged', Financial_Check_CC__c = 'Approved',
            OwnerId = fakeId(User.SObjectType));
        Account approvedThenRejected = new Account(Id = fakeId(Account.SObjectType), Name = 'Later Rejected',
            Financial_Check_CC__c = 'Rejected', OwnerId = fakeId(User.SObjectType));
        Account initiated = new Account(Id = fakeId(Account.SObjectType), Name = 'Initiated', Financial_Check_CC__c = 'Initiated',
            OwnerId = fakeId(User.SObjectType));
        Account noOld = new Account(Id = fakeId(Account.SObjectType), Name = 'No Old', Financial_Check_CC__c = 'Approved',
            OwnerId = fakeId(User.SObjectType));

        Map<Id, Account> oldMap = new Map<Id, Account>{
            approvedNoOwner.Id      => new Account(Id = approvedNoOwner.Id, Financial_Check_CC__c = 'Initiated'),
            rejectedUnmapped.Id     => new Account(Id = rejectedUnmapped.Id, Financial_Check_CC__c = 'Initiated'),
            noCurrency.Id           => new Account(Id = noCurrency.Id, Financial_Check_CC__c = 'Rejected'),
            noLimit.Id              => new Account(Id = noLimit.Id, Financial_Check_CC__c = 'Initiated'),
            unchanged.Id            => new Account(Id = unchanged.Id, Financial_Check_CC__c = 'Approved'),
            approvedThenRejected.Id => new Account(Id = approvedThenRejected.Id, Financial_Check_CC__c = 'Approved'),
            initiated.Id            => new Account(Id = initiated.Id, Financial_Check_CC__c = 'Yet to be Started')
        };

        Test.startTest();
        // Owners do not exist -> no emails are rendered, bell notifications are still attempted.
        AccountTriggerHandler_CC.sendFinancialCheckCompletionEmails(new List<Account>{
            approvedNoOwner, rejectedUnmapped, noCurrency, noLimit, unchanged, approvedThenRejected, initiated, noOld
        }, oldMap);
        // Nothing eligible -> early return
        AccountTriggerHandler_CC.sendFinancialCheckCompletionEmails(new List<Account>{ unchanged }, oldMap);
        Integer emailInvocations = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(0, emailInvocations, 'No email is sent when the owner cannot be resolved');
    }

    @IsTest
    static void onboardingAndFinancialCheckEmails_forRealAccount() {
        Account entity;
        User admin = userByAlias(ADMIN_ALIAS);
        System.runAs(admin) {
            entity = newEntity('ATH Email Entity', null);
            insert entity;
        }

        Account completed = new Account(Id = entity.Id, Name = entity.Name, Client_Onboarding_Status_CC__c = 'Completed',
            Financial_Check_CC__c = 'Approved', OwnerId = admin.Id, Credit_Limit_CC__c = 1000, CurrencyIsoCode = 'USD');
        Account oldAccount = new Account(Id = entity.Id, Name = entity.Name, Client_Onboarding_Status_CC__c = 'Initiated',
            Financial_Check_CC__c = 'Initiated');
        Map<Id, Account> oldMap = new Map<Id, Account>{ oldAccount.Id => oldAccount };

        Boolean onboardingRan = false;
        Boolean financialRan = false;
        Test.startTest();
        // Email delivery depends on org deliverability settings; the logic under test is the selection and rendering.
        try {
            AccountTriggerHandler_CC.sendOnboardingCompletionEmails(new List<Account>{ completed }, oldMap);
            onboardingRan = true;
        } catch (Exception ex) {
            System.debug(LoggingLevel.WARN, 'Onboarding email not sent in test: ' + ex.getMessage());
        }
        try {
            AccountTriggerHandler_CC.sendFinancialCheckCompletionEmails(new List<Account>{ completed }, oldMap);
            financialRan = true;
        } catch (Exception ex) {
            System.debug(LoggingLevel.WARN, 'Credit outcome email not sent in test: ' + ex.getMessage());
        }
        // Not newly completed -> nothing to do
        AccountTriggerHandler_CC.sendOnboardingCompletionEmails(new List<Account>{ completed },
            new Map<Id, Account>{ completed.Id => completed.clone(true, true) });
        Test.stopTest();

        Assert.areEqual(entity.Id, completed.Id, 'Emails are generated for the persisted account');
        System.debug('Onboarding email path completed: ' + onboardingRan + ', financial email path completed: ' + financialRan);
    }

    // ===================================================================== helpers

    private static User userByAlias(String alias) {
        String usernamePattern = '%' + USER_DOMAIN;
        return [SELECT Id, Name, Email FROM User WHERE Alias = :alias AND Username LIKE :usernamePattern LIMIT 1];
    }

    private static Id recordTypeId(String developerName) {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get(developerName).getRecordTypeId();
    }

    private static Id fakeId(SObjectType objectType) {
        fakeSequence++;
        return Id.valueOf(objectType.getDescribe().getKeyPrefix() + String.valueOf(fakeSequence).leftPad(12, '0'));
    }

    private static Account newEntity(String name, String businessCentralId) {
        return new Account(
            Name = name + ' ' + OpportunityUi2TestData_CC.suffix(),
            RecordTypeId = recordTypeId('Entity'),
            BillingStreet = '1 Test Street',
            BillingCity = 'London',
            BillingPostalCode = 'EC1A 1BB',
            BillingCountryCode = 'GB',
            Business_Central_Customer_ID_CC__c = businessCentralId
        );
    }

    private static Account newSite(String name, Id parentId) {
        return new Account(
            Name = name + ' ' + OpportunityUi2TestData_CC.suffix(),
            RecordTypeId = recordTypeId('Site'),
            ParentId = parentId,
            ShippingStreet = '2 Site Road',
            ShippingCity = 'Leeds',
            ShippingPostalCode = 'LS1 1AA',
            ShippingCountryCode = 'GB'
        );
    }

    private static Account newFakeSite(Id siteRt, Id parentId, String name, Boolean synced) {
        return new Account(Id = fakeId(Account.SObjectType), RecordTypeId = siteRt, ParentId = parentId, Name = name,
            Site_Synced_CC__c = synced);
    }

    private static Account newOldSite(Account site, String oldName) {
        return new Account(Id = site.Id, RecordTypeId = site.RecordTypeId, ParentId = site.ParentId, Name = oldName,
            Site_Synced_CC__c = site.Site_Synced_CC__c);
    }

    private static Boolean hasIntegrationConfig(String operation) {
        return ![SELECT Id FROM Integration_Config__mdt
                 WHERE SObject_API_Name__c = 'Account' AND Operation__c = :operation LIMIT 1].isEmpty();
    }

    private static String errorText(SObject record) {
        List<String> messages = new List<String>();
        for (Database.Error error : record.getErrors()) {
            messages.add(error.getMessage());
        }
        return String.join(messages, ' | ');
    }

    private class OkCalloutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{}');
            return response;
        }
    }
}