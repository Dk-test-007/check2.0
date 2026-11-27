/**
 * Date for the Lead UI pilot outcome banner: when the Lead entered its current Status, from Lead field
 * history (Status is history-tracked). Returns null rather than a guess when history does not show it,
 * for example for changes made before tracking started.
 */
public with sharing class LeadOutcomeBannerController_CC {

    /**
     * @param leadId the Lead shown on the page
     * @param status the Status the banner is showing; only a matching latest change is returned
     * @param recordVersion the Lead's SystemModstamp as shown on the page. Not used in the query: it keys the client
     *        cache, so a later Re-Nurture or Disqualified entry is looked up again instead of reusing an earlier
     *        cycle's cached date for the same status
     * @return when the latest Status change to that value was recorded, or null when not recorded
     */
    @AuraEnabled(cacheable=true)
    public static Datetime getStatusSince(Id leadId, String status, String recordVersion) {
        if (leadId == null || String.isBlank(status)) {
            return null;
        }
        List<LeadHistory> changes = [
            SELECT CreatedDate, NewValue FROM LeadHistory
            WHERE LeadId = :leadId AND Field = 'Status'
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        return changes.isEmpty() ? null : sinceIfMatching(changes[0].NewValue, changes[0].CreatedDate, status);
    }

    /** The change date only when the latest recorded Status change is to the Status being shown. */
    @TestVisible
    private static Datetime sinceIfMatching(Object newValue, Datetime changedAt, String status) {
        return newValue != null && String.valueOf(newValue) == status ? changedAt : null;
    }
}