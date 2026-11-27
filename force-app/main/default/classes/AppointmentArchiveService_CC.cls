/**
 * =============================================================================
 * Class Name    : AppointmentArchiveService_CC
 * Description   : On delete of an Event, recreates it as a new record with
 *                 Status_CC__c = 'Cancelled' and the original CreatedDate /
 *                 LastModifiedDate preserved.
 *
 * Author        :
 * Created Date  :
 *
 * =============================================================================
 * Modification History
 * =============================================================================
 * Version    Date         Author           Description
 * -------    ----------   ------------     ---------------------------------------
 *    1                                     Initial build - before delete retention
 *
 * =============================================================================
 * Usage: Called from EventTriggerHandler_CC.beforeDelete().
 *
 * PREREQUISITE: the running user must hold "Set Audit Fields upon Record
 * Creation" (Appointment_Archive_Audit_Fields_CC permission set). Without it
 * the insert fails with "Field is not writeable: Event.CreatedDate".
 * =============================================================================
 */
public without sharing class AppointmentArchiveService_CC {

    private static final String  STATUS_CANCELLED = 'Cancelled';
    private static final Integer ALL_DAY_MINUTES  = 1440;

    /**
     * @param deletedEvents Trigger.old
     */
    public static void archiveDeletedEvents(List<Event> deletedEvents) {

        List<Event> archives = new List<Event>();

        for (Event original : deletedEvents) {

            // Recursion guard - deleting an archive must not create another.
            if (original.Archived_CC__c == true) {
                continue;
            }

            Event archive = new Event();

            archive.Subject     = original.Subject;
            archive.Description = original.Description;
            archive.Location    = original.Location;
            archive.Type        = original.Type;
            archive.WhoId       = original.WhoId;
            archive.WhatId      = original.WhatId;
            archive.OwnerId     = original.OwnerId;
            archive.ShowAs      = original.ShowAs;

            // Set EITHER Start/End OR ActivityDateTime + Duration, never both.
            archive.IsAllDayEvent = original.IsAllDayEvent;
            if (original.IsAllDayEvent == true) {
                archive.ActivityDateTime  = original.ActivityDateTime;
                archive.DurationInMinutes = ALL_DAY_MINUTES;
            } else {
                archive.StartDateTime = original.StartDateTime;
                archive.EndDateTime   = original.EndDateTime;
            }

            // Retention markers.
            archive.Status_CC__c            = STATUS_CANCELLED;
            archive.Archived_CC__c          = true;
            archive.Cancelled_on_CC__c      = System.now();
            archive.Original_Event_Id_CC__c = String.valueOf(original.Id);

            // Audit fields - permission dependent, see header.
            archive.CreatedDate      = original.CreatedDate;
            archive.CreatedById      = original.CreatedById;
            archive.LastModifiedDate = original.LastModifiedDate;
            archive.LastModifiedById = original.LastModifiedById;

            archives.add(archive);
        }

        if (!archives.isEmpty()) {
            insert archives;
        }
    }
}