/**
 * Controller for the orderContractLines_CC LWC.
 *
 * Manages OrderItems on a Draft, Contract-based Order from the Contract's
 * SalesContractLine records, keeps SalesContractLine.Remaining_SKU_CC__c in
 * line with the quantities actually reserved, and stamps the Contract Line's
 * MOQ settings onto each OrderItem.
 *
 * Standard Sales objects only. No CPQ, no RCA. No triggers: every
 * recalculation is driven from the LWC.
 *
 * RESERVATION MODEL (recalculation, not incremental arithmetic)
 * ------------------------------------------------------------
 *   Remaining_SKU_CC__c =
 *       SalesContractLine.Quantity
 *     - SUM(OrderItem.Quantity)
 *         WHERE OrderItem.Sales_Contract_Line_CC__c = line
 *         AND   OrderItem.Order.Status is NOT a cancelled status
 *
 * "Cancelled status" = every Order.Status picklist value whose API value or
 * label contains "cancel" (Cancelled, Canceled, Cancelled by Customer, ...),
 * read from the field describe. The label shown on the page is not always
 * the stored API value, so matching only the literal 'Cancelled' could leave
 * a cancelled Order still reserving quantity.
 *
 * Cancelled Orders stop reserving quantity. The value is recalculated from
 * source records, so running it repeatedly gives the same result and quantity
 * can never be released twice. Recalculation runs for ALL Sales Contract
 * Lines of the Order's Contract:
 *   - getContractLines()  every time the LWC loads, including when the LWC
 *                         detects that the Order Status changed
 *   - saveOrderLines()    after OrderItems are inserted/updated/deleted
 *   - cancelOrder()       "Cancel Order" button on the LWC: sets the Order
 *                         Status to Cancelled and recalculates in the same
 *                         transaction, exactly like saveOrderLines(), so the
 *                         Sales Contract Line related list shows the released
 *                         quantity straight away
 *
 * CONTRACT PAGE SYNC
 * ------------------
 * Whenever a recalculation changes Remaining SKU, the parent Contract is
 * given a new record version (no-field update, best effort). Lightning then
 * sees the Contract as changed, so the Contract record page and its Sales
 * Contract Line related list show the released / reserved quantities without
 * opening the Contract LWC. A Contract validation rule that blocks the
 * no-field update does not block the Order save.
 *
 * MOQ VALIDATION (per Contract Line)
 * ----------------------------------
 *   RQ = Requested Order Quantity, EQ = Existing Order Quantity (this Order)
 *   Available SKU = Remaining SKU + EQ
 *   1. RQ > Available SKU                       -> ERROR
 *   2. MOQ Required = No                        -> PASS
 *   3. RQ = 0 (remove the OrderItem)            -> PASS (MOQ not evaluated)
 *   4. Minimum Order Quantity missing or <= 0   -> ERROR (invalid MOQ setup)
 *   5. RQ < Minimum Order Quantity              -> ERROR
 *   6. otherwise                                -> PASS
 *
 * MOQ_Required_CC__c on SalesContractLine is a RESTRICTED PICKLIST. Its "Yes"
 * value is resolved at runtime from the field describe (value or label
 * matching true / yes / y / 1, case-insensitive), so MOQ is detected
 * correctly whatever the picklist API names are.
 *
 * ORDERITEM MOQ SNAPSHOT
 * ----------------------
 * On every OrderItem insert/update the Contract Line's MOQ settings are
 * copied to OrderItem.MOQ_Required_CC__c and
 * OrderItem.Minimum_Order_Quantity_CC__c. The OrderItem field types are read
 * from the describe (Checkbox, Picklist or Text for MOQ Required; Number or
 * Text for Minimum Order Quantity), so the correct value type is written.
 *
 * Save payload (sent by the LWC as a JSON string):
 *   [ { "contractLineId": "<SalesContractLine.Id>", "orderQuantity": 3 } ]
 */
public without sharing class OrderContractLineController_CC {
    private static final String STATUS_DRAFT = 'Draft';
    private static final String STATUS_CANCELLED = 'Cancelled';
    private static final String DEFAULT_PRODUCT_NAME = 'Product';
    private static final String KEY_CONTRACT_LINE_ID = 'contractLineId';
    private static final String KEY_ORDER_QUANTITY = 'orderQuantity';
    private static final String TEXT_MOQ_REQUIRED_VALUE = 'true';
    private static final String TEXT_MOQ_NOT_REQUIRED_VALUE = 'false';
    private static final Set<String> MOQ_YES_TOKENS =
        new Set<String>{ 'true', 'yes', 'y', '1' };
    private static final Set<String> MOQ_NO_TOKENS =
        new Set<String>{ 'false', 'no', 'n', '0' };
    private static Boolean lineMoqResolved = false;
    private static String lineMoqYesValue;
    private static Boolean orderItemMoqResolved = false;
    private static Schema.DisplayType orderItemMoqType;
    private static Schema.DisplayType orderItemMinimumType;
    private static String orderItemMoqYesValue;
    private static String orderItemMoqNoValue;
    private static List<String> orderItemMoqAvailableValues = new List<String>();
    private static Set<String> cancelledStatusValues;
    public class ContractLineWrapper {
        @AuraEnabled public String rowId { get; set; }
        @AuraEnabled public Id contractLineId { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal remainingSKU { get; set; }
        @AuraEnabled public Boolean moqRequired { get; set; }
        @AuraEnabled public Decimal minimumOrderQuantity { get; set; }
        @AuraEnabled public Decimal orderQuantity { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public String description { get; set; }
    }
    public class ContractLinesResult {
        @AuraEnabled public String orderStatus { get; set; }
        @AuraEnabled public Boolean isEditable { get; set; }
        @AuraEnabled public Boolean isCancelled { get; set; }
        @AuraEnabled public Boolean canCancel { get; set; }
        @AuraEnabled public Integer recalculatedLineCount { get; set; }
        @AuraEnabled public List<ContractLineWrapper> lines { get; set; }
    }
    @AuraEnabled
    public static ContractLinesResult getContractLines(Id orderId) {
        try {
            return loadContractLines(orderId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw buildError(e.getDmlMessage(0));
        } catch (Exception e) {
            throw buildError(e.getMessage());
        }
    }
    private static ContractLinesResult loadContractLines(Id orderId) {
        if (orderId == null) throw buildError('Order Id is required.');
        List<Order> orders = [SELECT Id, Status, ContractId FROM Order WHERE Id = :orderId WITH SYSTEM_MODE LIMIT 1];
        if (orders.isEmpty()) throw buildError('The Order could not be found.');
        Order orderRecord = orders[0];
        if (orderRecord.ContractId == null) throw buildError('This Order is not created from a Contract.');
        Integer recalculatedLineCount =
            recalculateRemainingSkuForContract(orderRecord.ContractId);
        List<SalesContractLine> contractLines = [SELECT Id, ContractId, QuoteLineItemId, Product2Id, Product2.Name, Quantity, Remaining_SKU_CC__c, MOQ_Required_CC__c, Minimum_Order_Quantity_CC__c, UnitPrice, Description FROM SalesContractLine WHERE ContractId = :orderRecord.ContractId WITH SYSTEM_MODE ORDER BY CreatedDate];
        Map<Id, Decimal> orderQuantities = new Map<Id, Decimal>();
        for (OrderItem orderItem : [SELECT Id, Quantity, Sales_Contract_Line_CC__c FROM OrderItem WHERE OrderId = :orderId AND Sales_Contract_Line_CC__c != null WITH SYSTEM_MODE]) {
            Id lineId = orderItem.Sales_Contract_Line_CC__c;
            Decimal current = orderQuantities.containsKey(lineId)
                ? orderQuantities.get(lineId)
                : 0;
            orderQuantities.put(lineId, current + nullToZero(orderItem.Quantity));
        }
        List<ContractLineWrapper> wrappers = new List<ContractLineWrapper>();
        for (SalesContractLine line : contractLines) {
            ContractLineWrapper wrapper = new ContractLineWrapper();
            Boolean moqRequired = isMoqRequired(line.MOQ_Required_CC__c);
            wrapper.rowId = String.valueOf(line.Id);
            wrapper.contractLineId = line.Id;
            wrapper.productId = line.Product2Id;
            wrapper.productName = getProductName(line);
            wrapper.quantity = line.Quantity;
            wrapper.remainingSKU = nullToZero(line.Remaining_SKU_CC__c);
            wrapper.moqRequired = moqRequired;
            wrapper.minimumOrderQuantity = moqRequired
                ? line.Minimum_Order_Quantity_CC__c
                : null;
            wrapper.orderQuantity = orderQuantities.containsKey(line.Id)
                ? orderQuantities.get(line.Id)
                : 0;
            wrapper.unitPrice = line.UnitPrice;
            wrapper.description = line.Description;
            wrappers.add(wrapper);
        }
        ContractLinesResult result = new ContractLinesResult();
        result.orderStatus = orderRecord.Status;
        result.isEditable = orderRecord.Status == STATUS_DRAFT;
        result.isCancelled = isCancelledStatus(orderRecord.Status);
        result.canCancel = !result.isCancelled;
        result.recalculatedLineCount = recalculatedLineCount;
        result.lines = wrappers;
        return result;
    }
    @AuraEnabled
    public static Integer saveOrderLines(Id orderId, String selectedLinesJson) {
        try {
            return processSave(orderId, parseRequestedQuantities(selectedLinesJson));
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw buildError(e.getDmlMessage(0));
        } catch (Exception e) {
            throw buildError(e.getMessage());
        }
    }
    private static Integer processSave(Id orderId, Map<Id, Decimal> requestedQuantities) {
        if (orderId == null) throw buildError('Order Id is required.');
        if (requestedQuantities == null || requestedQuantities.isEmpty()) throw buildError('No valid Contract Lines were submitted.');
        Set<Id> submittedLineIds = requestedQuantities.keySet();
        List<Order> orders = [SELECT Id, Status, ContractId, Pricebook2Id, Contract.Pricebook2Id FROM Order WHERE Id = :orderId WITH SYSTEM_MODE FOR UPDATE];
        if (orders.isEmpty()) throw buildError('The Order could not be found.');
        Order orderRecord = orders[0];
        if (orderRecord.ContractId == null) throw buildError('This Order is not created from a Contract.');
        if (orderRecord.Status != STATUS_DRAFT) {
            throw buildError(
                'Order Lines can only be managed while the Order is in Draft status.'
            );
        }
        Map<Id, SalesContractLine> linesById = new Map<Id, SalesContractLine>([SELECT Id, ContractId, Product2Id, Product2.Name, Quantity, Remaining_SKU_CC__c, MOQ_Required_CC__c, Minimum_Order_Quantity_CC__c, UnitPrice, Description FROM SalesContractLine WHERE ContractId = :orderRecord.ContractId WITH SYSTEM_MODE FOR UPDATE]);
        for (Id contractLineId : submittedLineIds) {
            if (!linesById.containsKey(contractLineId)) {
                throw buildError(
                    'One or more submitted Contract Lines do not belong to this Contract.'
                );
            }
        }
        List<OrderItem> existingOrderItems = [SELECT Id, Quantity, PricebookEntryId, Sales_Contract_Line_CC__c FROM OrderItem WHERE OrderId = :orderId AND Sales_Contract_Line_CC__c IN :submittedLineIds WITH SYSTEM_MODE FOR UPDATE];
        Map<Id, OrderItem> existingItemsByLine = new Map<Id, OrderItem>();
        for (OrderItem orderItem : existingOrderItems) {
            Id lineId = orderItem.Sales_Contract_Line_CC__c;
            if (existingItemsByLine.containsKey(lineId)) {
                throw buildError(
                    'More than one Order Product is linked to the Contract Line for ' +
                    getProductName(linesById.get(lineId)) +
                    '. Remove the duplicate Order Product before saving.'
                );
            }
            existingItemsByLine.put(lineId, orderItem);
        }
        Map<Id, Decimal> reservedByLine = getReservedQuantities(submittedLineIds);
        List<OrderItem> orderItemsToUpdate = new List<OrderItem>();
        List<OrderItem> orderItemsToDelete = new List<OrderItem>();
        List<SalesContractLine> linesRequiringInsert = new List<SalesContractLine>();
        Set<Id> productIdsToInsert = new Set<Id>();
        for (Id contractLineId : submittedLineIds) {
            SalesContractLine line = linesById.get(contractLineId);
            Decimal requestedQuantity = requestedQuantities.get(contractLineId);
            OrderItem existingOrderItem = existingItemsByLine.get(contractLineId);
            Decimal existingQuantity = existingOrderItem == null
                ? 0
                : nullToZero(existingOrderItem.Quantity);
            if (requestedQuantity == existingQuantity) continue;
            Decimal remainingSKU =
                nullToZero(line.Quantity) - nullToZero(reservedByLine.get(contractLineId));
            Decimal availableSKU = remainingSKU + existingQuantity;
            validateRequestedQuantity(line, requestedQuantity, availableSKU);
            if (requestedQuantity == 0) {
                orderItemsToDelete.add(new OrderItem(Id = existingOrderItem.Id));
                continue;
            }
            if (existingOrderItem != null) {
                OrderItem itemToUpdate = new OrderItem(
                    Id = existingOrderItem.Id,
                    Quantity = requestedQuantity,
                    Description = line.Description
                );
                if (line.UnitPrice != null) itemToUpdate.UnitPrice = line.UnitPrice;
                stampMoqSnapshot(itemToUpdate, line);
                orderItemsToUpdate.add(itemToUpdate);
                continue;
            }
            if (line.Product2Id == null) {
                throw buildError(
                    'No Product is defined on the Contract Line for ' +
                    getProductName(line) + '.'
                );
            }
            linesRequiringInsert.add(line);
            productIdsToInsert.add(line.Product2Id);
        }
        Id pricebookId = orderRecord.Pricebook2Id != null
            ? orderRecord.Pricebook2Id
            : orderRecord.Contract.Pricebook2Id;
        Map<Id, PricebookEntry> entriesByProduct = new Map<Id, PricebookEntry>();
        if (!productIdsToInsert.isEmpty()) {
            if (pricebookId == null) {
                throw buildError(
                    'A Price Book is required on the Order or its Contract before Order Lines can be created.'
                );
            }
            for (PricebookEntry entry : [SELECT Id, Product2Id, UnitPrice FROM PricebookEntry WHERE Pricebook2Id = :pricebookId AND Product2Id IN :productIdsToInsert AND IsActive = true WITH SYSTEM_MODE]) {
                entriesByProduct.put(entry.Product2Id, entry);
            }
        }
        List<OrderItem> orderItemsToInsert = new List<OrderItem>();
        for (SalesContractLine line : linesRequiringInsert) {
            PricebookEntry entry = entriesByProduct.get(line.Product2Id);
            if (entry == null) {
                throw buildError(
                    'No active Price Book Entry exists for ' +
                    getProductName(line) + ' in the Order Price Book.'
                );
            }
            OrderItem itemToInsert = new OrderItem(
                OrderId = orderId,
                PricebookEntryId = entry.Id,
                Quantity = requestedQuantities.get(line.Id),
                UnitPrice = line.UnitPrice != null ? line.UnitPrice : entry.UnitPrice,
                Description = line.Description,
                Sales_Contract_Line_CC__c = line.Id
            );
            stampMoqSnapshot(itemToInsert, line);
            orderItemsToInsert.add(itemToInsert);
        }
        if (!orderItemsToDelete.isEmpty()) {
            checkDeleteResults(
                Database.delete(orderItemsToDelete, AccessLevel.SYSTEM_MODE)
            );
        }
        if (!orderItemsToUpdate.isEmpty()) {
            checkSaveResults(
                Database.update(orderItemsToUpdate, AccessLevel.SYSTEM_MODE)
            );
        }
        if (!orderItemsToInsert.isEmpty()) {
            if (orderRecord.Pricebook2Id == null) {
                checkSaveResults(
                    Database.update(
                        new List<Order>{
                            new Order(Id = orderId, Pricebook2Id = pricebookId)
                        },
                        AccessLevel.SYSTEM_MODE
                    )
                );
            }
            checkSaveResults(
                Database.insert(orderItemsToInsert, AccessLevel.SYSTEM_MODE)
            );
        }
        applyRemainingSkuRecalculation(linesById.values());
        verifyOrderItems(orderId, requestedQuantities);
        return orderItemsToInsert.size() +
            orderItemsToUpdate.size() +
            orderItemsToDelete.size();
    }
    @AuraEnabled
    public static List<Id> getRefreshRecordIds(Id orderId) {
        try {
            if (orderId == null) throw buildError('Order Id is required.');
            List<Order> orders = [SELECT Id, ContractId FROM Order WHERE Id = :orderId WITH SYSTEM_MODE LIMIT 1];
            if (orders.isEmpty()) return new List<Id>();
            Order orderRecord = orders[0];
            Set<Id> recordIds = new Set<Id>{ orderRecord.Id };
            for (OrderItem orderItem : [SELECT Id FROM OrderItem WHERE OrderId = :orderId WITH SYSTEM_MODE]) {
                recordIds.add(orderItem.Id);
            }
            if (orderRecord.ContractId != null) {
                recordIds.add(orderRecord.ContractId);
                for (SalesContractLine line : [SELECT Id FROM SalesContractLine WHERE ContractId = :orderRecord.ContractId WITH SYSTEM_MODE]) {
                    recordIds.add(line.Id);
                }
            }
            return new List<Id>(recordIds);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw buildError(e.getMessage());
        }
    }
    @AuraEnabled
    public static Integer cancelOrder(Id orderId) {
        try {
            return processCancel(orderId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw buildError(e.getDmlMessage(0));
        } catch (Exception e) {
            throw buildError(e.getMessage());
        }
    }
    private static Integer processCancel(Id orderId) {
        if (orderId == null) throw buildError('Order Id is required.');
        List<Order> orders = [SELECT Id, Status, ContractId FROM Order WHERE Id = :orderId WITH SYSTEM_MODE FOR UPDATE];
        if (orders.isEmpty()) throw buildError('The Order could not be found.');
        Order orderRecord = orders[0];
        if (orderRecord.ContractId == null) throw buildError('This Order is not created from a Contract.');
        List<SalesContractLine> lockedLines = lockContractLines(orderRecord.ContractId);
        if (!isCancelledStatus(orderRecord.Status)) {
            checkSaveResults(
                Database.update(
                    new List<Order>{
                        new Order(Id = orderId, Status = getCancelStatusToWrite())
                    },
                    AccessLevel.SYSTEM_MODE
                )
            );
        }
        return applyRemainingSkuRecalculation(lockedLines);
    }
    private static Integer recalculateRemainingSkuForContract(Id contractId) {
        return applyRemainingSkuRecalculation(lockContractLines(contractId));
    }
    private static List<SalesContractLine> lockContractLines(Id contractId) {
        return [SELECT Id, ContractId, Quantity, Remaining_SKU_CC__c FROM SalesContractLine WHERE ContractId = :contractId WITH SYSTEM_MODE FOR UPDATE];
    }
    private static Integer applyRemainingSkuRecalculation(List<SalesContractLine> lockedLines) {
        if (lockedLines == null || lockedLines.isEmpty()) return 0;
        Set<Id> lineIds = new Map<Id, SalesContractLine>(lockedLines).keySet();
        Map<Id, Decimal> reservedByLine = getReservedQuantities(lineIds);
        List<SalesContractLine> linesToUpdate = new List<SalesContractLine>();
        Set<Id> changedContractIds = new Set<Id>();
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
                if (line.ContractId != null) changedContractIds.add(line.ContractId);
            }
        }
        if (!linesToUpdate.isEmpty()) {
            checkSaveResults(
                Database.update(linesToUpdate, AccessLevel.SYSTEM_MODE)
            );
            touchContracts(changedContractIds);
        }
        return linesToUpdate.size();
    }
    private static void touchContracts(Set<Id> contractIds) {
        if (contractIds == null || contractIds.isEmpty()) return;
        List<Contract> contractsToTouch = new List<Contract>();
        for (Id contractId : contractIds) {
            contractsToTouch.add(new Contract(Id = contractId));
        }
        Database.update(contractsToTouch, false, AccessLevel.SYSTEM_MODE);
    }
    private static Map<Id, Decimal> getReservedQuantities(Set<Id> contractLineIds) {
        Map<Id, Decimal> reservedByLine = new Map<Id, Decimal>();
        if (contractLineIds == null || contractLineIds.isEmpty()) return reservedByLine;
        Set<String> cancelledStatuses = getCancelledStatusValues();
        for (AggregateResult result : [SELECT Sales_Contract_Line_CC__c lineId, SUM(Quantity) reservedQuantity FROM OrderItem WHERE Sales_Contract_Line_CC__c IN :contractLineIds AND Order.Status NOT IN :cancelledStatuses WITH SYSTEM_MODE GROUP BY Sales_Contract_Line_CC__c]) {
            reservedByLine.put(
                (Id) result.get('lineId'),
                nullToZero((Decimal) result.get('reservedQuantity'))
            );
        }
        return reservedByLine;
    }
    private static Set<String> getCancelledStatusValues() {
        if (cancelledStatusValues != null) return cancelledStatusValues;
        cancelledStatusValues = new Set<String>{ STATUS_CANCELLED };
        for (Schema.PicklistEntry entry : Schema.Order.Status.getDescribe().getPicklistValues()) {
            if (normalise(entry.getValue()).contains('cancel') || normalise(entry.getLabel()).contains('cancel')) cancelledStatusValues.add(entry.getValue());
        }
        return cancelledStatusValues;
    }
    private static String getCancelStatusToWrite() {
        String firstCancelValue;
        for (Schema.PicklistEntry entry : Schema.Order.Status.getDescribe().getPicklistValues()) {
            if (!entry.isActive()) continue;
            if (entry.getValue().equalsIgnoreCase(STATUS_CANCELLED)) return entry.getValue();
            if (firstCancelValue == null && (normalise(entry.getValue()).contains('cancel') || normalise(entry.getLabel()).contains('cancel'))) firstCancelValue = entry.getValue();
        }
        if (firstCancelValue == null) throw buildError('The Order Status picklist has no active Cancelled value.');
        return firstCancelValue;
    }
    private static Boolean isCancelledStatus(String status) {
        if (String.isBlank(status)) return false;
        for (String cancelledStatus : getCancelledStatusValues()) {
            if (cancelledStatus.equalsIgnoreCase(status.trim())) return true;
        }
        return false;
    }
    private static void validateRequestedQuantity(
        SalesContractLine line,
        Decimal requestedQuantity,
        Decimal availableSKU
    ) {
        String productName = getProductName(line);
        if (requestedQuantity > availableSKU) {
            throw buildError(
                'Order Quantity for ' + productName +
                ' cannot exceed the available Remaining SKU. Available: ' +
                availableSKU + '.'
            );
        }
        if (!isMoqRequired(line.MOQ_Required_CC__c)) return;
        if (requestedQuantity == 0) return;
        Decimal minimumOrderQuantity = line.Minimum_Order_Quantity_CC__c;
        if (minimumOrderQuantity == null || minimumOrderQuantity <= 0) {
            throw buildError(
                'Minimum Order Quantity must be defined for ' + productName +
                ' because MOQ is required.'
            );
        }
        if (requestedQuantity < minimumOrderQuantity) {
            throw buildError(
                'Order Quantity for ' + productName +
                ' must be at least ' + minimumOrderQuantity + '.'
            );
        }
    }
    private static void verifyOrderItems(
        Id orderId,
        Map<Id, Decimal> requestedQuantities
    ) {
        Set<Id> contractLineIds = requestedQuantities.keySet();
        Map<Id, OrderItem> savedItemsByLine = new Map<Id, OrderItem>();
        for (OrderItem orderItem : [SELECT Id, OrderId, Quantity, Sales_Contract_Line_CC__c FROM OrderItem WHERE OrderId = :orderId AND Sales_Contract_Line_CC__c IN :contractLineIds WITH SYSTEM_MODE]) {
            if (savedItemsByLine.containsKey(orderItem.Sales_Contract_Line_CC__c)) {
                throw buildError(
                    'Duplicate Order Products were found for Contract Line ' +
                    orderItem.Sales_Contract_Line_CC__c + '.'
                );
            }
            savedItemsByLine.put(orderItem.Sales_Contract_Line_CC__c, orderItem);
        }
        for (Id contractLineId : contractLineIds) {
            Decimal requestedQuantity = requestedQuantities.get(contractLineId);
            OrderItem savedOrderItem = savedItemsByLine.get(contractLineId);
            if (requestedQuantity > 0) {
                if (savedOrderItem == null) {
                    throw buildError(
                        'Order Item was not created for Contract Line ' +
                        contractLineId + '.'
                    );
                }
                if (savedOrderItem.Quantity != requestedQuantity) {
                    throw buildError(
                        'Order Item quantity could not be saved for Contract Line ' +
                        contractLineId + '.'
                    );
                }
            } else if (savedOrderItem != null) {
                throw buildError(
                    'Order Item could not be removed for Contract Line ' +
                    contractLineId + '.'
                );
            }
        }
    }
    private static Boolean isMoqRequired(String storedValue) {
        if (String.isBlank(storedValue)) return false;
        resolveLineMoqValue();
        if (lineMoqYesValue != null) return storedValue.trim().equalsIgnoreCase(lineMoqYesValue);
        return MOQ_YES_TOKENS.contains(normalise(storedValue));
    }
    private static void resolveLineMoqValue() {
        if (lineMoqResolved) return;
        Schema.DescribeFieldResult fieldDescribe =
            Schema.SalesContractLine.MOQ_Required_CC__c.getDescribe();
        if (isPicklistType(fieldDescribe.getType())) {
            for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
                if (
                    entry.isActive() &&
                    (MOQ_YES_TOKENS.contains(normalise(entry.getValue())) ||
                     MOQ_YES_TOKENS.contains(normalise(entry.getLabel())))
                ) {
                    lineMoqYesValue = entry.getValue();
                    break;
                }
            }
        } else {
            lineMoqYesValue = TEXT_MOQ_REQUIRED_VALUE;
        }
        lineMoqResolved = true;
    }
    private static void stampMoqSnapshot(OrderItem targetItem, SalesContractLine line) {
        resolveOrderItemMoqFields();
        Boolean moqRequired = isMoqRequired(line.MOQ_Required_CC__c);
        Decimal minimumOrderQuantity = moqRequired
            ? line.Minimum_Order_Quantity_CC__c
            : null;
        targetItem.put(
            Schema.OrderItem.MOQ_Required_CC__c,
            toOrderItemMoqValue(moqRequired)
        );
        targetItem.put(
            Schema.OrderItem.Minimum_Order_Quantity_CC__c,
            toOrderItemMinimumValue(minimumOrderQuantity)
        );
    }
    private static void resolveOrderItemMoqFields() {
        if (orderItemMoqResolved) return;
        Schema.DescribeFieldResult moqDescribe =
            Schema.OrderItem.MOQ_Required_CC__c.getDescribe();
        orderItemMoqType = moqDescribe.getType();
        orderItemMinimumType =
            Schema.OrderItem.Minimum_Order_Quantity_CC__c.getDescribe().getType();
        if (isPicklistType(orderItemMoqType)) {
            for (Schema.PicklistEntry entry : moqDescribe.getPicklistValues()) {
                if (!entry.isActive()) continue;
                orderItemMoqAvailableValues.add(entry.getValue());
                String value = normalise(entry.getValue());
                String label = normalise(entry.getLabel());
                if (
                    orderItemMoqYesValue == null &&
                    (MOQ_YES_TOKENS.contains(value) || MOQ_YES_TOKENS.contains(label))
                ) {
                    orderItemMoqYesValue = entry.getValue();
                } else if (
                    orderItemMoqNoValue == null &&
                    (MOQ_NO_TOKENS.contains(value) || MOQ_NO_TOKENS.contains(label))
                ) {
                    orderItemMoqNoValue = entry.getValue();
                }
            }
        }
        orderItemMoqResolved = true;
    }
    private static Object toOrderItemMoqValue(Boolean moqRequired) {
        if (orderItemMoqType == Schema.DisplayType.BOOLEAN) return moqRequired;
        if (isPicklistType(orderItemMoqType)) {
            if (moqRequired) {
                if (orderItemMoqYesValue == null) {
                    throw buildError(
                        'Order Product MOQ Required has no active picklist value meaning Yes. ' +
                        'Available values: ' + String.join(orderItemMoqAvailableValues, ', ') + '.'
                    );
                }
                return orderItemMoqYesValue;
            }
            return orderItemMoqNoValue;
        }
        return moqRequired ? TEXT_MOQ_REQUIRED_VALUE : TEXT_MOQ_NOT_REQUIRED_VALUE;
    }
    private static Object toOrderItemMinimumValue(Decimal minimumOrderQuantity) {
        if (minimumOrderQuantity == null) return null;
        if (
            orderItemMinimumType == Schema.DisplayType.STRING ||
            orderItemMinimumType == Schema.DisplayType.TEXTAREA
        ) {
            return String.valueOf(minimumOrderQuantity);
        }
        if (orderItemMinimumType == Schema.DisplayType.INTEGER) return minimumOrderQuantity.intValue();
        return minimumOrderQuantity;
    }
    private static Boolean isPicklistType(Schema.DisplayType fieldType) {
        return fieldType == Schema.DisplayType.PICKLIST ||
            fieldType == Schema.DisplayType.MULTIPICKLIST;
    }
    private static Map<Id, Decimal> parseRequestedQuantities(String selectedLinesJson) {
        if (String.isBlank(selectedLinesJson)) throw buildError('No Order Lines were submitted for saving.');
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(selectedLinesJson);
        } catch (Exception e) {
            throw buildError('The submitted Order Lines could not be read.');
        }
        if (!(parsed instanceof List<Object>)) throw buildError('The submitted Order Lines are not in the expected format.');
        List<Object> rawLines = (List<Object>) parsed;
        if (rawLines.isEmpty()) throw buildError('No Order Lines were submitted for saving.');
        Map<Id, Decimal> requestedQuantities = new Map<Id, Decimal>();
        Integer position = 0;
        for (Object rawLine : rawLines) {
            position++;
            if (!(rawLine instanceof Map<String, Object>)) {
                throw buildError(
                    'Submitted Order Line ' + position + ' is not in the expected format.'
                );
            }
            Map<String, Object> values = (Map<String, Object>) rawLine;
            Id contractLineId = toId(values.get(KEY_CONTRACT_LINE_ID));
            if (contractLineId == null) {
                throw buildError(
                    'Submitted Order Line ' + position +
                    ' does not contain a valid Contract Line Id. Received: ' +
                    String.valueOf(values.get(KEY_CONTRACT_LINE_ID)) + '.'
                );
            }
            if (contractLineId.getSObjectType() != SalesContractLine.SObjectType) {
                throw buildError(
                    'Submitted Order Line ' + position +
                    ' does not reference a Contract Line. Received: ' +
                    contractLineId + '.'
                );
            }
            Decimal requestedQuantity = toDecimal(values.get(KEY_ORDER_QUANTITY), position);
            if (requestedQuantity < 0) throw buildError('Order Quantity cannot be negative.');
            requestedQuantities.put(contractLineId, requestedQuantity);
        }
        return requestedQuantities;
    }
    private static Id toId(Object value) {
        if (value == null) return null;
        String candidate = String.valueOf(value).trim();
        if (String.isBlank(candidate)) return null;
        try {
            return Id.valueOf(candidate);
        } catch (Exception e) {
            return null;
        }
    }
    private static Decimal toDecimal(Object value, Integer position) {
        if (value == null) return 0;
        String candidate = String.valueOf(value).trim();
        if (String.isBlank(candidate)) return 0;
        try {
            return Decimal.valueOf(candidate);
        } catch (Exception e) {
            throw buildError(
                'Submitted Order Line ' + position +
                ' has an invalid Order Quantity: ' + candidate + '.'
            );
        }
    }
    private static void checkSaveResults(List<Database.SaveResult> results) {
        for (Database.SaveResult result : results) {
            if (!result.isSuccess()) throw buildError(result.getErrors()[0].getMessage());
        }
    }
    private static void checkDeleteResults(List<Database.DeleteResult> results) {
        for (Database.DeleteResult result : results) {
            if (!result.isSuccess()) throw buildError(result.getErrors()[0].getMessage());
        }
    }
    private static String getProductName(SalesContractLine line) {
        return line != null && line.Product2 != null && line.Product2.Name != null
            ? line.Product2.Name
            : DEFAULT_PRODUCT_NAME;
    }
    private static String normalise(String value) {
        return value == null ? '' : value.trim().toLowerCase();
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