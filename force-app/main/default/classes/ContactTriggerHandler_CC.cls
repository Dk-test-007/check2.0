public class ContactTriggerHandler_CC extends BaseTriggerHandler_CC {
    public void run(BaseTriggerHandler_CC handler) {
        super.run(handler, 'Contact');
    }
    public override void beforeInsert() {
        validateContactMethod((List<Contact>)trigger.new);
    }
    public override void beforeUpdate() {
        validateContactMethod((List<Contact>)trigger.new);
    }
    public override void afterInsert() {
        ZoomInfoMappingBatch_CC.processInsertedRecords('Contact', (List<Contact>)trigger.new);
    }
    public static void validateContactMethod(List<Contact> newContacts) {
        for (Contact con : newContacts) {
            if (String.isBlank(con.Phone) &&
                String.isBlank(con.MobilePhone)) {
                con.addError('Contact must have a Phone or Mobile populated before Saving.');
            }
        }
    }
}