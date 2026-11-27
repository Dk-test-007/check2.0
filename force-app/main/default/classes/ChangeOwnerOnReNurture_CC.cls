/**
 * =============================================================================
 * Class Name    : ChangeOwnerOnReNurture_CC
 * Description   : Transfers Lead ownership back to Marketing after a Lead moves
 *                 to Re-Nurture, asynchronously so the user's save commits with
 *                 their access intact, then publishes a platform event so the
 *                 UI can show a toast and redirect.
 * =============================================================================
 */
public without sharing class ChangeOwnerOnReNurture_CC implements Queueable {

    private final Map<Id, Id> previousOwnerByLeadId;

    public ChangeOwnerOnReNurture_CC(Map<Id, Id> previousOwnerByLeadId) {
        this.previousOwnerByLeadId = previousOwnerByLeadId;
    }

    public void execute(QueueableContext context) {
        if (previousOwnerByLeadId == NULL || previousOwnerByLeadId.isEmpty()) {
            return;
        }

        List<Lead> leads = [
            SELECT Id, OwnerId, Status, Belongs_To_CC__c, Last_Marketing_Owner_Id_CC__c
            FROM Lead
            WHERE Id IN :previousOwnerByLeadId.keySet()
            WITH SYSTEM_MODE
        ];
        if (leads.isEmpty()) {
            return;
        }

        Set<Id> ownerIds = new Set<Id>();
        for (Lead leadRecord : leads) {
            if (isUserId(leadRecord.OwnerId)) {
                ownerIds.add(leadRecord.OwnerId);
            }
            Id storedOwnerId = toUserId(leadRecord.Last_Marketing_Owner_Id_CC__c);
            if (storedOwnerId != NULL) {
                ownerIds.add(storedOwnerId);
            }
        }

        Set<Id> marketingUsers = getMarketingUsers(ownerIds);
        Map<String, Id> queues = getQueues();
        Set<Id> marketingQueues = new Set<Id>(queues.values());

        List<Lead> leadsToTransfer = new List<Lead>();
        Map<Id, Id> transferred = new Map<Id, Id>();

        for (Lead leadRecord : leads) {
            // Status or owner may have changed between the save and this job.
            if (leadRecord.Status != 'Re-Nurture') {
                continue;
            }
            if (marketingUsers.contains(leadRecord.OwnerId) || marketingQueues.contains(leadRecord.OwnerId)) {
                continue;
            }

            Id newOwnerId = toUserId(leadRecord.Last_Marketing_Owner_Id_CC__c);
            if (newOwnerId == NULL || !marketingUsers.contains(newOwnerId)) {
                newOwnerId = NULL;
                if (leadRecord.Belongs_To_CC__c == 'Carlton Packaging INC') {
                    newOwnerId = queues.get('US_Marketing_Pool');
                } else if (leadRecord.Belongs_To_CC__c == 'Carlton Packaging LLP') {
                    newOwnerId = queues.get('UK_Marketing_Pool');
                }
            }

            if (newOwnerId != NULL && newOwnerId != leadRecord.OwnerId) {
                leadsToTransfer.add(new Lead(Id = leadRecord.Id, OwnerId = newOwnerId));
                transferred.put(leadRecord.Id, previousOwnerByLeadId.get(leadRecord.Id));
            }
        }

        if (leadsToTransfer.isEmpty()) {
            return;
        }

        try {
            update as system leadsToTransfer;
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR, 'Re-Nurture owner transfer failed: ' + e.getMessage());
            return;
        }

        publishOwnershipTransferEvents(transferred);
    }

    private static void publishOwnershipTransferEvents(Map<Id, Id> transferred) {
        if (transferred.isEmpty()) {
            return;
        }
        List<Lead_Ownership_Transferred_CC__e> events = new List<Lead_Ownership_Transferred_CC__e>();
        for (Id leadId : transferred.keySet()) {
            events.add(new Lead_Ownership_Transferred_CC__e(
                Lead_Id_CC__c           = String.valueOf(leadId),
                Recipient_User_Id_CC__c = String.valueOf(transferred.get(leadId)),
                New_Owner_Name_CC__c    = 'Marketing'
            ));
        }

        // System mode: publish is checked against the running user's object
        // permissions, and the running user here is the Sales user.
        List<Database.SaveResult> results = EventBus.publishWithAccessLevel(events, AccessLevel.SYSTEM_MODE);
        for (Database.SaveResult sr : results) {
            if (!sr.isSuccess()) {
                for (Database.Error err : sr.getErrors()) {
                    System.debug(LoggingLevel.ERROR, 'Event publish failed: ' + err.getMessage());
                }
            }
        }
    }

    private static Set<Id> getMarketingUsers(Set<Id> userIds) {
        Set<Id> marketingUsers = new Set<Id>();
        if (userIds == NULL || userIds.isEmpty()) {
            return marketingUsers;
        }
        for (User userRecord : [
            SELECT Id FROM User
            WHERE Id IN :userIds AND IsActive = TRUE AND Profile.Name = 'Carlton Marketing User'
            WITH SYSTEM_MODE
        ]) {
            marketingUsers.add(userRecord.Id);
        }
        return marketingUsers;
    }

    private static Map<String, Id> getQueues() {
        Map<String, Id> queueIdsByName = new Map<String, Id>();
        for (Group queueRecord : [
            SELECT Id, DeveloperName FROM Group
            WHERE Type = 'Queue' AND DeveloperName IN ('UK_Marketing_Pool', 'US_Marketing_Pool')
            WITH SYSTEM_MODE
        ]) {
            queueIdsByName.put(queueRecord.DeveloperName, queueRecord.Id);
        }
        return queueIdsByName;
    }

    private static Boolean isUserId(Id ownerId) {
        return ownerId != NULL && ownerId.getSObjectType() == User.SObjectType;
    }

    private static Id toUserId(String value) {
        if (String.isBlank(value) || !value.trim().startsWith('005')) {
            return NULL;
        }
        try {
            return Id.valueOf(value.trim());
        } catch (Exception ex) {
            return NULL;
        }
    }
}