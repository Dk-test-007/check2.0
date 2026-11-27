import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, getFieldDisplayValue } from 'lightning/uiRecordApi';
import getStatusSince from '@salesforce/apex/LeadOutcomeBannerController_CC.getStatusSince';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';
import SYSTEM_MODSTAMP_FIELD from '@salesforce/schema/Lead.SystemModstamp';
import DISQUALIFIED_REASON_FIELD from '@salesforce/schema/Lead.Disqualified_Reason_CC__c';
import DISQUALIFIED_COMMENTS_FIELD from '@salesforce/schema/Lead.Disqualification_Comments_CC__c';
import RE_NURTURE_REASON_FIELD from '@salesforce/schema/Lead.Re_Nurture_Reason_CC__c';
import RE_NURTURE_COMMENTS_FIELD from '@salesforce/schema/Lead.Re_Nurture_Comments_CC__c';
import REENGAGEMENT_DATE_FIELD from '@salesforce/schema/Lead.Reengagement_Date_CC__c';

const DISQUALIFIED = 'Disqualified';
const RE_NURTURE = 'Re-Nurture';
// Optional so a user without access to one field still sees the rest of the banner.
const FIELDS = [DISQUALIFIED_REASON_FIELD, DISQUALIFIED_COMMENTS_FIELD, RE_NURTURE_REASON_FIELD,
    RE_NURTURE_COMMENTS_FIELD, REENGAGEMENT_DATE_FIELD];

/**
 * Lead UI pilot: banner shown only for an actual Disqualified or Re-Nurture status, with the saved reason,
 * comments, re-engagement date and the date the status was recorded in field history (blank when not recorded).
 * It shows what is on the record; it does not infer an earlier stage or mark any stage complete.
 */
export default class LeadOutcomeBanner_CC extends LightningElement {
    @api recordId;

    record;
    status;
    since;
    sinceLoaded = false;
    // Wire inputs. recordVersion (SystemModstamp) keys the cached Apex result, so a second Re-Nurture or Disqualified
    // entry is looked up again rather than showing the first entry's cached date. Set only while a banner shows.
    sinceStatus;
    recordVersion;

    @wire(getRecord, { recordId: '$recordId', fields: [STATUS_FIELD, SYSTEM_MODSTAMP_FIELD], optionalFields: FIELDS })
    wiredRecord({ data }) {
        this.record = data;
        this.status = data ? getFieldValue(data, STATUS_FIELD) : undefined;
        const version = data ? getFieldValue(data, SYSTEM_MODSTAMP_FIELD) : undefined;
        const sinceStatus = this.show ? this.status : undefined;
        if (sinceStatus !== this.sinceStatus || version !== this.recordVersion) {
            // Never keep showing a date that belonged to an earlier save or cycle.
            this.since = undefined;
            this.sinceLoaded = false;
            this.sinceStatus = sinceStatus;
            this.recordVersion = version;
        }
    }

    @wire(getStatusSince, { leadId: '$recordId', status: '$sinceStatus', recordVersion: '$recordVersion' })
    wiredSince({ data, error }) {
        if (data !== undefined || error) {
            this.since = error ? undefined : data;
            this.sinceLoaded = true;
        }
    }

    get sinceUnknown() {
        return this.sinceLoaded && !this.since;
    }

    get show() {
        return this.isDisqualified || this.isReNurture;
    }
    get isDisqualified() {
        return this.status === DISQUALIFIED;
    }
    get isReNurture() {
        return this.status === RE_NURTURE;
    }
    get bannerClass() {
        return 'slds-notify slds-notify_alert ' + (this.isDisqualified ? 'slds-alert_error' : 'slds-alert_warning');
    }
    get iconName() {
        return this.isDisqualified ? 'utility:ban' : 'utility:refresh';
    }
    get heading() {
        return this.isDisqualified ? 'Disqualified' : 'Re-Nurture';
    }
    get reason() {
        return this.display(this.isDisqualified ? DISQUALIFIED_REASON_FIELD : RE_NURTURE_REASON_FIELD);
    }
    get comments() {
        return this.display(this.isDisqualified ? DISQUALIFIED_COMMENTS_FIELD : RE_NURTURE_COMMENTS_FIELD);
    }
    get reengagementDate() {
        return this.isReNurture ? this.display(REENGAGEMENT_DATE_FIELD) : undefined;
    }

    display(field) {
        if (!this.record) {
            return undefined;
        }
        return getFieldDisplayValue(this.record, field) || getFieldValue(this.record, field) || undefined;
    }
}