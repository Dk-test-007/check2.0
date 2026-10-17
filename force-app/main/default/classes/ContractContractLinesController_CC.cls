public without sharing class ContractContractLinesController_CC {
    private static final String STATUS_CANCELLED = 'Cancelled';
    private static final String TEXT_MOQ_REQUIRED_VALUE = 'true';
    private static final String TEXT_MOQ_NOT_REQUIRED_VALUE = 'false';
    private static final Decimal DEFAULT_MINIMUM_ORDER_QUANTITY = 0;
    private static final Set<String> MOQ_YES_TOKENS =
        new Set<String>{ 'true', 'yes', 'y', '1' };
    private static final Set<String> MOQ_NO_TOKENS =
        new Set<String>{ 'false', 'no', 'n', '0' };
    private static Boolean moqValuesResolved = false;
    private static Boolean moqIsPicklist = false;
    private static String moqYesValue;
    private static String moqNoValue;
    private static List<String> moqAvailableValues = new List<String>();
    private static Set<String> cancelledStatusValues;
    private static final String DEFAULT_PRODUCT_NAME = 'Product';
    private static final String KEY_CONTRACT_LINE_ID = 'contractLineId';
    private static final String KEY_MOQ_REQUIRED = 'moqRequired';
    private static final String KEY_MINIMUM_ORDER_QUANTITY = 'minimumOrderQuantity';
    public class ContractLineWrapper {
        @AuraEnabled public Id contractLineId { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Boolean moqRequired { get; set; }
        @AuraEnabled public Decimal minimumOrderQuantity { get; set; }
    }
    public class ContractLinesResult {
        @AuraEnabled public Integer recalculatedLineCount { get; set; }
        @AuraEnabled public List<ContractLineWrapper> lines { get; set; }
    }
    private class LineChange {
        Boolean moqRequired;
        Decimal minimumOrderQuantity;
    }
    @AuraEnabled
    public static ContractLinesResult getContractLines(Id contractId) {
        try {
            return loadContractLines(contractId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw buildError(e.getDmlMessage(0));
        } catch (Exception e) {
            throw buildError(e.getMessage());
        }
    }
    private static ContractLinesResult loadContractLines(Id contractId) {
        validateContractId(contractId);
        ContractLinesResult result = new ContractLinesResult();
        result.recalculatedLineCount = 0;
        result.lines = new List<ContractLineWrapper>();
        List<SalesContractLine> lockedLines = [ SELECT Id, Quantity, Remaining_SKU_CC__c FROM SalesContractLine WHERE ContractId = :contractId WITH SYSTEM_MODE FOR UPDATE ];
        if (lockedLines.isEmpty())  return result;
        result.recalculatedLineCount = recalculateRemainingSku(lockedLines);
        List<SalesContractLine> contractLines = [ SELECT Id, ContractId, Product2Id, Product2.Name, Quantity, MOQ_Required_CC__c, Minimum_Order_Quantity_CC__c FROM SalesContractLine WHERE ContractId = :contractId WITH SYSTEM_MODE ORDER BY CreatedDate ];
        for (SalesContractLine line : contractLines) {
            ContractLineWrapper wrapper = new ContractLineWrapper();
            wrapper.contractLineId = line.Id;
            wrapper.productId = line.Product2Id;
            wrapper.productName = getProductName(line);
            wrapper.quantity = line.Quantity;
            wrapper.moqRequired = isMoqRequired(line.MOQ_Required_CC__c);
            wrapper.minimumOrderQuantity = wrapper.moqRequired
                ? line.Minimum_Order_Quantity_CC__c
                : DEFAULT_MINIMUM_ORDER_QUANTITY;
            result.lines.add(wrapper);
        }
        return result;
    }
    @AuraEnabled
    public static Integer saveContractLines(Id contractId, String linesJson) {
        try {
            return processSave(contractId, parseLineChanges(linesJson));
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw buildError(e.getDmlMessage(0));
        } catch (Exception e) {
            throw buildError(e.getMessage());
        }
    }
    private static Integer processSave(Id contractId, Map<Id, LineChange> changes) {
        validateContractId(contractId);
        if (changes.isEmpty())  throw buildError('No Contract Line changes were submitted.');
        Set<Id> submittedLineIds = changes.keySet();
        Map<Id, SalesContractLine> linesById = new Map<Id, SalesContractLine>([ SELECT Id, Product2.Name, Quantity, MOQ_Required_CC__c, Minimum_Order_Quantity_CC__c FROM SalesContractLine WHERE Id IN :submittedLineIds AND ContractId = :contractId WITH SYSTEM_MODE FOR UPDATE ]);
        if (linesById.size() != submittedLineIds.size()) {
            throw buildError(
                'One or more submitted Contract Lines do not belong to this Contract.'
            );
        }
        List<SalesContractLine> linesToUpdate = new List<SalesContractLine>();
        for (Id contractLineId : submittedLineIds) {
            SalesContractLine line = linesById.get(contractLineId);
            LineChange change = changes.get(contractLineId);
            String newMoqValue = getMoqStoredValue(change.moqRequired);
            String productName = getProductName(line);
            Decimal newMinimum = change.moqRequired
                ? change.minimumOrderQuantity
                : DEFAULT_MINIMUM_ORDER_QUANTITY;
            if (change.moqRequired) {
                if (newMinimum == null || newMinimum <= 0) {
                    throw buildError(
                        'Minimum Order Quantity for ' + productName +
                        ' is required when MOQ Required is Yes and must be greater than 0.'
                    );
                }
                if (line.Quantity != null && newMinimum > line.Quantity) {
                    throw buildError(
                        'Minimum Order Quantity for ' + productName +
                        ' cannot exceed the Contract Quantity (' + line.Quantity + ').'
                    );
                }
            }
            Boolean currentRequired = isMoqRequired(line.MOQ_Required_CC__c);
            Boolean isUnchanged =
                currentRequired == change.moqRequired &&
                line.Minimum_Order_Quantity_CC__c == newMinimum;
            if (isUnchanged)  continue;
            linesToUpdate.add(
                new SalesContractLine(
                    Id = line.Id,
                    MOQ_Required_CC__c = newMoqValue,
                    Minimum_Order_Quantity_CC__c = newMinimum
                )
            );
        }
        if (!linesToUpdate.isEmpty()) {
            checkSaveResults(
                Database.update(linesToUpdate, AccessLevel.SYSTEM_MODE)
            );
        }
        return linesToUpdate.size();
    }
    private static Map<Id, LineChange> parseLineChanges(String linesJson) {
        if (String.isBlank(linesJson))  throw buildError('No Contract Line changes were submitted.');
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(linesJson);
        } catch (Exception e) {
            throw buildError('The submitted Contract Lines could not be read.');
        }
        if (!(parsed instanceof List<Object>))  throw buildError('The submitted Contract Lines are not in the expected format.');
        Map<Id, LineChange> changes = new Map<Id, LineChange>();
        Integer position = 0;
        for (Object rawLine : (List<Object>) parsed) {
            position++;
            if (!(rawLine instanceof Map<String, Object>)) {
                throw buildError(
                    'Submitted Contract Line ' + position + ' is not in the expected format.'
                );
            }
            Map<String, Object> values = (Map<String, Object>) rawLine;
            Id contractLineId = toId(values.get(KEY_CONTRACT_LINE_ID));
            if (
                contractLineId == null ||
                contractLineId.getSObjectType() != SalesContractLine.SObjectType
            ) {
                throw buildError(
                    'Submitted Contract Line ' + position +
                    ' does not contain a valid Contract Line Id.'
                );
            }
            LineChange change = new LineChange();
            change.moqRequired = toBoolean(values.get(KEY_MOQ_REQUIRED));
            change.minimumOrderQuantity =
                toDecimal(values.get(KEY_MINIMUM_ORDER_QUANTITY), position);
            changes.put(contractLineId, change);
        }
        return changes;
    }
    @AuraEnabled
    public static List<Id> refreshRecordPage(Id contractId) {
        try {
            validateContractId(contractId);
            List<Contract> contracts = [ SELECT Id FROM Contract WHERE Id = :contractId WITH SYSTEM_MODE FOR UPDATE ];
            if (contracts.isEmpty())  throw buildError('The Contract could not be found.');
            checkSaveResults(
                Database.update(
                    new List<Contract>{ new Contract(Id = contractId) },
                    AccessLevel.SYSTEM_MODE
                )
            );
            Set<Id> recordIds = new Set<Id>{ contractId };
            for (SalesContractLine line : [ SELECT Id FROM SalesContractLine WHERE ContractId = :contractId WITH SYSTEM_MODE ]) {
                recordIds.add(line.Id);
            }
            for (Order orderRecord : [ SELECT Id FROM Order WHERE ContractId = :contractId WITH SYSTEM_MODE ]) {
                recordIds.add(orderRecord.Id);
            }
            return new List<Id>(recordIds);
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw buildError(e.getDmlMessage(0));
        } catch (Exception e) {
            throw buildError(e.getMessage());
        }
    }
    private static Integer recalculateRemainingSku(List<SalesContractLine> lockedLines) {
        Set<Id> lineIds = new Map<Id, SalesContractLine>(lockedLines).keySet();
        Map<Id, Decimal> reservedByLine = getReservedQuantities(lineIds);
        List<SalesContractLine> linesToUpdate = new List<SalesContractLine>();
        for (SalesContractLine line : lockedLines) {
            Decimal recalculatedRemaining =
                nullToZero(line.Quantity) - nullToZero(reservedByLine.get(line.Id));
            if (line.Remaining_SKU_CC__c != recalculatedRemaining) {
                linesToUpdate.add(
                    new SalesContractLine(
                        Id = line.Id,
                        Remaining_SKU_CC__c = recalculatedRemaining
                    )
                );
            }
        }
        if (!linesToUpdate.isEmpty()) {
            checkSaveResults(
                Database.update(linesToUpdate, AccessLevel.SYSTEM_MODE)
            );
        }
        return linesToUpdate.size();
    }
    private static Map<Id, Decimal> getReservedQuantities(Set<Id> contractLineIds) {
        Map<Id, Decimal> reservedByLine = new Map<Id, Decimal>();
        Set<String> cancelledStatuses = getCancelledStatusValues();
        for (AggregateResult result : [ SELECT Sales_Contract_Line_CC__c lineId, SUM(Quantity) reservedQuantity FROM OrderItem WHERE Sales_Contract_Line_CC__c IN :contractLineIds AND Order.Status NOT IN :cancelledStatuses WITH SYSTEM_MODE GROUP BY Sales_Contract_Line_CC__c ]) {
            reservedByLine.put(
                (Id) result.get('lineId'),
                nullToZero((Decimal) result.get('reservedQuantity'))
            );
        }
        return reservedByLine;
    }
    private static Set<String> getCancelledStatusValues() {
        if (cancelledStatusValues != null)  return cancelledStatusValues;
        cancelledStatusValues = new Set<String>{ STATUS_CANCELLED };
        for (Schema.PicklistEntry entry : Schema.Order.Status.getDescribe().getPicklistValues()) {
            if (normalise(entry.getValue()).contains('cancel') || normalise(entry.getLabel()).contains('cancel'))  cancelledStatusValues.add(entry.getValue());
        }
        return cancelledStatusValues;
    }
    private static void resolveMoqValues() {
        if (moqValuesResolved)  return;
        Schema.DescribeFieldResult fieldDescribe =
            Schema.SalesContractLine.MOQ_Required_CC__c.getDescribe();
        Schema.DisplayType fieldType = fieldDescribe.getType();
        moqIsPicklist =
            fieldType == Schema.DisplayType.PICKLIST ||
            fieldType == Schema.DisplayType.MULTIPICKLIST;
        if (moqIsPicklist) {
            for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
                if (!entry.isActive())  continue;
                moqAvailableValues.add(entry.getValue());
                String value = normalise(entry.getValue());
                String label = normalise(entry.getLabel());
                if (
                    moqYesValue == null &&
                    (MOQ_YES_TOKENS.contains(value) || MOQ_YES_TOKENS.contains(label))
                ) {
                    moqYesValue = entry.getValue();
                } else if (
                    moqNoValue == null &&
                    (MOQ_NO_TOKENS.contains(value) || MOQ_NO_TOKENS.contains(label))
                ) {
                    moqNoValue = entry.getValue();
                }
            }
        } else {
            moqYesValue = TEXT_MOQ_REQUIRED_VALUE;
            moqNoValue = TEXT_MOQ_NOT_REQUIRED_VALUE;
        }
        moqValuesResolved = true;
    }
    private static Boolean isMoqRequired(String storedValue) {
        if (String.isBlank(storedValue))  return false;
        resolveMoqValues();
        if (moqYesValue != null)  return storedValue.trim().equalsIgnoreCase(moqYesValue);
        return MOQ_YES_TOKENS.contains(normalise(storedValue));
    }
    private static String getMoqStoredValue(Boolean moqRequired) {
        resolveMoqValues();
        if (moqRequired) {
            if (moqYesValue == null) {
                throw buildError(
                    'MOQ Required has no active picklist value meaning Yes. ' +
                    'Available values: ' + String.join(moqAvailableValues, ', ') + '.'
                );
            }
            return moqYesValue;
        }
        return moqNoValue;
    }
    private static String normalise(String value) {
        return value == null ? '' : value.trim().toLowerCase();
    }
    private static void validateContractId(Id contractId) {
        if (contractId == null)  throw buildError('Contract Id is required.');
        if (contractId.getSObjectType() != Contract.SObjectType)  throw buildError('This component can only be used on a Contract record.');
    }
    private static Id toId(Object value) {
        if (value == null)  return null;
        String candidate = String.valueOf(value).trim();
        if (String.isBlank(candidate))  return null;
        try {
            return Id.valueOf(candidate);
        } catch (Exception e) {
            return null;
        }
    }
    private static Boolean toBoolean(Object value) {
        if (value instanceof Boolean)  return (Boolean) value;
        return value != null && MOQ_YES_TOKENS.contains(normalise(String.valueOf(value)));
    }
    private static Decimal toDecimal(Object value, Integer position) {
        if (value == null)  return null;
        String candidate = String.valueOf(value).trim();
        if (String.isBlank(candidate))  return null;
        try {
            return Decimal.valueOf(candidate);
        } catch (Exception e) {
            throw buildError(
                'Submitted Contract Line ' + position +
                ' has an invalid Minimum Order Quantity: ' + candidate + '.'
            );
        }
    }
    private static void checkSaveResults(List<Database.SaveResult> results) {
        for (Database.SaveResult result : results) {
            if (!result.isSuccess())  throw buildError(result.getErrors()[0].getMessage());
        }
    }
    private static String getProductName(SalesContractLine line) {
        return line != null && line.Product2 != null && line.Product2.Name != null
            ? line.Product2.Name
            : DEFAULT_PRODUCT_NAME;
    }
    private static Decimal nullToZero(Decimal value) {
        return value == null ? 0 : value;
    }
    private static AuraHandledException buildError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}