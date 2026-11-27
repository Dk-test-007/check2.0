/**
 * Suggested Carlton Entity for the New Lead Wizard (Lead_Quick_Entry_CC), from the running user's direct
 * membership of the regional Lead queues that Lead routing already uses (LeadTriggerHandler_CC_New):
 * US_Marketing_Pool / US_Sales_Pool -> Carlton Packaging INC, UK_Marketing_Pool / UK_Sales_Pool -> Carlton Packaging LLP.
 *
 * Only active Belongs_To_CC__c values the user can set are suggested. When the user's queues give exactly one active
 * Entity, that is the suggestion. When they give none (no regional queue, or only an inactive value such as LLP today)
 * and the picklist has exactly one active value, that value is suggested: it is the only choice the wizard offers, so a
 * US user always gets the US Entity while UK (LLP) waits for a later phase (Nov 11 UAT feedback, item 1). Two or more
 * active Entities from the queues give no suggestion. Nothing is inferred from name, email, locale or time zone. The
 * suggestion only preselects the wizard's Entity choice: the user can change it, and routing, review-before-create
 * and validation are unchanged.
 */
public with sharing class LeadEntityDefault_CC {

    public static final String US_ENTITY = 'Carlton Packaging INC';
    public static final String UK_ENTITY = 'Carlton Packaging LLP';
    public static final String RESULT_DEFAULTED = 'Defaulted';
    public static final String RESULT_UNKNOWN = 'Unknown';
    public static final String RESULT_AMBIGUOUS = 'Ambiguous';
    public static final String RESULT_UNAVAILABLE = 'Unavailable';

    @TestVisible
    private static final Map<String, String> ENTITY_BY_QUEUE = new Map<String, String>{
        'US_Marketing_Pool' => US_ENTITY,
        'US_Sales_Pool' => US_ENTITY,
        'UK_Marketing_Pool' => UK_ENTITY,
        'UK_Sales_Pool' => UK_ENTITY
    };

    /** Wizard output. */
    public class Result {
        @InvocableVariable(label='Suggested Entity' description='Belongs_To_CC__c value to preselect; blank when there is no safe suggestion')
        public String entityValue;
        @InvocableVariable(label='Outcome' description='Defaulted, Unknown, Ambiguous or Unavailable')
        public String outcome;
    }

    /**
     * @return one suggestion for the running user
     */
    @InvocableMethod(label='Suggest Carlton Entity for Running User'
        description='Suggests the Carlton Entity from the user\'s regional Lead queue membership; blank when unknown or ambiguous.'
        category='Lead')
    public static List<Result> suggestForRunningUser() {
        return new List<Result>{ suggest(UserInfo.getUserId()) };
    }

    @TestVisible
    private static Result suggest(Id userId) {
        Set<String> entities = new Set<String>();
        // System mode: reads only this user's own queue memberships; users cannot otherwise query GroupMember.
        for (GroupMember membership : [
            SELECT Group.DeveloperName FROM GroupMember
            WHERE UserOrGroupId = :userId AND Group.Type = 'Queue' AND Group.DeveloperName IN :ENTITY_BY_QUEUE.keySet()
            WITH SYSTEM_MODE
        ]) {
            entities.add(ENTITY_BY_QUEUE.get(membership.Group.DeveloperName));
        }
        Result result = new Result();
        if (!Lead.Belongs_To_CC__c.getDescribe().isCreateable()) {
            result.outcome = RESULT_UNAVAILABLE;
            return result;
        }
        Set<String> activeValues = activeValues();
        Set<String> usable = new Set<String>(entities);
        usable.retainAll(activeValues);
        if (usable.size() > 1) {
            result.outcome = RESULT_AMBIGUOUS;
        } else if (usable.size() == 1) {
            result.entityValue = usable.iterator().next();
            result.outcome = RESULT_DEFAULTED;
        } else if (activeValues.size() == 1) {
            result.entityValue = activeValues.iterator().next();
            result.outcome = RESULT_DEFAULTED;
        } else {
            result.outcome = entities.isEmpty() ? RESULT_UNKNOWN : RESULT_UNAVAILABLE;
        }
        return result;
    }

    @TestVisible
    private static Set<String> activeValues() {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : Lead.Belongs_To_CC__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }
}