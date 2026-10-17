/**
 * =============================================================================
 * Class Name    : QuoteCloneController_CC
 * Description   : Controller class responsible for cloning Quotes and
 *                 associated Quote Line Items.
 *
 * Author        : Nipun Jain
 * Created Date  : Oct 2026
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Provides functionality to clone a Quote along with its associated
 * Quote Line Items while applying the required business validations.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public with sharing class QuoteCloneController_CC {

    @AuraEnabled (cacheable=false)
    public static Id cloneQuote(Id quoteId) {

        Quote originalQuote = Database.query(
            'SELECT ' + getFields(Quote.SObjectType) +
            ' FROM Quote WHERE Id = :quoteId LIMIT 1'
        );
        
        if (originalQuote.OpportunityId != null) {
            List<Quote> acceptedQuotes = [SELECT Id FROM Quote WHERE OpportunityId = :originalQuote.OpportunityId AND Opportunity.RecordType.DeveloperName = 'New_Business' AND Status = 'Accepted' LIMIT 1];
            if (!acceptedQuotes.isEmpty()) {
                throw new AuraHandledException('An Accepted Quote already exists for this Opportunity.');
            }
        }

        Quote clonedQuote = originalQuote.clone(false, false, false, false);
        clonedQuote.Name = originalQuote.Name + ' - Copy';
        clonedQuote.Status = 'Draft';
        clonedQuote.Quote_Accepted_Date__c = NULL;
        clonedQuote.Rejection_Reason__c = NULL;
        clonedQuote.Cancelled_Date__c = NULL;
        clonedQuote.Cancelled_Reason__c = NULL;
        clonedQuote.Cancelled_Reason_Detail__c = NULL;
        clonedQuote.StartDate = NULL;
        clonedQuote.ExpirationDate = NULL;
        clonedQuote.Validity_Period_Days__c = NULL;
        Database.insert(clonedQuote, AccessLevel.SYSTEM_MODE);

        List<QuoteLineItem> originalLines = Database.query(
            'SELECT ' + getFields(QuoteLineItem.SObjectType) +
            ' FROM QuoteLineItem WHERE QuoteId = :quoteId'
        );

        List<QuoteLineItem> clonedLines = new List<QuoteLineItem>();

        for (QuoteLineItem line : originalLines) {
            QuoteLineItem clonedLine = line.clone(false, false, false, false);
            clonedLine.QuoteId = clonedQuote.Id;
            clonedLines.add(clonedLine);
        }

        if (!clonedLines.isEmpty()) {
            Database.insert(clonedLines, AccessLevel.SYSTEM_MODE);
        }

        return clonedQuote.Id;
    }

    private static String getFields(Schema.SObjectType objectType) {
        Map<String, Schema.SObjectField> fields =
            objectType.getDescribe().fields.getMap();

        List<String> fieldNames = new List<String>();

        for (String fieldName : fields.keySet()) {
            Schema.DescribeFieldResult field = fields.get(fieldName).getDescribe();

            if (fieldName != 'Id' &&
                field.isCreateable() &&
                !field.isCalculated() &&
                !field.isAutoNumber()) {
                fieldNames.add(fieldName);
            }
        }

        return String.join(fieldNames, ',');
    }
}