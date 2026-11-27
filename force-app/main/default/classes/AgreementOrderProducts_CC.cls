/**
 * Carlton UI2 (10 Nov): an Order entered as a Sales Agreement release (Agreement Release Key set) may only carry that
 * agreement's products. The UI2's own Order form already offers only those; this also covers Order Products added on
 * the Order page (Add Products), which lists every product in the price book.
 * Other Orders (from an Opportunity, Quote or Contract, or created any other way) are not checked.
 */
public without sharing class AgreementOrderProducts_CC {

    /** Before insert on OrderItem. The product of an Order Product cannot be changed afterwards, so insert is enough. */
    public static void check(List<OrderItem> items) {
        Set<Id> orderIds = new Set<Id>();
        for (OrderItem item : items) {
            if (item.OrderId != null) {
                orderIds.add(item.OrderId);
            }
        }
        if (orderIds.isEmpty()) {
            return;
        }
        // System mode: the check must see the agreement and its products even when the user's sharing would not.
        Map<Id, Order> releases = new Map<Id, Order>([
            SELECT Id, SalesAgreementId, SalesAgreement.Name, Agreement_Extension_CC__c, Agreement_Extension_CC__r.Name
            FROM Order WHERE Id IN :orderIds AND Agreement_Release_Key_CC__c != null WITH SYSTEM_MODE
        ]);
        if (releases.isEmpty()) {
            return;
        }
        Set<Id> agreementIds = new Set<Id>();
        for (Order o : releases.values()) {
            Id agreementId = agreementOf(o);
            if (agreementId != null) {
                agreementIds.add(agreementId);
            }
        }
        Map<Id, Set<Id>> entriesByAgreement = new Map<Id, Set<Id>>();
        Map<Id, List<String>> namesByAgreement = new Map<Id, List<String>>();
        for (Id agreementId : agreementIds) {
            entriesByAgreement.put(agreementId, new Set<Id>());
            namesByAgreement.put(agreementId, new List<String>());
        }
        for (SalesAgreementProduct product : [SELECT SalesAgreementId, PricebookEntryId, Name FROM SalesAgreementProduct
                                              WHERE SalesAgreementId IN :agreementIds WITH SYSTEM_MODE ORDER BY Name]) {
            entriesByAgreement.get(product.SalesAgreementId).add(product.PricebookEntryId);
            namesByAgreement.get(product.SalesAgreementId).add(product.Name);
        }
        for (OrderItem item : items) {
            Order release = releases.get(item.OrderId);
            Id agreementId = release == null ? null : agreementOf(release);
            if (agreementId == null || entriesByAgreement.get(agreementId).contains(item.PricebookEntryId)) {
                continue;
            }
            item.addError(message(release, namesByAgreement.get(agreementId)));
        }
    }

    /** The agreement the release belongs to: native link inside the term, extension link after it. */
    private static Id agreementOf(Order o) {
        return o.SalesAgreementId != null ? o.SalesAgreementId : o.Agreement_Extension_CC__c;
    }

    @TestVisible
    private static String message(Order release, List<String> productNames) {
        String agreementName = release.SalesAgreementId != null ? release.SalesAgreement.Name : release.Agreement_Extension_CC__r.Name;
        return 'This Order was entered against Sales Agreement ' + agreementName + ', so it can only include that agreement\'s products: '
            + (productNames.isEmpty() ? '(none)' : String.join(productNames, ', '))
            + '. Add the product to the agreement first if the customer is now buying it.';
    }
}