trigger InvoiceTrigger_CC on Invoice (before insert,before update,before delete, After insert, After Update, after undelete) {
    InvoiceTriggerHandler_CC handler = new InvoiceTriggerHandler_CC();
    handler.run(handler);
}