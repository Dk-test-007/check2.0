public class InvoiceLineTriggerHandler_CC extends BaseTriggerHandler_CC {
    public void run(BaseTriggerHandler_CC handler) {
        super.run(handler, 'InvoiceLine');
    }

    public override void beforeInsert() {
        populateInvoice((List<InvoiceLine>) Trigger.new);
    }

    public override void beforeUpdate() {
        populateInvoice((List<InvoiceLine>) Trigger.new);
    }

    public static void populateInvoice(List<InvoiceLine> newInvoiceLines) {
        if (newInvoiceLines == null || newInvoiceLines.isEmpty()) {
            return;
        }

        Set<String> documentNumbers = new Set<String>();
        Set<String> productCodes = new Set<String>();

        // Collect Invoice document numbers and Product codes.
        for (InvoiceLine line : newInvoiceLines) {
            if (String.isNotBlank(line.BC_Document_No_CC__c)) {
                documentNumbers.add(line.BC_Document_No_CC__c.trim());
            }

            if (String.isNotBlank(line.No__c)) {
                productCodes.add(line.No__c.trim());
            }
        }

        // Find the matching Invoices.
        Map<String, Id> documentNumberToInvoiceIdMap = new Map<String, Id>();

        if (!documentNumbers.isEmpty()) {
            for (Invoice inv : [
                SELECT Id, InvoiceNumber
                FROM Invoice
                WHERE InvoiceNumber IN :documentNumbers
            ]) {
                if (String.isNotBlank(inv.InvoiceNumber)) {
                    documentNumberToInvoiceIdMap.put( inv.InvoiceNumber.trim(), inv.Id );
                }
            }
        }

        // Find the matching Products.
        Map<String, Id> productCodeToProductIdMap = new Map<String, Id>();

        if (!productCodes.isEmpty()) {
            for (Product2 product : [
                SELECT Id, ProductCode
                FROM Product2
                WHERE ProductCode IN :productCodes
            ]) {
                if (String.isNotBlank(product.ProductCode)) {
                    productCodeToProductIdMap.put( product.ProductCode.trim(), product.Id );
                }
            }
        }

        // Set the Invoice and Product relationships.
        for (InvoiceLine line : newInvoiceLines) {
            String documentNumber = line.BC_Document_No_CC__c;

            if (String.isNotBlank(documentNumber)) {
                documentNumber = documentNumber.trim();

                if (documentNumberToInvoiceIdMap.containsKey(documentNumber)) {
                    line.InvoiceId = documentNumberToInvoiceIdMap.get(documentNumber);
                } else {
                    line.addError( 'No matching Invoice was found for ' + 'Business Central Document No. "' + documentNumber + '". Verify that the parent Invoice exists ' + 'and its Invoice Number matches.' );
                }
            } else if (line.InvoiceId == null) {
                // Keep an existing Invoice relationship when the source document number is blank on an update.
                line.addError( 'BC Document No. or a valid Invoice relationship ' + 'must be provided for this Invoice Line.' );
            }

            // Link the line to its Product using the Product code.
            String productCode = line.No__c;

            if (String.isNotBlank(productCode)) {
                productCode = productCode.trim();

                if (productCodeToProductIdMap.containsKey(productCode)) {
                    line.Product2Id = productCodeToProductIdMap.get(productCode);
                } else {
                    line.addError('No matching Product was found for ' + 'Business Central Product Code "' + productCode + '". Verify that the Product exists and its ' + 'Product Code matches.' );
                }
            }
        }
    }
}