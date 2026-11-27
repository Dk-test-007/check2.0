/**
 * OrderRefreshPriceController_CC
 *
 * Backs the "Refresh Price" headless quick action on Order.
 * Compares each Order Product's ListPrice with the current PricebookEntry.UnitPrice.
 *  - If every line already matches, nothing is changed and the user is told the Order
 *    already has the latest Customer Price Book prices.
 *  - If at least one line differs, ALL Order Products are deleted and recreated so that
 *    OrderItem.ListPrice is re-inherited from the current PricebookEntry. ListPrice is not
 *    createable or updateable through the API; Salesforce sets it from the PricebookEntry
 *    only when the Order Product is created, which is why delete-and-recreate is required.
 *
 * Runs in SYSTEM CONTEXT by design (without sharing + AccessLevel.SYSTEM_MODE), so users
 * without Delete permission on Order Products can still run it. Validation rules,
 * triggers and flows still execute normally; nothing is bypassed.
 *
 * Returns { refreshed: Boolean, message: String } so the LWC can tell a refresh
 * apart from a "nothing to do" outcome.
 */
public without sharing class OrderRefreshPriceController_CC {

    @TestVisible
    private static final String ALREADY_CURRENT_MESSAGE =
        'The Order already has the latest Customer Price Book prices.';

    @TestVisible
    private static Boolean forceInsertFailure = false;

    @AuraEnabled
    public static Map<String, Object> refreshPrices(Id orderId) {
        if (orderId == null) {
            throwError('No Order Id was received from the action.');
        }

        Boolean isMultiCurrency = UserInfo.isMultiCurrencyOrganization();

        List<Order> orders = Database.queryWithBinds(
            'SELECT Id, Pricebook2Id, StatusCode' + (isMultiCurrency ? ', CurrencyIsoCode' : '') +
            ' FROM Order WHERE Id = :orderId LIMIT 1',
            new Map<String, Object>{ 'orderId' => orderId },
            AccessLevel.SYSTEM_MODE
        );
        if (orders.isEmpty()) {
            throwError('The Order could not be found.');
        }
        Order ord = orders[0];

        if (ord.StatusCode == 'Activated') {
            throwError('Order Products cannot be changed on an activated Order. ' +
                       'Move the Order back to a Draft status and try again.');
        }
        if (ord.Pricebook2Id == null) {
            throwError('This Order has no Price Book assigned, so current prices cannot be resolved.');
        }

        List<OrderItem> oldItems = [
            SELECT Id, OrderId, Product2Id, Product2.Name, PricebookEntryId, OriginalOrderItemId,
                   ListPrice, UnitPrice, Description,  Quantity, UnitCost
            FROM OrderItem WHERE OrderId = :orderId WITH SYSTEM_MODE ORDER BY OrderItemNumber];

        if (oldItems.isEmpty()) {
            return buildResult(false, 'This Order has no Order Products to refresh. No changes were made.');
        }

        Set<Id> productIds = new Set<Id>();
        for (OrderItem item : oldItems) {
            if (item.OriginalOrderItemId != null) {
                throwError('This Order contains reduction Order Products, which cannot be recreated. No changes were made.');
            }
            productIds.add(item.Product2Id);
        }

        String pbeQuery = 'SELECT Id, Product2Id, UnitPrice FROM PricebookEntry ' +
                          'WHERE Pricebook2Id = :pricebookId AND Product2Id IN :productIds AND IsActive = true';
        Map<String, Object> pbeBinds = new Map<String, Object>{
            'pricebookId' => ord.Pricebook2Id,
            'productIds'  => productIds
        };
        if (isMultiCurrency) {
            pbeQuery += ' AND CurrencyIsoCode = :currencyCode';
            pbeBinds.put('currencyCode', ord.get('CurrencyIsoCode'));
        }

        Map<Id, PricebookEntry> entryByProduct = new Map<Id, PricebookEntry>();
        for (PricebookEntry entry : (List<PricebookEntry>) Database.queryWithBinds(pbeQuery, pbeBinds, AccessLevel.SYSTEM_MODE)) {
            if (entryByProduct.containsKey(entry.Product2Id)) {
                throwError('More than one active Price Book Entry matches product ' + entry.Product2Id +
                           '. No changes were made.');
            }
            entryByProduct.put(entry.Product2Id, entry);
        }

        Set<String> missingProducts = new Set<String>();
        for (OrderItem item : oldItems) {
            if (!entryByProduct.containsKey(item.Product2Id)) {
                missingProducts.add(item.Product2.Name);
            }
        }
        if (!missingProducts.isEmpty()) {
            throwError('No active Price Book Entry was found in this Order\'s Price Book' +
                       (isMultiCurrency ? ' for currency ' + ord.get('CurrencyIsoCode') : '') +
                       ' for: ' + String.join(new List<String>(missingProducts), ', ') +
                       '. No changes were made.');
        }

        Boolean priceChanged = false;
        for (OrderItem item : oldItems) {
            Decimal currentPrice = entryByProduct.get(item.Product2Id).UnitPrice;
            if (item.ListPrice != currentPrice || item.UnitPrice != currentPrice) {
                priceChanged = true;
                break;
            }
        }
        if (!priceChanged) {
            return buildResult(false, ALREADY_CURRENT_MESSAGE);
        }

        List<OrderItem> newItems = new List<OrderItem>();
        for (OrderItem oldItem : oldItems) {
            PricebookEntry entry = entryByProduct.get(oldItem.Product2Id);
            newItems.add(new OrderItem(
                OrderId                      = ord.Id,
                Product2Id                   = oldItem.Product2Id,
                PricebookEntryId             = entry.Id,
                UnitPrice                    = entry.UnitPrice,
                Description                  = oldItem.Description,
                Quantity                     = oldItem.Quantity,
                UnitCost                     = oldItem.UnitCost
            ));
        }

        Savepoint sp = Database.setSavepoint();
        String failure;
        try {
            Database.delete(oldItems, true, AccessLevel.SYSTEM_MODE);

            if (forceInsertFailure) {
                newItems[0].Quantity = null; // test-only: Quantity is required, so insert fails
            }
            Database.insert(newItems, true, AccessLevel.SYSTEM_MODE);

            // Confirm Salesforce populated ListPrice from the resolved entry before reporting success.
            for (OrderItem created : [
                SELECT Id, Product2.Name, ListPrice, PricebookEntry.UnitPrice
                FROM OrderItem
                WHERE Id IN :newItems
                WITH SYSTEM_MODE
            ]) {
                if (created.ListPrice != created.PricebookEntry.UnitPrice) {
                    failure = 'List Price for ' + created.Product2.Name +
                              ' does not match its Price Book Entry after recreation.';
                    break;
                }
            }
        } catch (Exception e) {
            failure = (e instanceof DmlException)
                ? ((DmlException) e).getDmlMessage(0)
                : e.getMessage();
        }

        if (failure != null) {
            Database.rollback(sp);
            throwError('Refresh Price failed and no changes were saved. ' + failure);
        }

        return buildResult(true, 'Prices refreshed for ' + newItems.size() + ' Order Product(s).');
    }

    public static Map<String, Object> buildResult(Boolean refreshed, String message) {
        return new Map<String, Object>{ 'refreshed' => refreshed, 'message' => message };
    }

    public static void throwError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        throw ex;
    }
}