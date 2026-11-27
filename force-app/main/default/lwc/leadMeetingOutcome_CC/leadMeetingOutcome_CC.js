import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LeadMeetingOutcomeModal from 'c/leadMeetingOutcomeModal_CC';
import LEAD_OBJECT from '@salesforce/schema/Lead';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';
import IS_CONVERTED_FIELD from '@salesforce/schema/Lead.IsConverted';
import COMPANY_FIELD from '@salesforce/schema/Lead.Company';
import OUTCOME_FIELD from '@salesforce/schema/Lead.Meeting_Outcome_CC__c';
import SUB_REASON_FIELD from '@salesforce/schema/Lead.Meeting_Outcome_Sub_Reason_CC__c';

const STATUS_QUALIFY = 'Qualify';
const STATUS_ENGAGE = 'Engage';
const MASTER_RECORD_TYPE_ID = '012000000000000AAA';
// Optional so the card still loads on orgs where Lead has no record types.
const RECORD_TYPE_FIELD = 'Lead.RecordTypeId';

/** Meeting Outcome value -> Lead_Stage_CC__mdt record name of the stage it moves the Lead to. */
const STAGE_BY_OUTCOME = {
    Qualified: 'Qualified',
    Disqualified: 'Disqualified',
    'Re-Nurture': 'Re_Nurture'
};
const STAGE_DISQUALIFIED = 'Disqualified';

const SUCCESS_TITLE = {
    Qualified: 'Lead moved to Qualified',
    Disqualified: 'Lead disqualified',
    Re_Nurture: 'Lead moved to Re-Nurture'
};

/**
 * Record Meeting Outcome: Lead record page card. Replaces Lead Disqualify / Re-Nurture (leadDisqualifyReNurture_CC).
 *
 *   - Qualify: a Disqualify button. The popup asks for the Disqualified fields.
 *   - Engage: the user records the Meeting Outcome (Qualified, Disqualified or Re-Nurture) and its optional Sub Reason, then
 *     Continue opens the popup (leadMeetingOutcomeModal_CC) with the fields the Lead stage metadata requires for that
 *     stage. Saving the popup moves the Lead to Qualified, Disqualified or Re-Nurture in one save.
 * The card renders nothing at any other status or once the Lead is converted.
 *
 * Nothing is written until the popup is saved: cancelling the popup leaves the Lead unchanged. The save goes through
 * Lightning Data Service, so the Lead trigger (LeadTriggerHandler_CC_New / LeadStageTransitionService_CC) enforces the
 * stage rules, the Sales-only outcome rule and the required fields exactly as for a record page save.
 */
export default class LeadMeetingOutcome_CC extends LightningElement {
    @api recordId;

    record;
    recordTypeId;
    objectInfo;
    outcomeOptions = [];

    outcome;
    subReason;
    error;
    opening = false;

    // ---------------------------------------------------------------- data

    @wire(getRecord, {
        recordId: '$recordId',
        fields: [STATUS_FIELD, IS_CONVERTED_FIELD, COMPANY_FIELD],
        optionalFields: [OUTCOME_FIELD, SUB_REASON_FIELD, RECORD_TYPE_FIELD]
    })
    wiredRecord({ data, error }) {
        if (data) {
            const previousStatus = this.status;
            this.record = data;
            this.recordTypeId = data.recordTypeId || this.objectInfo?.defaultRecordTypeId || MASTER_RECORD_TYPE_ID;
            // First load, or a status change from elsewhere: start from what is stored on the Lead.
            if (!previousStatus || previousStatus !== this.status) {
                this.resetInputs();
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

    @wire(getPicklistValues, { recordTypeId: '$recordTypeId', fieldApiName: OUTCOME_FIELD })
    wiredOutcomes({ data }) {
        // Only the outcomes this card can act on, in picklist order.
        this.outcomeOptions = data
            ? data.values.filter((value) => STAGE_BY_OUTCOME[value.value]).map((value) => ({ label: value.label, value: value.value }))
            : [];
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
    get isQualify() {
        return !this.isConverted && this.status === STATUS_QUALIFY;
    }
    get isEngage() {
        return !this.isConverted && this.status === STATUS_ENGAGE;
    }
    get show() {
        return this.isQualify || this.isEngage || (!this.record && !!this.error);
    }

    // ---------------------------------------------------------------- labels

    get title() {
        return this.isEngage ? 'Record Meeting Outcome' : 'Disqualify';
    }
    get iconName() {
        return this.isEngage ? 'utility:event' : 'utility:ban';
    }
    get outcomeLabel() {
        return this.fieldLabel(OUTCOME_FIELD, 'Meeting Outcome');
    }
    get subReasonLabel() {
        return this.fieldLabel(SUB_REASON_FIELD, 'Meeting Outcome Sub Reason');
    }
    get subReasonMaxLength() {
        return this.objectInfo?.fields?.[SUB_REASON_FIELD.fieldApiName]?.length || 255;
    }
    get continueDisabled() {
        return this.opening;
    }

    fieldLabel(field, fallback) {
        return this.objectInfo?.fields?.[field.fieldApiName]?.label || fallback;
    }

    // ---------------------------------------------------------------- handlers

    handleOutcome(event) {
        this.outcome = event.detail.value;
        this.error = undefined;
    }

    handleSubReason(event) {
        this.subReason = event.detail.value;
    }

    handleDisqualify() {
        this.openPopup(STAGE_DISQUALIFIED, null, null);
    }

    handleContinue() {
        const inputs = [...this.template.querySelectorAll('lightning-combobox, lightning-textarea')];
        const inputsValid = inputs.reduce((valid, input) => input.reportValidity() && valid, true);
        // Sub Reason is optional.
        const subReason = (this.subReason || '').trim() || null;
        if (!this.outcome) {
            this.error = `Choose a ${this.outcomeLabel}.`;
        } else if (!inputsValid) {
            this.error = 'Correct the highlighted fields.';
        } else {
            this.error = undefined;
            this.openPopup(STAGE_BY_OUTCOME[this.outcome], this.outcome, subReason);
        }
    }

    async openPopup(targetStage, meetingOutcome, subReason) {
        this.opening = true;
        try {
            const result = await LeadMeetingOutcomeModal.open({
                size: 'medium',
                description: 'Fields required to move this Lead',
                recordId: this.recordId,
                targetStage,
                meetingOutcome,
                subReason,
                companyName: this.companyName
            });
            if (result === 'saved') {
                this.dispatchEvent(new ShowToastEvent({
                    title: SUCCESS_TITLE[targetStage],
                    message: this.companyName,
                    variant: 'success'
                }));
            }
        } finally {
            this.opening = false;
        }
    }

    resetInputs() {
        const storedOutcome = this.record ? getFieldValue(this.record, OUTCOME_FIELD) : undefined;
        // An outcome retired from the picklist is not offered again; the user records a current one.
        this.outcome = STAGE_BY_OUTCOME[storedOutcome] ? storedOutcome : undefined;
        this.subReason = this.record ? getFieldValue(this.record, SUB_REASON_FIELD) || undefined : undefined;
        this.error = undefined;
    }
}

/** Flattens LDS / UI API errors into one readable line. */
function messageOf(error) {
    const body = error?.body;
    if (Array.isArray(body)) {
        return body.map((item) => item.message).filter(Boolean).join(' ') || 'The Lead could not be loaded.';
    }
    return body?.message || error?.message || 'The Lead could not be loaded.';
}