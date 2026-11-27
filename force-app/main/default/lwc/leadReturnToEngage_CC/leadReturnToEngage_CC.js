import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getContext from '@salesforce/apex/LeadReturnToEngageAction_CC.getContext';
import returnToEngage from '@salesforce/apex/LeadReturnToEngageAction_CC.returnToEngage';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';

const VIEW = 'view';
const CONFIRM = 'confirm';

/**
 * Lead UI pilot: Return to Engage card in the record page side panel, shown at Re-Nurture.
 * Asks for confirmation, then saves through LeadReturnToEngageAction_CC, which re-checks permission, Sales
 * authorisation, record access, the Engage gate and duplicates. Cancel writes nothing. After the save the record is
 * refreshed, so the banner, forward progress and stage panels follow the new Status.
 */
export default class LeadReturnToEngage_CC extends LightningElement {
    @api recordId;

    context;
    step = VIEW;
    error;
    saving = false;
    loadedStatus;

    @wire(getRecord, { recordId: '$recordId', fields: [STATUS_FIELD] })
    wiredRecord({ data }) {
        const status = data ? getFieldValue(data, STATUS_FIELD) : undefined;
        if (data && status !== this.loadedStatus) {
            this.loadedStatus = status;
            this.loadContext();
        }
    }

    async loadContext() {
        try {
            this.context = await getContext({ leadId: this.recordId });
            this.error = undefined;
        } catch (e) {
            this.context = undefined;
            this.error = messageOf(e);
        }
    }

    get isView() {
        return this.step === VIEW;
    }
    get isConfirm() {
        return this.step === CONFIRM;
    }
    get canReturn() {
        return this.context?.canReturn === true;
    }
    get blockedMessage() {
        return this.context && !this.context.canReturn ? this.context.message : undefined;
    }
    get companyName() {
        return this.context?.company || 'this Lead';
    }

    handleStart() {
        this.error = undefined;
        this.step = CONFIRM;
    }

    handleCancel() {
        this.step = VIEW;
        this.error = undefined;
    }

    async handleConfirm() {
        this.saving = true;
        this.error = undefined;
        try {
            await returnToEngage({ leadId: this.recordId });
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new ShowToastEvent({ title: 'Lead returned to Engage', message: this.companyName, variant: 'success' }));
            this.step = VIEW;
        } catch (e) {
            this.error = messageOf(e);
            this.step = VIEW;
        } finally {
            this.saving = false;
        }
    }
}

function messageOf(error) {
    return error?.body?.message || error?.message || 'The Lead could not be returned to Engage.';
}