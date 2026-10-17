trigger TaskTrigger_CC on Task (before insert, before update, before delete, after insert, after update, after delete, after undelete) {
    TaskTriggerHandler_CC handler = new TaskTriggerHandler_CC();
    handler.run(handler, 'Task');
}