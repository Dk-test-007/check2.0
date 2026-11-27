trigger EventTrigger_CC on Event (before insert, before update, before delete, after insert, after update, after delete, after undelete) {
    EventTriggerHandler_CC handler = new EventTriggerHandler_CC();
    handler.run(handler, 'Event');
}