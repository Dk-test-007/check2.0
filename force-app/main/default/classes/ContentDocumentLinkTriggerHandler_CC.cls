/**
 * =============================================================================
 * Class Name    : ContentDocumentLinkTriggerHandler_CC
 * Description   : Trigger handler for ContentDocumentLink object
 *
 * Author        : Nipun Jain
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author             Description
 * -------    ----------   -----------------  -----------------------------------
 *
 * =============================================================================
 * Usage:
 * Central trigger handler for ContentDocumentLink object.
 * =============================================================================
 * Prerequisites
 * =============================================================================
 */

public class ContentDocumentLinkTriggerHandler_CC extends BaseTriggerHandler_CC {

    public void run() {
        super.run(this, 'ContentDocumentLink');
    }

    public override void beforeInsert() {
        checkForClosedCaseError((List<ContentDocumentLink>) Trigger.new);
    }

    public override void afterInsert() {
        handleLinksInserted((List<ContentDocumentLink>) Trigger.new);
    }

    public override void afterDelete() {
        handleLinksDeleted((List<ContentDocumentLink>) Trigger.old);
    }

    private static final String NOTE_FILE_TYPE     = 'SNOTE'; // FileType of Enhanced Notes
    private static final String SHARE_TYPE         = 'I';     // Inferred: access follows the related record
    private static final String DEFAULT_VISIBILITY = 'AllUsers';

    private void handleLinksInserted(List<ContentDocumentLink> links) {
        Set<Id> documentIds = new Set<Id>();

        for (ContentDocumentLink cdl : links) {
            if (isActivityId(cdl.LinkedEntityId)) {
                documentIds.add(cdl.ContentDocumentId);
            }
        }

        if (!documentIds.isEmpty()) {
            syncNotes(documentIds, new Map<Id, Set<Id>>());
        }
    }

    private void handleLinksDeleted(List<ContentDocumentLink> links) {
        Map<Id, Set<Id>> removedActivityIdsByDocument = new Map<Id, Set<Id>>();
        Set<Id> activityIds = new Set<Id>();

        for (ContentDocumentLink cdl : links) {
            if (isActivityId(cdl.LinkedEntityId)) {
                getOrCreate(removedActivityIdsByDocument, cdl.ContentDocumentId).add(cdl.LinkedEntityId);
                activityIds.add(cdl.LinkedEntityId);
            }
        }

        if (activityIds.isEmpty()) {
            return;
        }

        // The records the removed activities are related to are candidates for removal
        Map<Id, Set<Id>> relatedRecordsByActivity = getRelatedRecordsByActivity(activityIds);
        Map<Id, Set<Id>> removalCandidatesByDocument = new Map<Id, Set<Id>>();

        for (Id documentId : removedActivityIdsByDocument.keySet()) {
            for (Id activityId : removedActivityIdsByDocument.get(documentId)) {
                if (relatedRecordsByActivity.containsKey(activityId)) {
                    getOrCreate(removalCandidatesByDocument, documentId).addAll(relatedRecordsByActivity.get(activityId));
                }
            }
        }

        if (!removalCandidatesByDocument.isEmpty()) {
            syncNotes(removalCandidatesByDocument.keySet(), removalCandidatesByDocument);
        }
    }

    /**
     * For each Note, works out which records it should be attached to (the WhatId/WhoId
     * of every activity it is currently on), adds missing links, and removes links to the
     * given candidate records that are no longer justified by any remaining activity.
     */
    private void syncNotes(Set<Id> documentIds, Map<Id, Set<Id>> removalCandidatesByDocument) {
        // 1. Only process Notes, not regular files
        Set<Id> noteIds = new Map<Id, ContentDocument>([
            SELECT Id
            FROM ContentDocument
            WHERE Id IN :documentIds AND FileType = :NOTE_FILE_TYPE
        ]).keySet();

        if (noteIds.isEmpty()) {
            return;
        }

        // 2. Current links of each Note, and the activities it is attached to
        Map<Id, Map<Id, ContentDocumentLink>> linksByNote = new Map<Id, Map<Id, ContentDocumentLink>>();
        Set<Id> activityIds = new Set<Id>();

        for (ContentDocumentLink cdl : [
            SELECT Id, ContentDocumentId, LinkedEntityId, Visibility
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :noteIds
        ]) {
            if (!linksByNote.containsKey(cdl.ContentDocumentId)) {
                linksByNote.put(cdl.ContentDocumentId, new Map<Id, ContentDocumentLink>());
            }
            linksByNote.get(cdl.ContentDocumentId).put(cdl.LinkedEntityId, cdl);

            if (isActivityId(cdl.LinkedEntityId)) {
                activityIds.add(cdl.LinkedEntityId);
            }
        }

        // 3. Records each activity is related to (WhatId and WhoId)
        Map<Id, Set<Id>> relatedRecordsByActivity = getRelatedRecordsByActivity(activityIds);

        List<ContentDocumentLink> linksToInsert = new List<ContentDocumentLink>();
        List<ContentDocumentLink> linksToDelete = new List<ContentDocumentLink>();

        for (Id noteId : noteIds) {
            Map<Id, ContentDocumentLink> currentLinks = linksByNote.containsKey(noteId)
                ? linksByNote.get(noteId)
                : new Map<Id, ContentDocumentLink>();

            // Records the Note should be on, based on the activities it is still attached to
            Set<Id> desiredRecords = new Set<Id>();
            String visibility = DEFAULT_VISIBILITY;

            for (Id entityId : currentLinks.keySet()) {
                if (relatedRecordsByActivity.containsKey(entityId)) {
                    desiredRecords.addAll(relatedRecordsByActivity.get(entityId));
                    if (String.isNotBlank(currentLinks.get(entityId).Visibility)) {
                        visibility = currentLinks.get(entityId).Visibility;
                    }
                }
            }

            // 4. Attach to related records the Note isn't on yet
            for (Id recordId : desiredRecords) {
                if (!currentLinks.containsKey(recordId)) {
                    linksToInsert.add(new ContentDocumentLink(
                        ContentDocumentId = noteId,
                        LinkedEntityId    = recordId,
                        ShareType         = SHARE_TYPE,
                        Visibility        = visibility
                    ));
                }
            }

            // 5. Remove from related records that no remaining activity justifies
            Set<Id> candidates = removalCandidatesByDocument.get(noteId);
            if (candidates != null) {
                for (Id recordId : candidates) {
                    if (!desiredRecords.contains(recordId)
                        && currentLinks.containsKey(recordId)
                        && !isActivityId(recordId)) {
                        linksToDelete.add(currentLinks.get(recordId));
                    }
                }
            }
        }

        // 6. Partial success so one failing record doesn't block the rest of the batch
        if (!linksToDelete.isEmpty()) {
            logDeleteErrors(Database.delete(linksToDelete, false), linksToDelete);
        }
        if (!linksToInsert.isEmpty()) {
            logInsertErrors(Database.insert(linksToInsert, false), linksToInsert);
        }
    }

    private Map<Id, Set<Id>> getRelatedRecordsByActivity(Set<Id> activityIds) {
        Map<Id, Set<Id>> relatedRecordsByActivity = new Map<Id, Set<Id>>();
        Set<Id> taskIds = new Set<Id>();
        Set<Id> eventIds = new Set<Id>();

        for (Id activityId : activityIds) {
            if (activityId.getSObjectType() == Task.SObjectType) {
                taskIds.add(activityId);
            } else {
                eventIds.add(activityId);
            }
        }

        if (!taskIds.isEmpty()) {
            for (Task t : [SELECT Id, WhatId, WhoId FROM Task WHERE Id IN :taskIds]) {
                relatedRecordsByActivity.put(t.Id, toRecordSet(t.WhatId, t.WhoId));
            }
        }

        if (!eventIds.isEmpty()) {
            for (Event e : [SELECT Id, WhatId, WhoId FROM Event WHERE Id IN :eventIds]) {
                relatedRecordsByActivity.put(e.Id, toRecordSet(e.WhatId, e.WhoId));
            }
        }

        return relatedRecordsByActivity;
    }

    private Set<Id> toRecordSet(Id whatId, Id whoId) {
        Set<Id> records = new Set<Id>();
        if (whatId != null) {
            records.add(whatId);
        }
        if (whoId != null) {
            records.add(whoId);
        }
        return records;
    }

    private Boolean isActivityId(Id recordId) {
        if (recordId == null) {
            return false;
        }
        Schema.SObjectType recordType = recordId.getSObjectType();
        return recordType == Task.SObjectType || recordType == Event.SObjectType;
    }

    private Set<Id> getOrCreate(Map<Id, Set<Id>> target, Id key) {
        if (!target.containsKey(key)) {
            target.put(key, new Set<Id>());
        }
        return target.get(key);
    }

    private void logInsertErrors(List<Database.SaveResult> results, List<ContentDocumentLink> links) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    System.debug(LoggingLevel.ERROR, 'ContentDocumentLinkTriggerHandler_CC: Failed to attach Note ' +
                        links[i].ContentDocumentId + ' to record ' + links[i].LinkedEntityId + ': ' + err.getMessage());
                }
            }
        }
    }

    private void logDeleteErrors(List<Database.DeleteResult> results, List<ContentDocumentLink> links) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    System.debug(LoggingLevel.ERROR, 'ContentDocumentLinkTriggerHandler_CC: Failed to remove Note ' +
                        links[i].ContentDocumentId + ' from record ' + links[i].LinkedEntityId + ': ' + err.getMessage());
                }
            }
        }
    }


    public static void checkForClosedCaseError(List<ContentDocumentLink> cdlList) {
        Set<Id> caseIds = new Set<Id>();

        for(ContentDocumentLink cdl: cdlList) {
            if(String.valueOf(cdl.LinkedEntityId).startsWith('500')) {
                caseIds.add(cdl.LinkedEntityId);
            }
        }

        Map<Id, Case> caseMap = new Map<Id, Case>([SELECT Id, IsClosed FROM Case WHERE Id IN: caseIds]);
        for(ContentDocumentLink cdl: cdlList) {
            if(caseMap.containsKey(cdl.LinkedEntityId) && caseMap.get(cdl.LinkedEntityId).IsClosed) {
                cdl.addError('You cannot upload a file to a closed Case.');
            }
        }
    }
}