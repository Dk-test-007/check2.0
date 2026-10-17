public class InvoiceTriggerHandler_CC extends BaseTriggerHandler_CC {
    public void run(BaseTriggerHandler_CC handler) {
        super.run(handler, 'Invoice');
    }
    public override void beforeInsert()
    {
        populateAccountAndOrder((List<Invoice>)trigger.new);
    }
    public static void populateAccountAndOrder(List<Invoice> newInvoices) {
        Set<String> accountCodes = new Set<String>();
        Set<String> orderCodes = new Set<String>();
        
        // 1. Collect the BC codes from the incoming Invoices
        for (Invoice inv : newInvoices) {
            if (String.isNotBlank(inv.BC_Account_Code_CC__c)) {
                accountCodes.add(inv.BC_Account_Code_CC__c);
            }
            if (String.isNotBlank(inv.BC_Order_Code_CC__c)) {
                orderCodes.add(inv.BC_Order_Code_CC__c);
            }
        }
        
        // 2. Query matching Accounts and build a Map of BC Customer ID -> Account Id
        Map<String, Id> accountCodeToIdMap = new Map<String, Id>();
        if (!accountCodes.isEmpty()) {
            for (Account acc : [SELECT Id, Business_Central_Customer_ID_CC__c 
                                FROM Account 
                                WHERE Business_Central_Customer_ID_CC__c IN :accountCodes]) {
                accountCodeToIdMap.put(acc.Business_Central_Customer_ID_CC__c, acc.Id);
            }
        }
        
        // 3. Query matching Orders and build a Map of External ID -> Order Id
        Map<String, Id> orderCodeToIdMap = new Map<String, Id>();
        if (!orderCodes.isEmpty()) {
            for (Order ord : [SELECT Id, External_Id_CC__c 
                              FROM Order 
                              WHERE External_Id_CC__c IN :orderCodes]) {
                orderCodeToIdMap.put(ord.External_Id_CC__c, ord.Id);
            }
        }
        
        // 4. Populate the Account and Order lookups on the Invoices
        for (Invoice inv : newInvoices) {
            // Update standard Account lookup
            if (String.isNotBlank(inv.BC_Account_Code_CC__c) && accountCodeToIdMap.containsKey(inv.BC_Account_Code_CC__c)) {
                inv.BillingAccountId = accountCodeToIdMap.get(inv.BC_Account_Code_CC__c); 
            }
            
            // Update standard Order lookup
            if (String.isNotBlank(inv.BC_Order_Code_CC__c) && orderCodeToIdMap.containsKey(inv.BC_Order_Code_CC__c)) {
                inv.ReferenceEntityId = orderCodeToIdMap.get(inv.BC_Order_Code_CC__c);
            }
        }
    }
}