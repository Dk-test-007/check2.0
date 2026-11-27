import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getContext from '@salesforce/apex/LeadRestartAtIdentifyAction_CC.getContext';
import restart from '@salesforce/apex/LeadRestartAtIdentifyAction_CC.restart';
import confirmReview from '@salesforce/apex/LeadRestartAtIdentifyAction_CC.confirmReview';
import STATUS_FIELD from '@salesforce/schema/Lead.Status';
import SYSTEM_MODSTAMP_FIELD from '@salesforce/schema/Lead.SystemModstamp';

const VIEW = 'view';
const CONFIRM = 'confirm';
const IDENTITY = 'identity';

/**
 * Lead UI pilot reactivation card (record page side panel).
 * At Re-Nurture: Restart at Qualify, with a required reason, confirmation and Cancel (writes nothing).
 * At Identify / Qualify after a restart: the review this cycle still needs, with a Confirm button.
 * Renders nothing when neither applies. LeadRestartAtIdentifyAction_CC re-checks everything on the server.
 */
export default class LeadRestartAtIdentify_CC extends LightningElement {
    @api recordId;

    context;
    step = VIEW;
    note = '';
    error;
    saving = false;
    loadedVersion;

    @wire(getRecord, { recordId: '$recordId', fields: [STATUS_FIELD, SYSTEM_MODSTAMP_FIELD] })
    wiredRecord({ data }) {
        if (!data) {
            return;
        }
        const version = getFieldValue(data, STATUS_FIELD) + '|' + getFieldValue(data, SYSTEM_MODSTAMP_FIELD);
        if (version !== this.loadedVersion) {
            this.loadedVersion = version;
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

    get isReNurture() {
        return this.context?.status === 'Re-Nurture';
    }
    get hasReview() {
        return !!this.context?.pendingReview;
    }
    get show() {
        return this.isReNurture || this.hasReview || !!this.error;
    }
    get title() {
        return this.hasReview ? 'Restarted Lead: review this cycle' : 'Restart at Qualify';
    }
    get isView() {
        return this.step === VIEW;
    }
    get isConfirm() {
        return this.step === CONFIRM;
    }
    get canRestart() {
        return this.context?.canRestart === true;
    }
    get restartBlocked() {
        return this.isReNurture && !this.canRestart ? this.context?.restartMessage : undefined;
    }
    get companyName() {
        return this.context?.company || 'this Lead';
    }
    get ownedByQueue() {
        return this.context?.ownedByQueue === true;
    }
    get nextCycle() {
        return (this.context?.cycle || 1) + 1;
    }
    get isIdentityReview() {
        return this.context?.pendingReview === IDENTITY;
    }
    get canConfirm() {
        return this.context?.canConfirm === true;
    }
    get reviewBlocked() {
        return this.hasReview && !this.canConfirm ? this.context?.reviewMessage : undefined;
    }
    get reviewButtonLabel() {
        return this.isIdentityReview ? 'Confirm identity review' : 'Confirm qualification review';
    }
    get confirmDisabled() {
        return this.saving || !this.note.trim();
    }

    handleStart() {
        this.error = undefined;
        this.note = '';
        this.step = CONFIRM;
    }

    handleNote(event) {
        this.note = event.target.value || '';
    }

    handleCancel() {
        this.step = VIEW;
        this.note = '';
        this.error = undefined;
    }

    async handleRestart() {
        await this.run(() => restart({ leadId: this.recordId, note: this.note }), 'Lead restarted at Qualify');
    }

    async handleConfirmReview() {
        const review = this.context.pendingReview;
        await this.run(async () => {
            const status = await confirmReview({ leadId: this.recordId, review });
            return status;
        }, review === IDENTITY ? 'Identity review confirmed' : 'Qualification review confirmed');
    }

    async run(action, successTitle) {
        this.saving = true;
        this.error = undefined;
        try {
            const status = await action();
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            const message = status ? this.companyName + ' is at ' + status + '.' : this.companyName;
            this.dispatchEvent(new ShowToastEvent({ title: successTitle, message, variant: 'success' }));
            this.step = VIEW;
            this.note = '';
        } catch (e) {
            this.error = messageOf(e);
            this.step = VIEW;
        } finally {
            this.saving = false;
        }
    }
}

function messageOf(error) {
    return error?.body?.message || error?.message || 'The change could not be saved.';
}