trigger ContractTrigger_CC on Contract (before insert, after insert, before update, after update, before delete, after delete, after undelete) {
     new ContractTriggerHandler_CC().run();
}