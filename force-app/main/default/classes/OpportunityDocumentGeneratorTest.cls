@isTest
private class OpportunityDocumentGeneratorTest {
  @isTest
  static void testAttachDocuments_withValidId() {
    Opportunity opp = new Opportunity(
      Name = 'Test Opportunity',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30)
    );
    insert opp;

    Test.startTest();
    OpportunityDocumentGenerator.attachDocuments(opp.Id);
    Test.stopTest();
  }

  @isTest
  static void testAttachDocuments_withNullId_throws() {
    Boolean caughtException = false;

    try {
      OpportunityDocumentGenerator.attachDocuments(null);
    } catch (AuraHandledException e) {
      caughtException = true;
    }

    System.assert(
      caughtException,
      'Expected an AuraHandledException for a null opportunityId.'
    );
  }
}
