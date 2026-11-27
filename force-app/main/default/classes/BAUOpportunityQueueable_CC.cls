/**
 * =============================================================================
 * Class Name    : BAUOpportunityQueueable_CC
 * Description   : Queueable class to execute BAUOpportunityBatch_CC
 * =============================================================================
 */
public class BAUOpportunityQueueable_CC implements Queueable {

    private Set<Id> accountIds;

    public BAUOpportunityQueueable_CC(Set<Id> accountIds) {
        this.accountIds = accountIds;
    }

    public void execute(QueueableContext context) {
        if (accountIds != null && !accountIds.isEmpty()) {
            Database.executeBatch(new BAUOpportunityBatch_CC(accountIds));
        }
    }
}