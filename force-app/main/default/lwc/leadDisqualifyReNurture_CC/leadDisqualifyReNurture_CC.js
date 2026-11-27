import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LEAD_OBJECT from '@salesforce/schema/Lead';
import ID_FIELD from '@salesforce/schema/Lead.Id';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';
import IS_CONVERTED_FIELD from '@salesforce/schema/Lead.IsConverted';
import COMPANY_FIELD from '@salesforce/schema/Lead.Company';
import DQ_REASON_FIELD from '@salesforce/schema/Lead.Disqualified_Reason_CC__c';
import DQ_COMMENTS_FIELD from '@salesforce/schema/Lead.Disqualification_Comments_CC__c';
import RN_REASON_FIELD from '@salesforce/schema/Lead.Re_Nurture_Reason_CC__c';
import RN_COMMENTS_FIELD from '@salesforce/schema/Lead.Re_Nurture_Comments_CC__c';
import RN_DATE_FIELD from '@salesforce/schema/Lead.Reengagement_Date_CC__c';

const STATUS_QUALIFY = 'Qualify';
const STATUS_ENGAGE = 'Engage';
const STATUS_DISQUALIFIED = 'Disqualified';
const STATUS_RE_NURTURE = 'Re-Nurture';
const OTHER_REASON = 'Other';
const MASTER_RECORD_TYPE_ID = '012000000000000AAA';

// Optional so the card still loads on orgs where Lead has no record types.
const RECORD_TYPE_FIELD = 'Lead.RecordTypeId';

const VIEW = 'view';
const FORM = 'form';
const CONFIRM = 'confirm';
const DISQUALIFY = 'disqualify';
const RE_NURTURE = 'reNurture';

/**
 * @deprecated Replaced by leadMeetingOutcome_CC (Record Meeting Outcome), which records the Meeting Outcome at Engage
 * and asks for the stage fields in a popup. Kept only until it is removed from the org; do not add it to pages.
 *
 * Lead record page card offering two exit outcomes:
 *   - Disqualify: Lead at Qualify or Engage. Needs a Disqualified Reason; comments are required when the reason is Other.
 *   - Re-Nurture: Lead at Engage only. Needs a Re-Nurture Reason and Re-engagement Date; comments are required for Other.
 * The card renders nothing at any other status or once the Lead is converted.
 *
 * Saves through Lightning Data Service (updateRecord), so sharing, field-level security and the Lead trigger
 * (LeadTriggerHandler_CC_New / LeadStageTransitionService_CC) all apply exactly as for a record page save: stage
 * entry rules, the Sales-only outcome rule, metadata-driven required fields and the Re-Nurture owner reassignment.
 * Cancel and Back write nothing.
 */
export default class LeadDisqualifyReNurture_CC extends LightningElement {
    @api recordId;

    record;
    recordTypeId;
    disqualifyReasons = [];
    reNurtureReasons = [];
    objectInfo;

    step = VIEW;
    action;
    reason;
    comments;
    reengagementDate;
    error;
    saving = false;

    // ---------------------------------------------------------------- data

    @wire(getRecord, {
        recordId: '$recordId',
        fields: [STATUS_FIELD, IS_CONVERTED_FIELD, COMPANY_FIELD],
        optionalFields: [RECORD_TYPE_FIELD]
    })
    wiredRecord({ data, error }) {
        if (data) {
            const previousStatus = this.status;
            this.record = data;
            this.recordTypeId = data.recordTypeId || this.objectInfo?.defaultRecordTypeId || MASTER_RECORD_TYPE_ID;
            // A status change from elsewhere (record page edit, another component) resets any open form.
            if (previousStatus && previousStatus !== this.status) {
                this.reset();
            }
        } else if (error) {
            this.record = undefined;
            this.error = messageOf(error);
        }
    }

    @wire(getObjectInfo, { objectApiName: LEAD_OBJECT })
    wiredObjectInfo({ data }) {
        if (data) {
            this.objectInfo = data;
            if (!this.record?.recordTypeId) {
                this.recordTypeId = data.defaultRecordTypeId || MASTER_RECORD_TYPE_ID;
            }
        }
    }

    @wire(getPicklistValues, { recordTypeId: '$recordTypeId', fieldApiName: DQ_REASON_FIELD })
    wiredDisqualifyReasons({ data }) {
        this.disqualifyReasons = data ? toOptions(data.values) : [];
    }

    @wire(getPicklistValues, { recordTypeId: '$recordTypeId', fieldApiName: RN_REASON_FIELD })
    wiredReNurtureReasons({ data }) {
        this.reNurtureReasons = data ? toOptions(data.values) : [];
    }

    // ---------------------------------------------------------------- state

    get status() {
        return this.record ? getFieldValue(this.record, STATUS_FIELD) : undefined;
    }
    get isConverted() {
        return this.record ? getFieldValue(this.record, IS_CONVERTED_FIELD) === true : false;
    }
    get companyName() {
        return (this.record && getFieldValue(this.record, COMPANY_FIELD)) || 'this Lead';
    }
    get canDisqualify() {
        return !this.isConverted && (this.status === STATUS_QUALIFY || this.status === STATUS_ENGAGE);
    }
    get canReNurture() {
        return !this.isConverted && this.status === STATUS_ENGAGE;
    }
    get show() {
        return this.canDisqualify || this.saving || (!this.record && !!this.error);
    }

    get isView() {
        return this.step === VIEW;
    }
    get isConfirm() {
        return this.step === CONFIRM;
    }
    get isDisqualify() {
        return this.action === DISQUALIFY;
    }
    get isReNurture() {
        return this.action === RE_NURTURE;
    }
    get isDisqualifyForm() {
        return this.step === FORM && this.isDisqualify;
    }
    get isReNurtureForm() {
        return this.step === FORM && this.isReNurture;
    }

    // ---------------------------------------------------------------- labels

    get title() {
        if (this.isDisqualify && !this.isView) {
            return 'Disqualify Lead';
        }
        if (this.isReNurture && !this.isView) {
            return 'Re-Nurture Lead';
        }
        return this.canReNurture ? 'Disqualify or Re-Nurture' : 'Disqualify';
    }
    get iconName() {
        return this.isReNurture && !this.isView ? 'utility:refresh' : 'utility:ban';
    }
    get viewHelp() {
        return this.canReNurture
            ? 'Disqualify it if it will not go forward, or Re-Nurture it to revisit on a later date.'
            : 'Disqualify it if it will not go forward. Re-Nurture is available once the Lead reaches Engage.';
    }
    get disqualifyReasonOptions() {
        return this.disqualifyReasons;
    }
    get reNurtureReasonOptions() {
        return this.reNurtureReasons;
    }
    get reasonOptions() {
        return this.isDisqualify ? this.disqualifyReasons : this.reNurtureReasons;
    }
    get reasonLabel() {
        const match = this.reasonOptions.find((option) => option.value === this.reason);
        return match ? match.label : this.reason;
    }
    get commentsRequired() {
        return this.reason === OTHER_REASON;
    }
    get disqualifyCommentsLabel() {
        return this.commentsLabel(this.fieldLabel(DQ_COMMENTS_FIELD, 'Disqualification Comments'));
    }
    get reNurtureCommentsLabel() {
        return this.commentsLabel(this.fieldLabel(RN_COMMENTS_FIELD, 'Re-Nurture Comments'));
    }
    get disqualifyCommentsMaxLength() {
        return this.fieldLength(DQ_COMMENTS_FIELD);
    }
    get reNurtureCommentsMaxLength() {
        return this.fieldLength(RN_COMMENTS_FIELD);
    }
    get hasComments() {
        return Boolean(this.comments && this.comments.trim());
    }
    get today() {
        const now = new Date();
        const pad = (value) => String(value).padStart(2, '0');
        return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
    }
    get confirmLabel() {
        return this.isDisqualify ? 'Confirm Disqualify' : 'Confirm Re-Nurture';
    }
    get confirmVariant() {
        return this.isDisqualify ? 'destructive' : 'brand';
    }

    commentsLabel(base) {
        return this.commentsRequired ? `${base} (required for Other)` : base;
    }
    fieldLabel(field, fallback) {
        return this.objectInfo?.fields?.[field.fieldApiName]?.label || fallback;
    }
    fieldLength(field) {
        return this.objectInfo?.fields?.[field.fieldApiName]?.length || undefined;
    }

    // ---------------------------------------------------------------- handlers

    handleStartDisqualify() {
        this.start(DISQUALIFY);
    }

    handleStartReNurture() {
        this.start(RE_NURTURE);
    }

    start(action) {
        this.action = action;
        this.reason = undefined;
        this.comments = undefined;
        this.reengagementDate = undefined;
        this.error = undefined;
        this.step = FORM;
    }

    handleReason(event) {
        this.reason = event.detail.value;
    }

    handleComments(event) {
        this.comments = event.detail.value;
    }

    handleDate(event) {
        this.reengagementDate = event.detail.value;
    }

    handleReview() {
        // Show the field messages, but decide here: a required textarea accepts whitespace-only comments.
        const inputs = [...this.template.querySelectorAll('lightning-combobox, lightning-textarea, lightning-input')];
        const inputsValid = inputs.reduce((valid, input) => input.reportValidity() && valid, true);
        if (!this.reason) {
            this.error = this.isDisqualify ? 'Choose a Disqualified Reason.' : 'Choose a Re-Nurture Reason.';
        } else if (this.isReNurture && !this.reengagementDate) {
            this.error = 'Choose a Re-engagement Date.';
        } else if (this.commentsRequired && !this.hasComments) {
            this.error = 'Enter comments when the reason is Other.';
        } else if (!inputsValid) {
            this.error = 'Correct the highlighted fields.';
        } else {
            this.error = undefined;
            this.step = CONFIRM;
        }
    }

    handleBack() {
        this.error = undefined;
        this.step = FORM;
    }

    handleCancel() {
        this.reset();
    }

    async handleConfirm() {
        // Re-check against the latest status: the record may have changed since the form opened.
        if ((this.isDisqualify && !this.canDisqualify) || (this.isReNurture && !this.canReNurture)) {
            this.error = this.isDisqualify
                ? 'Only a Lead at Qualify or Engage can be disqualified.'
                : 'Only a Lead at Engage can be re-nurtured.';
            this.step = VIEW;
            return;
        }

        const comments = this.hasComments ? this.comments.trim() : null;
        const fields = { [ID_FIELD.fieldApiName]: this.recordId };
        if (this.isDisqualify) {
            fields[STATUS_FIELD.fieldApiName] = STATUS_DISQUALIFIED;
            fields[DQ_REASON_FIELD.fieldApiName] = this.reason;
            fields[DQ_COMMENTS_FIELD.fieldApiName] = comments;
        } else {
            fields[STATUS_FIELD.fieldApiName] = STATUS_RE_NURTURE;
            fields[RN_REASON_FIELD.fieldApiName] = this.reason;
            fields[RN_COMMENTS_FIELD.fieldApiName] = comments;
            fields[RN_DATE_FIELD.fieldApiName] = this.reengagementDate;
        }

        const successTitle = this.isDisqualify ? 'Lead disqualified' : 'Lead moved to Re-Nurture';
        const successMessage = `${this.companyName}: ${this.reasonLabel}`;
        this.saving = true;
        this.error = undefined;
        try {
            await updateRecord({ fields });
            this.dispatchEvent(new ShowToastEvent({ title: successTitle, message: successMessage, variant: 'success' }));
            this.reset();
        } catch (e) {
            this.error = messageOf(e);
            this.step = FORM;
        } finally {
            this.saving = false;
        }
    }

    reset() {
        this.step = VIEW;
        this.action = undefined;
        this.reason = undefined;
        this.comments = undefined;
        this.reengagementDate = undefined;
        this.error = undefined;
    }
}

function toOptions(values) {
    return (values || []).map((value) => ({ label: value.label, value: value.value }));
}

/** Flattens LDS / UI API errors (record errors, field errors, trigger addError messages) into one readable line. */
function messageOf(error) {
    const messages = [];
    const body = error?.body;
    (body?.output?.errors || []).forEach((item) => messages.push(item.message));
    Object.values(body?.output?.fieldErrors || {}).forEach((list) =>
        (list || []).forEach((item) => messages.push(item.message))
    );
    if (!messages.length && Array.isArray(body)) {
        body.forEach((item) => messages.push(item.message));
    }
    if (!messages.length && body?.message) {
        messages.push(body.message);
    }
    if (!messages.length && error?.message) {
        messages.push(error.message);
    }
    const unique = [...new Set(messages.filter(Boolean))];
    return unique.length ? unique.join(' ') : 'The Lead could not be saved.';
}