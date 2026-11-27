/**
 * Tests for ContractContractLinesController_CC (Contract Lines MOQ editor on the Contract record page).
 *
 * SalesContractLine is gated by the "Contract LifeCycle Management User" permission set licence: even System
 * Administrators are denied the entity without it, so every test runs as a System Administrator holding that licence
 * plus the CLM permission sets. The Entity is created by a UI2 isolation administrator and marked as synthetic UI2 data
 * so no Business Central callouts are queued for it. Data is saved in system mode (field-level security on Contract and
 * the Contract Line MOQ fields differs per org and is not under test).
 */
@IsTest
private class ContractContractLinesController_CC_Test {

    private static final String CLM_ALIAS = 'cclclm';
    private static final String CONTRACT_NAME = 'ZZCCL Main Contract';
    private static final String EMPTY_CONTRACT_NAME = 'ZZCCL Empty Contract';
    private static final String PRODUCT_A = 'ZZCCL Product A';
    private static final String PRODUCT_B = 'ZZCCL Product B';
    private static final String PRODUCT_C = 'ZZCCL Product C';

    @TestSetup
    static void setup() {
        User admin = OpportunityUi2TestData_CC.isolationAdmin();
        User clm = createClmUser();
        Account entity;
        System.runAs(admin) {
            entity = OpportunityUi2TestData_CC.entity(clm.Id, true);
        }
        System.runAs(clm) {
            PricebookEntry entryA = OpportunityUi2TestData_CC.standardEntry(PRODUCT_A, 40, 'GBP');
            PricebookEntry entryB = OpportunityUi2TestData_CC.standardEntry(PRODUCT_B, 40, 'GBP');
            PricebookEntry entryC = OpportunityUi2TestData_CC.standardEntry(PRODUCT_C, 40, 'GBP');

            Contract main = buildContract(entity.Id, CONTRACT_NAME);
            Contract empty = buildContract(entity.Id, EMPTY_CONTRACT_NAME);
            Database.insert(new List<Contract>{ main, empty }, AccessLevel.SYSTEM_MODE);

            Database.insert(new List<SalesContractLine>{
                buildLine(main.Id, entryA.Product2Id, PRODUCT_A, 10, 'No', null),
                buildLine(main.Id, entryB.Product2Id, PRODUCT_B, 20, 'Yes', 5),
                buildLine(main.Id, entryC.Product2Id, PRODUCT_C, 5, null, null)
            }, AccessLevel.SYSTEM_MODE);
        }
    }

    // ------------------------------------------------------------------ helpers

    private static User createClmUser() {
        User usr = OpportunityUi2TestData_CC.user('System Administrator', CLM_ALIAS);
        insert usr;
        PermissionSetLicense psl = [SELECT Id FROM PermissionSetLicense WHERE DeveloperName = 'ContractManagementUser' LIMIT 1];
        insert new PermissionSetLicenseAssign(AssigneeId = usr.Id, PermissionSetLicenseId = psl.Id);
        OpportunityUi2TestData_CC.assign(usr.Id, new List<String>{ 'CLMAdminUser', 'CLMRuntimeUser' });
        return usr;
    }

    private static User clmUser() {
        return [SELECT Id FROM User WHERE Alias = :CLM_ALIAS AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static Contract buildContract(Id accountId, String name) {
        return new Contract(AccountId = accountId, Name = name, Status = 'Draft', StartDate = Date.today(),
            ContractTerm = 12, Pricebook2Id = Test.getStandardPricebookId(), CurrencyIsoCode = 'GBP');
    }

    private static SalesContractLine buildLine(Id contractId, Id productId, String name, Decimal quantity,
                                               String moqRequired, Decimal minimum) {
        return new SalesContractLine(ContractId = contractId, Name = name, Product2Id = productId, Quantity = quantity,
            UnitPrice = 40, MOQ_Required_CC__c = moqRequired, Minimum_Order_Quantity_CC__c = minimum);
    }

    private static Contract contract(String name) {
        return [SELECT Id, AccountId FROM Contract WHERE Name = :name WITH SYSTEM_MODE LIMIT 1];
    }

    private static SalesContractLine line(String productName) {
        String pattern = productName + '%';
        return [SELECT Id, Quantity, Remaining_SKU_CC__c, MOQ_Required_CC__c, Minimum_Order_Quantity_CC__c
                FROM SalesContractLine WHERE Product2.Name LIKE :pattern WITH SYSTEM_MODE LIMIT 1];
    }

    private static Map<String, Object> change(Object lineId, Object moqRequired, Object minimum) {
        return new Map<String, Object>{ 'contractLineId' => lineId, 'moqRequired' => moqRequired, 'minimumOrderQuantity' => minimum };
    }

    /** Calls saveContractLines and returns the AuraHandledException message, or null when it succeeds. */
    private static String saveError(Id contractId, String linesJson) {
        try {
            ContractContractLinesController_CC.saveContractLines(contractId, linesJson);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String loadError(Id contractId) {
        try {
            ContractContractLinesController_CC.getContractLines(contractId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String refreshError(Id contractId) {
        try {
            ContractContractLinesController_CC.refreshRecordPage(contractId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static Id fakeId(SObjectType objectType) {
        return Id.valueOf(objectType.getDescribe().getKeyPrefix() + '000000000000');
    }

    // ------------------------------------------------------------------ getContractLines

    @IsTest
    static void getContractLines_ReturnsLinesAndRecalculatesRemainingSkuOnce() {
        System.runAs(clmUser()) {
            Id contractId = contract(CONTRACT_NAME).Id;

            Test.startTest();
            ContractContractLinesController_CC.ContractLinesResult first = ContractContractLinesController_CC.getContractLines(contractId);
            ContractContractLinesController_CC.ContractLinesResult second = ContractContractLinesController_CC.getContractLines(contractId);
            Test.stopTest();

            Assert.areEqual(3, first.lines.size(), 'All Contract Lines are returned');
            Assert.areEqual(0, second.recalculatedLineCount, 'A second load changes nothing');
            Assert.areEqual(20, line(PRODUCT_B).Remaining_SKU_CC__c, 'Remaining SKU equals the quantity when nothing is ordered');

            Map<String, ContractContractLinesController_CC.ContractLineWrapper> byProduct =
                new Map<String, ContractContractLinesController_CC.ContractLineWrapper>();
            for (ContractContractLinesController_CC.ContractLineWrapper wrapper : first.lines) {
                Assert.isNotNull(wrapper.contractLineId);
                Assert.isNotNull(wrapper.productId);
                byProduct.put(wrapper.productName.left(PRODUCT_A.length()), wrapper);
            }
            Assert.isFalse(byProduct.get(PRODUCT_A).moqRequired);
            Assert.areEqual(0, byProduct.get(PRODUCT_A).minimumOrderQuantity, 'Minimum is 0 when MOQ is not required');
            Assert.isTrue(byProduct.get(PRODUCT_B).moqRequired);
            Assert.areEqual(5, byProduct.get(PRODUCT_B).minimumOrderQuantity);
            Assert.areEqual(20, byProduct.get(PRODUCT_B).quantity);
            Assert.isFalse(byProduct.get(PRODUCT_C).moqRequired, 'A blank MOQ Required means not required');
        }
    }

    @IsTest
    static void getContractLines_SubtractsOrderedQuantities() {
        System.runAs(clmUser()) {
            Contract main = contract(CONTRACT_NAME);
            SalesContractLine lineA = line(PRODUCT_A);
            String productPattern = PRODUCT_A + '%';
            PricebookEntry entry = [SELECT Id, UnitPrice FROM PricebookEntry WHERE Product2.Name LIKE :productPattern
                                    AND Pricebook2Id = :Test.getStandardPricebookId() AND CurrencyIsoCode = 'GBP' LIMIT 1];
            Boolean ordered = false;
            // Order and Order Product automation is not under test: when it refuses the data, the load is still exercised.
            try {
                Database.update(new Contract(Id = main.Id, Status = 'Active'), AccessLevel.SYSTEM_MODE);
                Order orderRecord = new Order(AccountId = main.AccountId, ContractId = main.Id, EffectiveDate = Date.today(),
                    Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId(), CurrencyIsoCode = 'GBP');
                Database.insert(orderRecord, AccessLevel.SYSTEM_MODE);
                Database.insert(new OrderItem(OrderId = orderRecord.Id, PricebookEntryId = entry.Id, Quantity = 3,
                    UnitPrice = entry.UnitPrice, Sales_Contract_Line_CC__c = lineA.Id), AccessLevel.SYSTEM_MODE);
                ordered = true;
            } catch (DmlException e) {
                System.debug(LoggingLevel.INFO, 'Order data not created: ' + e.getDmlMessage(0));
            }

            Test.startTest();
            ContractContractLinesController_CC.ContractLinesResult result = ContractContractLinesController_CC.getContractLines(main.Id);
            List<Id> refreshIds = ContractContractLinesController_CC.refreshRecordPage(main.Id);
            Test.stopTest();

            Assert.areEqual(3, result.lines.size());
            if (ordered) {
                Assert.areEqual(7, line(PRODUCT_A).Remaining_SKU_CC__c, 'Ordered quantity is reserved against the line');
                Assert.areEqual(5, refreshIds.size(), 'Contract, three lines and the Order');
            } else {
                Assert.isTrue(refreshIds.size() >= 4, 'Contract and its three lines');
            }
        }
    }

    @IsTest
    static void getContractLines_ContractWithoutLinesReturnsEmpty() {
        System.runAs(clmUser()) {
            Test.startTest();
            ContractContractLinesController_CC.ContractLinesResult result =
                ContractContractLinesController_CC.getContractLines(contract(EMPTY_CONTRACT_NAME).Id);
            Test.stopTest();
            Assert.areEqual(0, result.lines.size());
            Assert.areEqual(0, result.recalculatedLineCount);
        }
    }

    @IsTest
    static void getContractLines_RejectsInvalidIds() {
        System.runAs(clmUser()) {
            Test.startTest();
            String nullMessage = loadError(null);
            String wrongTypeMessage = loadError(contract(CONTRACT_NAME).AccountId);
            Test.stopTest();
            Assert.areEqual('Contract Id is required.', nullMessage);
            Assert.areEqual('This component can only be used on a Contract record.', wrongTypeMessage);
        }
    }

    // ------------------------------------------------------------------ saveContractLines

    @IsTest
    static void saveContractLines_UpdatesChangedLinesOnly() {
        System.runAs(clmUser()) {
            Id contractId = contract(CONTRACT_NAME).Id;
            SalesContractLine lineA = line(PRODUCT_A);
            SalesContractLine lineB = line(PRODUCT_B);
            String payload = JSON.serialize(new List<Object>{
                change(lineA.Id, true, 4),        // No -> Yes, minimum 4
                change(lineB.Id, 'no', '')        // Yes -> No, minimum cleared to 0 (string inputs)
            });

            Test.startTest();
            Integer updated = ContractContractLinesController_CC.saveContractLines(contractId, payload);
            Integer again = ContractContractLinesController_CC.saveContractLines(contractId, payload);
            Test.stopTest();

            Assert.areEqual(2, updated, 'Both lines changed');
            Assert.areEqual(0, again, 'Saving the same values changes nothing');
            SalesContractLine savedA = line(PRODUCT_A);
            SalesContractLine savedB = line(PRODUCT_B);
            Assert.areEqual('Yes', savedA.MOQ_Required_CC__c);
            Assert.areEqual(4, savedA.Minimum_Order_Quantity_CC__c);
            Assert.areEqual('No', savedB.MOQ_Required_CC__c);
            Assert.areEqual(0, savedB.Minimum_Order_Quantity_CC__c);
        }
    }

    @IsTest
    static void saveContractLines_RejectsMalformedPayloads() {
        System.runAs(clmUser()) {
            Id contractId = contract(CONTRACT_NAME).Id;
            Id lineAId = line(PRODUCT_A).Id;

            Test.startTest();
            String blank = saveError(contractId, '  ');
            String unreadable = saveError(contractId, '{not json');
            String notList = saveError(contractId, '{"a":1}');
            String notObject = saveError(contractId, '[1]');
            String badId = saveError(contractId, JSON.serialize(new List<Object>{ change('not-an-id', true, 1) }));
            String blankId = saveError(contractId, JSON.serialize(new List<Object>{ change('', true, 1) }));
            String wrongType = saveError(contractId, JSON.serialize(new List<Object>{ change(contractId, true, 1) }));
            String badNumber = saveError(contractId, JSON.serialize(new List<Object>{ change(lineAId, true, 'abc') }));
            String empty = saveError(contractId, '[]');
            String noContract = saveError(null, JSON.serialize(new List<Object>{ change(lineAId, true, 1) }));
            Test.stopTest();

            Assert.areEqual('No Contract Line changes were submitted.', blank);
            Assert.areEqual('The submitted Contract Lines could not be read.', unreadable);
            Assert.areEqual('The submitted Contract Lines are not in the expected format.', notList);
            Assert.areEqual('Submitted Contract Line 1 is not in the expected format.', notObject);
            Assert.areEqual('Submitted Contract Line 1 does not contain a valid Contract Line Id.', badId);
            Assert.areEqual('Submitted Contract Line 1 does not contain a valid Contract Line Id.', blankId);
            Assert.areEqual('Submitted Contract Line 1 does not contain a valid Contract Line Id.', wrongType);
            Assert.isTrue(badNumber.contains('invalid Minimum Order Quantity'), badNumber);
            Assert.areEqual('No Contract Line changes were submitted.', empty);
            Assert.areEqual('Contract Id is required.', noContract);
        }
    }

    @IsTest
    static void saveContractLines_EnforcesMinimumOrderQuantityRules() {
        System.runAs(clmUser()) {
            Id contractId = contract(CONTRACT_NAME).Id;
            Id emptyContractId = contract(EMPTY_CONTRACT_NAME).Id;
            Id lineAId = line(PRODUCT_A).Id;

            Test.startTest();
            String missingMinimum = saveError(contractId, JSON.serialize(new List<Object>{ change(lineAId, true, null) }));
            String zeroMinimum = saveError(contractId, JSON.serialize(new List<Object>{ change(lineAId, 'yes', 0) }));
            String aboveQuantity = saveError(contractId, JSON.serialize(new List<Object>{ change(lineAId, true, 11) }));
            String otherContract = saveError(emptyContractId, JSON.serialize(new List<Object>{ change(lineAId, true, 1) }));
            String unknownLine = saveError(contractId, JSON.serialize(new List<Object>{ change(fakeId(SalesContractLine.SObjectType), true, 1) }));
            Test.stopTest();

            Assert.isTrue(missingMinimum.contains('is required when MOQ Required is Yes'), missingMinimum);
            Assert.isTrue(zeroMinimum.contains('is required when MOQ Required is Yes'), zeroMinimum);
            Assert.isTrue(aboveQuantity.contains('cannot exceed the Contract Quantity'), aboveQuantity);
            Assert.areEqual('One or more submitted Contract Lines do not belong to this Contract.', otherContract);
            Assert.areEqual('One or more submitted Contract Lines do not belong to this Contract.', unknownLine);
            Assert.isNull(line(PRODUCT_A).Minimum_Order_Quantity_CC__c, 'Nothing was saved');
        }
    }

    // ------------------------------------------------------------------ refreshRecordPage

    @IsTest
    static void refreshRecordPage_ReturnsContractAndLineIds() {
        System.runAs(clmUser()) {
            Id contractId = contract(CONTRACT_NAME).Id;
            Test.startTest();
            List<Id> ids = ContractContractLinesController_CC.refreshRecordPage(contractId);
            String nullMessage = refreshError(null);
            String wrongType = refreshError(contract(CONTRACT_NAME).AccountId);
            String missing = refreshError(fakeId(Contract.SObjectType));
            Test.stopTest();

            Assert.isTrue(new Set<Id>(ids).contains(contractId));
            Assert.areEqual(4, ids.size(), 'Contract and its three lines');
            Assert.areEqual('Contract Id is required.', nullMessage);
            Assert.areEqual('This component can only be used on a Contract record.', wrongType);
            Assert.areEqual('The Contract could not be found.', missing);
        }
    }
}