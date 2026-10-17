public with sharing class QuotePdfService {
    @AuraEnabled
    public static Id saveToQuote(Id quoteId) {
        PageReference pdfPage = Page.CarltonQuoteTemplate3_3; // your renderAs="pdf" page
        pdfPage.getParameters().put('id', quoteId);

        Blob pdfBody = Test.isRunningTest()
            ? Blob.valueOf('Test PDF')
            : pdfPage.getContentAsPDF();

        QuoteDocument doc = new QuoteDocument(QuoteId = quoteId, Document = pdfBody);
        insert doc;
        return doc.Id;
    }
}