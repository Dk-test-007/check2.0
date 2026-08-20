/**
 * Backing controller for the generateOpportunityDocuments LWC record action.
 * This is a minimal, working placeholder: it resolves the deploy-time
 * dependency the LWC has on this class/method existing, but does not yet
 * implement real document generation/attachment. Replace the TODO below with
 * the actual logic (e.g. rendering and attaching a PDF via ContentVersion /
 * ContentDocumentLink) when that work is ready.
 */
public with sharing class OpportunityDocumentGenerator {
  @AuraEnabled
  public static void attachDocuments(Id opportunityId) {
    if (opportunityId == null) {
      AuraHandledException ex = new AuraHandledException(
        'opportunityId is required.'
      );
      ex.setMessage('opportunityId is required.');
      throw ex;
    }

    // TODO: implement actual document generation and attachment to the Opportunity.
  }
}
