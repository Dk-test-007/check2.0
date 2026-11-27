trigger OrderTrigger_CC on Order (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    new OrderTriggerHandler_CC().run();
}