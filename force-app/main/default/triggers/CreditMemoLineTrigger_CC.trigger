trigger CreditMemoLineTrigger_CC on CreditMemoLine(before insert, before update, before delete, after insert, after delete, after update, after undelete) {
	CreditMemoLineTriggerHandler_CC handler = new CreditMemoLineTriggerHandler_CC();
    handler.run(handler);
}