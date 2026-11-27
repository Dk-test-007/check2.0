trigger ContactTrigger_CC on Contact (before insert,before update,before delete, After insert, After Update, after undelete) {
    ContactTriggerHandler_CC handler = new ContactTriggerHandler_CC();
    handler.run(handler);
}