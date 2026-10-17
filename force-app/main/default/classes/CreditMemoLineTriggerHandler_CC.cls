public class CreditMemoLineTriggerHandler_CC extends BaseTriggerHandler_CC {
    public void run(BaseTriggerHandler_CC handler) {
        super.run(handler, 'CreditMemoLine');
    }

    public override void beforeInsert() {
        populateCreditMemo((List<CreditMemoLine>) Trigger.new);
    }

    public override void beforeUpdate() {
        populateCreditMemo((List<CreditMemoLine>) Trigger.new);
    }

    public static void populateCreditMemo(
        List<CreditMemoLine> newCreditMemoLines
    ) {
        if (newCreditMemoLines == null || newCreditMemoLines.isEmpty()) {
            return;
        }

        Set<String> documentNumbers = new Set<String>();
        Set<String> productCodes = new Set<String>();

        // 1. Collect source Document No. and Product Code values.
        for (CreditMemoLine line : newCreditMemoLines) {
            if (String.isNotBlank(line.BC_Document_No_CC__c)) {
                documentNumbers.add(line.BC_Document_No_CC__c.trim());
            }

            if (String.isNotBlank(line.No__c)) {
                productCodes.add(line.No__c.trim());
            }
        }

        // 2. Query matching Credit Memos.
        // Map: Credit Memo Number -> Credit Memo Id.
        Map<String, Id> documentNumberToCreditMemoIdMap =
            new Map<String, Id>();

        if (!documentNumbers.isEmpty()) {
            for (CreditMemo cm : [
                SELECT Id, CreditMemoNumber
                FROM CreditMemo
                WHERE CreditMemoNumber IN :documentNumbers
            ]) {
                if (String.isNotBlank(cm.CreditMemoNumber)) {
                    documentNumberToCreditMemoIdMap.put(
                        cm.CreditMemoNumber.trim(),
                        cm.Id
                    );
                }
            }
        }

        // 3. Query matching Products.
        // Map: Product Code -> Product Id.
        Map<String, Id> productCodeToProductIdMap = new Map<String, Id>();

        if (!productCodes.isEmpty()) {
            for (Product2 product : [ SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN :productCodes ]) {
                if (String.isNotBlank(product.ProductCode)) {
                    productCodeToProductIdMap.put( product.ProductCode.trim(), product.Id );
                }
            }
        }

        // 4. Populate Credit Memo and Product relationships.
        for (CreditMemoLine line : newCreditMemoLines) {
            String documentNumber = line.BC_Document_No_CC__c;

            if (String.isNotBlank(documentNumber)) {
                documentNumber = documentNumber.trim();

                if ( documentNumberToCreditMemoIdMap.containsKey( documentNumber ) ) {
                    line.CreditMemoId = documentNumberToCreditMemoIdMap.get( documentNumber );
                } else {
                    line.addError( 'No matching Credit Memo was found for ' + 'Business Central Document No. "' + documentNumber + '". Verify that the parent Credit Memo exists ' + 'and its Credit Memo Number matches.' );
                }
            } else if (line.CreditMemoId == null) {
                // Preserve an existing parent relationship when the
                // source document number is blank on an update.
                line.addError( 'BC Document No. or a valid Credit Memo ' + 'relationship must be provided for this ' + 'Credit Memo Line.' );
            }

            // 5. Populate Product lookup using the product code.
            String productCode = line.No__c;

            if (String.isNotBlank(productCode)) {
                productCode = productCode.trim();

                if (productCodeToProductIdMap.containsKey(productCode)) {
                    line.Product2Id = productCodeToProductIdMap.get(productCode);
                } else {
                    line.addError( 'No matching Product was found for ' + 'Business Central Product Code "' + productCode + '". Verify that the Product exists and its ' + 'Product Code matches.' );
                }
            }
        }
    }
}