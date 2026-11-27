trigger OrderItemTrigger_CC on OrderItem (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
    new OrderItemTriggerHandler_CC().run();
}