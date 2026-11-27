/**
 * Test-only helper for Identify Leads that have an Entity (Belongs_To_CC__c).
 *
 * When such a Lead is saved by anyone other than a Carlton Sales / Internal Account Manager user, the Lead trigger
 * re-owns it to the Entity's pool queue from Lead_Company_Owner_Mapping_CC (LeadTriggerHandler_CC_New
 * .applyCompanyOwnerMapping). The mapping stores the queue Id, which is specific to each org: until it is updated
 * with the org's own queue Ids (after deploying to a new org), every such save fails with INVALID_CROSS_REFERENCE_KEY.
 *
 * insertIdentifyLeads() saves the Leads; where the mapped pools exist it requires the save to succeed, otherwise it
 * asserts that documented failure so the calling test can stop there.
 */
@IsTest
public class TestLeadRouting_CC {

    private static final String ROUTING_FAILURE = 'INVALID_CROSS_REFERENCE_KEY';

    /** Whether every active Entity owner mapping points at a queue or user that exists in this org. */
    public static Boolean entityPoolsExist() {
        Set<Id> ownerIds = new Set<Id>();
        for (Lead_Company_Owner_Mapping_CC__mdt mapping : [SELECT Owner_Id_CC__c FROM Lead_Company_Owner_Mapping_CC__mdt
                                                           WHERE Active_CC__c = TRUE AND Company_Name_CC__c = NULL
                                                           AND Entity_CC__c != NULL AND Owner_Id_CC__c != NULL]) {
            try {
                ownerIds.add(Id.valueOf(mapping.Owner_Id_CC__c.trim()));
            } catch (Exception ex) {
                return false;
            }
        }
        Integer found = [SELECT COUNT() FROM Group WHERE Id IN :ownerIds] + [SELECT COUNT() FROM User WHERE Id IN :ownerIds];
        return found == ownerIds.size();
    }

    /**
     * Inserts the Identify Leads as the running user. Returns true when they are saved (the mapped pools exist).
     * Otherwise asserts that each save was refused because the mapped pool does not exist, and returns false.
     */
    public static Boolean insertIdentifyLeads(List<Lead> leads) {
        List<Database.SaveResult> results = Database.insert(leads, false);
        Boolean poolsExist = entityPoolsExist();
        for (Database.SaveResult result : results) {
            if (poolsExist) {
                Assert.isTrue(result.isSuccess(), 'Lead insert should succeed: ' + result.getErrors());
            } else {
                assertRoutingFailure(result);
            }
        }
        return poolsExist;
    }

    /** Asserts the save was refused because the Entity's mapped pool does not exist in this org. */
    public static void assertRoutingFailure(Database.SaveResult result) {
        Assert.isFalse(result.isSuccess(), 'Entity routing to a pool that does not exist in this org must fail the save');
        Assert.isTrue(String.valueOf(result.getErrors()).contains(ROUTING_FAILURE),
            'Only the missing mapped pool should block the save: ' + result.getErrors());
    }
}
