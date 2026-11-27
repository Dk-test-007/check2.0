/**
 * Opportunity UI2: Enter PO / Create Order from a Sales Agreement.
 *
 * Creates a real standard Order (and Order Products) for a customer PO release, linked to the agreement through the
 * native Order.SalesAgreementId, so the agreement's native actuals (mode Orders) count it once activated.
 * - No QuoteId: release Orders never inherit the winning Quote, so the one-activated-Order-per-Quote rule does not
 *   block repeated releases (the rule itself is unchanged).
 * - No OpportunityId: Orders cannot be created on a closed Opportunity; the source Opportunity stays traceable
 *   through SalesAgreement.Source_Opportunity_CC__c.
 * - Ship-To: the Site actually shipped to, validated against the agreement's allowed Sites, set on the Draft Order
 *   after insert (the Order trigger only derives it from an Opportunity, and this route has none).
 * - Prices are the price book list price (normal order rule for Orders without a new-business Opportunity).
 * - Agreement_Release_Key_CC__c (agreement | PO | release) is unique: the same release cannot be entered twice.
 * - Dates: an order dated before the agreement starts is rejected. The platform refuses Order.SalesAgreementId after
 *   the native EndDate (fixed once Activated), so a later Order is linked by Agreement_Extension_CC__c instead and
 *   counted in the extension actuals. If its month has no plan row yet (after the last planned month, or a gap), the
 *   month is added as an extension month with forecast 0.
 * Existing Order and Order Product triggers and validation rules all run.
 */
public with sharing class AgreementReleaseOrderService_CC {

    public class ReleaseLine {
        @AuraEnabled public Id agreementProductId { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
    }

    public class ReleaseRequest {
        @AuraEnabled public Id agreementId { get; set; }
        @AuraEnabled public String poNumber { get; set; }
        @AuraEnabled public String releaseNumber { get; set; }
        @AuraEnabled public Date orderDate { get; set; }
        @AuraEnabled public Id shipToSiteId { get; set; }
        @AuraEnabled public String locationCode { get; set; }
        @AuraEnabled public String shipmentMethod { get; set; }
        @AuraEnabled public List<ReleaseLine> lines { get; set; }
        @AuraEnabled public Boolean activateNow { get; set; }
    }

    public class ReleaseResult {
        @AuraEnabled public Id orderId { get; set; }
        @AuraEnabled public String orderNumber { get; set; }
        @AuraEnabled public Boolean alreadyExisted { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String message { get; set; }
    }

    public class EntryContext {
        @AuraEnabled public String agreementStatus { get; set; }
        @AuraEnabled public String currencyIsoCode { get; set; }
        @AuraEnabled public Date periodStart { get; set; }
        @AuraEnabled public Date periodEnd { get; set; }
        /** Last day of the last planned month (past periodEnd when the term was extended). */
        @AuraEnabled public Date coveredThrough { get; set; }
        @AuraEnabled public List<SalesAgreementPlanService_CC.Option> products { get; set; }
        @AuraEnabled public List<SalesAgreementPlanService_CC.Option> sites { get; set; }
        @AuraEnabled public List<SalesAgreementPlanService_CC.Option> locationCodes { get; set; }
        @AuraEnabled public List<SalesAgreementPlanService_CC.Option> shipmentMethods { get; set; }
        @AuraEnabled public List<OrderSummary> orders { get; set; }
    }

    public class OrderSummary {
        @AuraEnabled public Id orderId { get; set; }
        @AuraEnabled public String orderNumber { get; set; }
        @AuraEnabled public String poNumber { get; set; }
        @AuraEnabled public String releaseKey { get; set; }
        @AuraEnabled public Date orderDate { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String shipToName { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        /** Native (SalesAgreementId, inside the native term) or Extension (Agreement_Extension_CC__c, after it). */
        @AuraEnabled public String link { get; set; }
        /** The Order's product lines, for example "Logitech Brio 4K Webcam × 1; Tape × 20" (10 Nov). */
        @AuraEnabled public String products { get; set; }
    }

    /** "Name × quantity" per line, in line order, joined by "; ". */
    @TestVisible
    static String productSummary(List<OrderItem> items) {
        List<String> parts = new List<String>();
        for (OrderItem item : items) {
            String quantity = item.Quantity == null ? '' : ' × ' + item.Quantity.stripTrailingZeros().toPlainString();
            parts.add(item.Product2?.Name + quantity);
        }
        return String.join(parts, '; ');
    }

    @AuraEnabled
    public static EntryContext getEntryContext(Id agreementId) {
        SalesAgreementPlanService_CC.requirePilot();
        SalesAgreement agreement = loadAgreement(agreementId);
        EntryContext ctx = new EntryContext();
        ctx.agreementStatus = agreement.Status;
        ctx.currencyIsoCode = agreement.CurrencyIsoCode;
        ctx.periodStart = agreement.StartDate;
        ctx.periodEnd = agreement.EndDate;
        Date lastPlanned = SalesAgreementForecastService_CC.lastPlannedMonth(agreementId);
        ctx.coveredThrough = lastPlanned == null ? agreement.EndDate : lastPlanned.addMonths(1).addDays(-1);
        ctx.products = new List<SalesAgreementPlanService_CC.Option>();
        for (SalesAgreementProduct product : [SELECT Id, Name, SalesPrice, PricebookEntry.UnitPrice FROM SalesAgreementProduct
                                              WHERE SalesAgreementId = :agreementId WITH USER_MODE ORDER BY Name]) {
            ctx.products.add(option(product.Id, product.Name, product.PricebookEntry.UnitPrice));
        }
        ctx.sites = new List<SalesAgreementPlanService_CC.Option>();
        Set<Id> allowed = AgreementSiteRules_CC.allowedShipToSites(agreement);
        for (Account site : AgreementSiteRules_CC.sitesOfEntity(agreement.AccountId)) {
            if (allowed.contains(site.Id)) {
                ctx.sites.add(option(site.Id, site.Name, null));
            }
        }
        ctx.locationCodes = picklist(Order.Location_Code_CC__c);
        ctx.shipmentMethods = picklist(Order.Shipment_Method_Code_CC__c);
        ctx.orders = new List<OrderSummary>();
        for (Order ord : [SELECT Id, OrderNumber, PoNumber, Agreement_Release_Key_CC__c, EffectiveDate, Status,
                                 Ship_to_Customer_No_CC__r.Name, TotalAmount, SalesAgreementId,
                                 (SELECT Product2.Name, Quantity FROM OrderItems ORDER BY OrderItemNumber)
                          FROM Order WHERE SalesAgreementId = :agreementId OR Agreement_Extension_CC__c = :agreementId
                          WITH USER_MODE ORDER BY EffectiveDate, OrderNumber]) {
            OrderSummary s = new OrderSummary();
            s.orderId = ord.Id;
            s.orderNumber = ord.OrderNumber;
            s.poNumber = ord.PoNumber;
            s.releaseKey = ord.Agreement_Release_Key_CC__c;
            s.orderDate = ord.EffectiveDate;
            s.status = ord.Status;
            s.shipToName = ord.Ship_to_Customer_No_CC__r?.Name;
            s.amount = ord.TotalAmount;
            s.link = ord.SalesAgreementId == agreementId ? 'Native' : 'Extension';
            s.products = productSummary(ord.OrderItems);
            ctx.orders.add(s);
        }
        return ctx;
    }

    @AuraEnabled
    public static ReleaseResult createRelease(ReleaseRequest request) {
        SalesAgreementPlanService_CC.requirePilot();
        if (request == null || request.agreementId == null) {
            throw SalesAgreementPlanService_CC.error('Choose the Sales Agreement.');
        }
        SalesAgreementPlanService_CC.requireEditAccess(request.agreementId);
        SalesAgreement agreement = loadAgreement(request.agreementId);
        if (String.isBlank(request.poNumber)) {
            throw SalesAgreementPlanService_CC.error('Enter the customer PO number.');
        }
        String release = String.isBlank(request.releaseNumber) ? '1' : request.releaseNumber.trim();
        String key = (agreement.Id + '|' + request.poNumber.trim() + '|' + release).left(120);
        List<Order> existing = [SELECT Id, OrderNumber, Status, TotalAmount FROM Order
                                WHERE Agreement_Release_Key_CC__c = :key WITH SYSTEM_MODE LIMIT 1];
        if (!existing.isEmpty()) {
            return result(existing[0], true, 'This PO release was already entered; nothing new was created.');
        }
        if (request.orderDate == null) {
            throw SalesAgreementPlanService_CC.error('Enter the order date.');
        }
        if (agreement.StartDate != null && request.orderDate < agreement.StartDate) {
            throw SalesAgreementPlanService_CC.error('The order date is before this agreement starts ('
                + agreement.StartDate.format() + '). Enter it against the agreement that covers that date.');
        }
        // The platform refuses SalesAgreementId outside the native term, so a later Order uses the extension link.
        Boolean afterNativeTerm = agreement.EndDate != null && request.orderDate > agreement.EndDate;
        Date orderMonth = ForecastMetrics_CC.firstOfMonth(request.orderDate);
        if (!AgreementSiteRules_CC.allowedShipToSites(agreement).contains(request.shipToSiteId)) {
            throw SalesAgreementPlanService_CC.error('Choose a Ship-To Site covered by this agreement.');
        }
        Map<Id, SalesAgreementProduct> products = new Map<Id, SalesAgreementProduct>([
            SELECT Id, PricebookEntryId, PricebookEntry.UnitPrice, PricebookEntry.IsActive
            FROM SalesAgreementProduct WHERE SalesAgreementId = :agreement.Id WITH USER_MODE
        ]);
        if (request.lines == null || request.lines.isEmpty()) {
            throw SalesAgreementPlanService_CC.error('Add at least one product line.');
        }
        for (ReleaseLine line : request.lines) {
            SalesAgreementProduct product = products.get(line.agreementProductId);
            if (product == null || !product.PricebookEntry.IsActive) {
                throw SalesAgreementPlanService_CC.error('Each line must be an active product of this agreement.');
            }
            if (line.quantity == null || line.quantity <= 0) {
                throw SalesAgreementPlanService_CC.error('Each line needs a quantity above zero.');
            }
        }
        Account site = [SELECT Id, ShippingStreet, ShippingCity, ShippingStateCode, ShippingPostalCode, ShippingCountryCode
                        FROM Account WHERE Id = :request.shipToSiteId WITH USER_MODE];
        Account entity = [SELECT Id, BillingStreet, BillingCity, BillingStateCode, BillingPostalCode, BillingCountryCode
                          FROM Account WHERE Id = :agreement.AccountId WITH USER_MODE];

        Savepoint sp = Database.setSavepoint();
        try {
            Order ord = new Order(
                AccountId = agreement.AccountId,
                Pricebook2Id = agreement.PricebookId,
                CurrencyIsoCode = agreement.CurrencyIsoCode,
                EffectiveDate = request.orderDate,
                Status = 'Draft',
                PoNumber = request.poNumber.trim(),
                SalesAgreementId = afterNativeTerm ? null : agreement.Id,
                Agreement_Extension_CC__c = afterNativeTerm ? agreement.Id : null,
                Agreement_Release_Key_CC__c = key,
                Ship_to_Customer_No_CC__c = site.Id,
                Location_Code_CC__c = request.locationCode,
                Shipment_Date_CC__c = request.orderDate,
                Shipment_Method_Code_CC__c = request.shipmentMethod,
                ShippingStreet = site.ShippingStreet, ShippingCity = site.ShippingCity,
                ShippingStateCode = site.ShippingStateCode, ShippingPostalCode = site.ShippingPostalCode,
                ShippingCountryCode = site.ShippingCountryCode,
                BillingStreet = entity.BillingStreet, BillingCity = entity.BillingCity,
                BillingStateCode = entity.BillingStateCode, BillingPostalCode = entity.BillingPostalCode,
                BillingCountryCode = entity.BillingCountryCode,
                Description = 'PO ' + request.poNumber.trim() + ' release ' + release + ' against ' + agreement.Name
            );
            Database.SaveResult saved = Database.insert(ord, false, AccessLevel.USER_MODE);
            if (!saved.isSuccess()) {
                Database.rollback(sp);
                List<Order> raced = [SELECT Id, OrderNumber, Status, TotalAmount FROM Order
                                     WHERE Agreement_Release_Key_CC__c = :key WITH SYSTEM_MODE LIMIT 1];
                if (!raced.isEmpty()) {
                    return result(raced[0], true, 'This PO release was entered by another request; nothing new was created.');
                }
                throw SalesAgreementPlanService_CC.error(saved.getErrors()[0].getMessage());
            }
            // The Order trigger derives Ship-To from an Opportunity on insert (none here), so it is set again while the
            // Order is still Draft: the release keeps the Site it actually ships to.
            Database.update(new Order(Id = ord.Id, Ship_to_Customer_No_CC__c = site.Id), AccessLevel.USER_MODE);
            List<OrderItem> items = new List<OrderItem>();
            for (ReleaseLine line : request.lines) {
                SalesAgreementProduct product = products.get(line.agreementProductId);
                items.add(new OrderItem(OrderId = ord.Id, PricebookEntryId = product.PricebookEntryId,
                    Quantity = line.quantity, UnitPrice = product.PricebookEntry.UnitPrice,
                    Location_Code_CC__c = request.locationCode, Shipment_Date_CC__c = request.orderDate));
            }
            Database.insert(items, AccessLevel.USER_MODE);
            if (request.activateNow == true) {
                Database.update(new Order(Id = ord.Id, Status = 'Activated'), AccessLevel.USER_MODE);
            }
            String monthNote = '';
            if (afterNativeTerm && !SalesAgreementForecastService_CC.hasPlanMonth(agreement.Id, orderMonth)) {
                try {
                    SalesAgreementForecastService_CC.addPlanMonths(agreement, new List<Date>{ orderMonth }, new List<Decimal>{ 0 },
                        ('PO ' + request.poNumber.trim() + ' dated ' + request.orderDate.format()
                        + ' after the planned term; month added with forecast 0.').left(255));
                    monthNote = ' ' + ForecastMetrics_CC.label(orderMonth) + ' was added to the plan with forecast 0.';
                } catch (DmlException ex) {
                    // A concurrent release added the same month first (unique Plan Key): keep that row and this Order.
                    if (ex.getDmlType(0) != StatusCode.DUPLICATE_VALUE) {
                        throw ex;
                    }
                }
            }
            Order created = [SELECT Id, OrderNumber, Status, TotalAmount FROM Order WHERE Id = :ord.Id WITH USER_MODE];
            String counted = afterNativeTerm
                ? 'It counts in the extension actuals (after the native term) as soon as it is activated.'
                : 'Recalculate the agreement to refresh Order Actuals.';
            return result(created, false, (request.activateNow == true
                ? 'Order activated. ' + counted
                : 'Draft Order created. Activate it to count it in Order Actuals.') + monthNote);
        } catch (Exception ex) {
            Database.rollback(sp);
            if (ex instanceof AuraHandledException) {
                throw ex;
            }
            throw SalesAgreementPlanService_CC.error('Nothing was saved. ' + (ex instanceof DmlException ? ((DmlException) ex).getDmlMessage(0) : ex.getMessage()));
        }
    }

    @AuraEnabled
    public static String activateOrder(Id orderId) {
        SalesAgreementPlanService_CC.requirePilot();
        SalesAgreementPlanService_CC.requireEditAccess(orderId);
        Order ord = [SELECT Id, SalesAgreementId, Agreement_Extension_CC__c FROM Order WHERE Id = :orderId WITH USER_MODE];
        if (ord.SalesAgreementId == null && ord.Agreement_Extension_CC__c == null) {
            throw SalesAgreementPlanService_CC.error('Only Sales Agreement release Orders can be activated here.');
        }
        Database.update(new Order(Id = orderId, Status = 'Activated'), AccessLevel.USER_MODE);
        return ord.SalesAgreementId == null
            ? 'Order activated. It counts in the extension actuals (after the native term).'
            : 'Order activated. Recalculate the agreement to refresh Order Actuals.';
    }

    private static SalesAgreement loadAgreement(Id agreementId) {
        return SalesAgreementForecastService_CC.loadForPlan(agreementId);
    }

    private static ReleaseResult result(Order ord, Boolean alreadyExisted, String message) {
        ReleaseResult r = new ReleaseResult();
        r.orderId = ord.Id;
        r.orderNumber = ord.OrderNumber;
        r.status = ord.Status;
        r.amount = ord.TotalAmount;
        r.alreadyExisted = alreadyExisted;
        r.message = message;
        return r;
    }

    private static SalesAgreementPlanService_CC.Option option(String value, String label, Decimal amount) {
        SalesAgreementPlanService_CC.Option o = new SalesAgreementPlanService_CC.Option();
        o.value = value;
        o.label = label;
        o.amount = amount;
        return o;
    }

    private static List<SalesAgreementPlanService_CC.Option> picklist(Schema.SObjectField field) {
        List<SalesAgreementPlanService_CC.Option> options = new List<SalesAgreementPlanService_CC.Option>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                options.add(option(entry.getValue(), entry.getLabel(), null));
            }
        }
        return options;
    }
}