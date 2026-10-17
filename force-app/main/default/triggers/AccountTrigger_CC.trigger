trigger AccountTrigger_CC on Account (before insert,before update,before delete, After insert, After Update, after undelete) {
    AccountTriggerHandler_CC handler = new AccountTriggerHandler_CC();
    handler.run(handler);
}