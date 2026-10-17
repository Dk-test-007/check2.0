public class CreditMemoTriggerHandler_CC extends BaseTriggerHandler_CC {
    public void run(BaseTriggerHandler_CC handler) {
        super.run(handler, 'CreditMemo');
    }

    public override void beforeInsert() {
        populateAccountAndInvoice((List<CreditMemo>) Trigger.new);
    }
    public override void beforeUpdate() {
        populateAccountAndInvoice((List<CreditMemo>) Trigger.new);
    }

    public static void populateAccountAndInvoice( List<CreditMemo> newCreditMemos) {
        if (newCreditMemos == null || newCreditMemos.isEmpty()) {
            return;
        }
        Set<String> accountCodes = new Set<String>();
        Set<String> invoiceNumbers = new Set<String>();

		// 1. Collect incoming Account codes and Invoice numbers.
        for (CreditMemo cm : newCreditMemos) {
            if (String.isNotBlank(cm.BC_Account_Code_CC__c)) {
                accountCodes.add(cm.BC_Account_Code_CC__c.trim());
            }
            String invoiceNumber = getInvoiceNumberForMatching(cm);
            if (String.isNotBlank(invoiceNumber)) {
                invoiceNumbers.add(invoiceNumber);
            }
        }

        //2. Query Accounts and build a map of Business Central customer code -> Account Id. Ambiguous Account codes are excluded to avoid linking a Credit Memo to an arbitrary Account.
        Map<String, Id> accountCodeToIdMap = new Map<String, Id>();
        Set<String> ambiguousAccountCodes = new Set<String>();

        if (!accountCodes.isEmpty()) {
            for (Account acc : [
                SELECT Id, Business_Central_Customer_ID_CC__c
                FROM Account
                WHERE Business_Central_Customer_ID_CC__c
                IN :accountCodes
            ]) {
                if (
                    String.isBlank(acc.Business_Central_Customer_ID_CC__c)
                ) {
                    continue;
                }
                String accountCode = acc.Business_Central_Customer_ID_CC__c.trim();
                if (ambiguousAccountCodes.contains(accountCode)) {
                    continue;
                }
                if (accountCodeToIdMap.containsKey(accountCode)) {
                    // Multiple Accounts share the same source code.
                    // Do not use an arbitrary match.
                    accountCodeToIdMap.remove(accountCode);
                    ambiguousAccountCodes.add(accountCode);

                } else {
                    accountCodeToIdMap.put(accountCode,acc.Id);
                }
            }
        }

        
        //3. Query Invoices and build a map of Invoice Number -> Invoice Id.
        Map<String, Id> invoiceNumberToIdMap = new Map<String, Id>();
        if (!invoiceNumbers.isEmpty()) {
            for (Invoice inv : [
                SELECT Id, InvoiceNumber
                FROM Invoice
                WHERE InvoiceNumber IN :invoiceNumbers
            ]) {
                if (String.isNotBlank(inv.InvoiceNumber)) {
                    invoiceNumberToIdMap.put(inv.InvoiceNumber.trim(),inv.Id);
                }
            }
        }

        //4. Populate the standard Account and Invoice lookups.
        for (CreditMemo cm : newCreditMemos) {
            // Link the Credit Memo to the matching Account.
            if (
                String.isNotBlank(cm.BC_Account_Code_CC__c)
            ) {
                String accountCode = cm.BC_Account_Code_CC__c.trim();
                if (accountCodeToIdMap.containsKey(accountCode)) {
                    cm.BillingAccountId = accountCodeToIdMap.get(accountCode);
                }
            }
            // Determine the exact source Invoice number.
            String invoiceNumber = getInvoiceNumberForMatching(cm);
            // ReferenceEntityId supports the Invoice relationship.
            if (
                String.isNotBlank(invoiceNumber) && invoiceNumberToIdMap.containsKey(invoiceNumber)
            ) {
                cm.ReferenceEntityId = invoiceNumberToIdMap.get(invoiceNumber);
            }
        }
    }

    /*
     * 5. Determine which source field to use for Invoice matching.
     *
     *    Priority:
     *    a. Applies-to Doc. No., when the document type is Invoice.
     *    b. Original Sales Inv. No., as a fallback.
     */
    private static String getInvoiceNumberForMatching( CreditMemo cm ) {
        if (cm == null) {
            return null;
        }
        String appliesToType = cm.BC_Applies_To_Doc_Type_CC__c;
        String appliesToNumber = cm.BC_Applies_To_Doc_No_CC__c;

        if ( String.isNotBlank(appliesToType) && appliesToType.trim().equalsIgnoreCase('Invoice') && String.isNotBlank(appliesToNumber) ) {
            return appliesToNumber.trim();
        }
        if (
            String.isNotBlank( cm.BC_Original_Sales_Invoice_No_CC__c )
        ) {
            return cm.BC_Original_Sales_Invoice_No_CC__c.trim();
        }
        return null;
    }
}