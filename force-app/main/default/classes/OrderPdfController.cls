public with sharing class OrderPdfController {

    // Renders the Order PDF, saves it to the Order's Files, and returns the ContentDocumentId
    @AuraEnabled
    public static Id savePdfToOrder(Id orderId) {
        Order ord = [SELECT Id, OrderNumber FROM Order WHERE Id = :orderId LIMIT 1];

        PageReference pdfPage = Page.CarltonOrderTemplate_CC;
        pdfPage.getParameters().put('id', orderId);

        Blob pdfBody = Test.isRunningTest()
            ? Blob.valueOf('Test PDF')
            : pdfPage.getContentAsPDF();

        String fileName = 'Sales Order ' + ord.OrderNumber + ' - '
            + Datetime.now().format('yyyy-MM-dd HH-mm');

        ContentVersion cv = new ContentVersion(
            Title = fileName,
            PathOnClient = fileName + '.pdf',
            VersionData = pdfBody,
            FirstPublishLocationId = orderId
        );
        insert cv;

        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
    }
}