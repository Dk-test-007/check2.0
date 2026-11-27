import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getContext from '@salesforce/apex/LeadDisqualifyAction_CC.getContext';
import disqualify from '@salesforce/apex/LeadDisqualifyAction_CC.disqualify';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';

const VIEW = 'view';
const FORM = 'form';
const CONFIRM = 'confirm';

/**
 * Lead UI pilot: Disqualify card in the record page side panel.
 * Collects reason and comments, asks for confirmation, then saves through LeadDisqualifyAction_CC, which
 * re-checks record and field access, record state and inputs. Cancel and Back write nothing.
 */
export default class LeadDisqualifyAction_CC extends LightningElement {
    @api recordId;

    context;
    step = VIEW;
    reason;
    comments;
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
    get isForm() {
        return this.step === FORM;
    }
    get isConfirm() {
        return this.step === CONFIRM;
    }
    get canDisqualify() {
        return this.context?.canDisqualify === true;
    }
    get blockedMessage() {
        return this.context && !this.context.canDisqualify ? this.context.message : undefined;
    }
    get reasonOptions() {
        return this.context?.reasons || [];
    }
    get commentsRequired() {
        return this.reason === this.context?.otherReasonValue;
    }
    get commentsLabel() {
        return this.commentsRequired ? 'Disqualification Comments (required for Other)' : 'Disqualification Comments';
    }
    get maxLength() {
        return this.context?.commentsMaxLength;
    }
    get reasonLabel() {
        const match = this.reasonOptions.find((option) => option.value === this.reason);
        return match ? match.label : this.reason;
    }
    get companyName() {
        return this.context?.company || 'this Lead';
    }
    get hasComments() {
        return Boolean(this.comments && this.comments.trim());
    }

    handleStart() {
        this.reason = this.context?.currentReason;
        this.comments = this.context?.currentComments;
        this.error = undefined;
        this.step = FORM;
    }

    handleReason(event) {
        this.reason = event.detail.value;
    }

    handleComments(event) {
        this.comments = event.detail.value;
    }

    handleReview() {
        // Show the field messages, but decide here: a required textarea accepts whitespace-only comments.
        this.template.querySelectorAll('lightning-combobox, lightning-textarea').forEach((input) => input.reportValidity());
        if (!this.reason) {
            this.error = 'Choose a Disqualified Reason.';
        } else if (this.commentsRequired && !this.hasComments) {
            this.error = 'Enter Disqualification Comments when the reason is Other.';
        } else {
            this.error = undefined;
            this.step = CONFIRM;
        }
    }

    handleBack() {
        this.step = FORM;
    }

    handleCancel() {
        this.step = VIEW;
        this.reason = undefined;
        this.comments = undefined;
        this.error = undefined;
    }

    async handleConfirm() {
        this.saving = true;
        this.error = undefined;
        try {
            await disqualify({ leadId: this.recordId, reason: this.reason, comments: this.comments });
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new ShowToastEvent({ title: 'Lead disqualified', message: this.reasonLabel, variant: 'success' }));
            this.handleCancel();
        } catch (e) {
            this.error = messageOf(e);
            this.step = FORM;
        } finally {
            this.saving = false;
        }
    }
}

function messageOf(error) {
    return error?.body?.message || error?.message || 'The Lead could not be disqualified.';
}