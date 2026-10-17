trigger InvoiceLineTrigger_CC on InvoiceLine(before insert, before update, before delete, after insert, after update, after delete, after undelete) {
	InvoiceLineTriggerHandler_CC handler = new InvoiceLineTriggerHandler_CC();
	handler.run(handler);
}