/**
 * =============================================================================
 * Class Name    : QuoteDuplicateLineItemController_CC
 * Description   : Controller for detecting duplicate Quote Line Items
 *
 * Author        : Nipun Jain
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Controller for detecting duplicate Quote Line Items.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public with sharing class QuoteDuplicateLineItemController_CC {

    @AuraEnabled(cacheable=true)
    public static List<String> getDuplicateProductNames(Id quoteId) {
        List<String> duplicateProductNames = new List<String>();

        for (AggregateResult result : [SELECT Product2.Name productName, COUNT(Id) lineCount FROM QuoteLineItem WHERE QuoteId = :quoteId GROUP BY Product2.Name HAVING COUNT(Id) > 1 ORDER BY COUNT(Id) DESC]) {
            duplicateProductNames.add((String) result.get('productName'));
        }

        return duplicateProductNames;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean hasNegativeMargin(Id quoteId) {
        return [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :quoteId AND Margin_Percentage__c < 0] > 0;
    }
}