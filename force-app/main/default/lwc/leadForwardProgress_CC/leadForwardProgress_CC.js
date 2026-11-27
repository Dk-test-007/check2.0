import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import canConvertLeads from '@salesforce/userPermission/ConvertLeads';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';
import IS_CONVERTED_FIELD from '@salesforce/schema/Lead.IsConverted';
import NEXT_STEP_FIELD from '@salesforce/schema/Lead.Stage_Progress_Message_CC__c';

const QUALIFIED = 'Qualified';
/** Stages of the forward path, in order. Each step value is the Lead Status it represents. */
const STAGES = ['Identify', 'Qualify', 'Engage', QUALIFIED];
/** Start of the Next Step text LeadStageTransitionService_CC stores when nothing is left before conversion. */
export const READY_PREFIX = 'Ready to convert';

/**
 * Lead UI pilot stage bar: Identify -> Qualify -> Engage -> Qualified. Read-only: Status is never changed by clicking
 * it, and the bar follows Status alone (LeadStageTransitionService_CC sets Status from the fields).
 *
 * Meeting Outcome does not move the bar. A Lead at Engage stays at Engage until its Status changes, whichever outcome
 * was recorded, so Qualified, Disqualified and Re-Nurture outcomes behave the same way.
 *
 * Disqualified and Re-Nurture are outcomes of Engage, not stages (28 Oct decision): both are shown identically, with
 * no step current or complete, and the outcome banner states the status. lightning-progress-indicator marks its first
 * step current when current-step is unset, so a static step list is rendered for them instead.
 *
 * The bar does not convert. Users convert with the standard Convert button in the page header.
 */
export default class LeadForwardProgress_CC extends LightningElement {
    @api recordId;

    status;
    converted = false;
    nextStep;

    @wire(getRecord, {
        recordId: '$recordId',
        fields: [STATUS_FIELD, IS_CONVERTED_FIELD],
        optionalFields: [NEXT_STEP_FIELD]
    })
    wiredRecord({ data }) {
        if (!data) {
            return;
        }
        this.status = getFieldValue(data, STATUS_FIELD);
        this.converted = Boolean(getFieldValue(data, IS_CONVERTED_FIELD));
        this.nextStep = getFieldValue(data, NEXT_STEP_FIELD);
    }

    get steps() {
        return STAGES.map((value) => ({ label: value, value }));
    }

    get isQualified() {
        return this.status === QUALIFIED && !this.converted;
    }

    get readyToConvert() {
        return this.isQualified && typeof this.nextStep === 'string' && this.nextStep.startsWith(READY_PREFIX);
    }

    get canConvert() {
        // Boolean in Salesforce; the Jest transformer substitutes a truthy string when the import is not mocked.
        return Boolean(canConvertLeads);
    }

    get currentStep() {
        if (this.converted) {
            return QUALIFIED;
        }
        return STAGES.includes(this.status) ? this.status : undefined;
    }

    get isDisposition() {
        return Boolean(this.status) && !this.currentStep;
    }

    get dispositionLabel() {
        return 'Status ' + this.status + ': not on the forward path, so no stage is current.';
    }

    get convertNote() {
        if (this.readyToConvert) {
            return this.canConvert
                ? 'Qualified: ready to convert. Use the Convert button at the top of the page.'
                : 'Qualified: ready to convert. A Sales user converts it.';
        }
        return this.isQualified ? 'Qualified: complete the fields in Next Step, then convert.' : null;
    }
}