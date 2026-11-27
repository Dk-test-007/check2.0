import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import { getRecord, getFieldValue, updateRecord, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import OPPORTUNITY_OBJECT from '@salesforce/schema/Opportunity';
import STAGE_FIELD from '@salesforce/schema/Opportunity.StageName';
import RECORD_TYPE_FIELD from '@salesforce/schema/Opportunity.RecordTypeId';
import FORECAST_COMPLETE_FIELD from '@salesforce/schema/Opportunity.Carlton_Monthly_Forecast_Complete_CC__c';

const FIELDS = [STAGE_FIELD, RECORD_TYPE_FIELD, FORECAST_COMPLETE_FIELD];

export default class CarltonOpportunityStage extends LightningElement {
    @api recordId;
    record;
    objectInfo;
    picklist;
    busy = false;
    showWinDialog = false;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredRecord({ data, error }) {
        if (data) {
            this.record = data;
            this.openUnfinishedWin();
        }
        if (error) this.toast('Stage unavailable', this.message(error), 'error');
    }

    @wire(getObjectInfo, { objectApiName: OPPORTUNITY_OBJECT })
    wiredObjectInfo({ data, error }) {
        if (data) {
            this.objectInfo = data;
            this.openUnfinishedWin();
        }
        if (error) this.toast('Stage unavailable', this.message(error), 'error');
    }

    @wire(getPicklistValues, { recordTypeId: '$recordTypeId', fieldApiName: STAGE_FIELD })
    wiredPicklist({ data, error }) {
        if (data) this.picklist = data;
        if (error) this.toast('Stage options unavailable', this.message(error), 'error');
    }

    get stageName() { return getFieldValue(this.record, STAGE_FIELD); }
    get recordTypeId() { return getFieldValue(this.record, RECORD_TYPE_FIELD); }
    get recordTypeName() { return this.objectInfo?.recordTypeInfos?.[this.recordTypeId]?.name; }
    get isNewBusiness() { return this.recordTypeName === 'New Business'; }
    get hasInitialForecast() { return getFieldValue(this.record, FORECAST_COMPLETE_FIELD) === true; }
    get stageOptions() { return (this.picklist?.values || []).map(({ label, value }) => ({ label, value })); }
    get hasStageOptions() { return this.record && this.objectInfo && this.stageOptions.length > 0; }
    get stageDisabled() { return this.busy || this.showWinDialog; }
    get canResumeWin() { return this.isNewBusiness && !this.hasInitialForecast && !this.showWinDialog; }

    openUnfinishedWin() {
        if (!this.busy && !this.showWinDialog && this.isNewBusiness &&
            this.stageName === 'Closed Won' && !this.hasInitialForecast) {
            this.showWinDialog = true;
        }
    }

    async handleStageChange(event) {
        const nextStage = event.detail.value;
        event.target.value = this.stageName;
        if (!nextStage || nextStage === this.stageName || this.busy) return;
        if (nextStage === 'Closed Won' && this.isNewBusiness && !this.hasInitialForecast) {
            await this.startWinForecast();
            return;
        }
        this.busy = true;
        try {
            await updateRecord({ fields: { Id: this.recordId, StageName: nextStage } });
            this.toast('Stage updated', `Opportunity stage is now ${nextStage}.`, 'success');
            this.dispatchEvent(new RefreshEvent());
        } catch (error) {
            this.toast('Stage was not changed', this.customValidationMessage(error) || this.message(error), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleResumeForecast() { await this.startWinForecast(); }

    async startWinForecast() {
        if (this.busy || !this.isNewBusiness || this.hasInitialForecast) return;
        if (this.stageName === 'Closed Won') {
            this.showWinDialog = true;
            return;
        }
        this.showWinDialog = true;
    }

    async closeWinDialog() {
        if (this.busy) return;
        this.showWinDialog = false;
        this.toast('Win canceled', 'No forecast or stage change was saved.', 'info');
    }
    async handleWinSaved() {
        this.busy = true;
        this.showWinDialog = false;
        try {
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new RefreshEvent());
        } finally {
            this.busy = false;
        }
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    // Validation rules, Apex addError() and Flow "Custom Error" elements all surface as
    // FIELD_CUSTOM_VALIDATION_EXCEPTION, either record-level (output.errors) or field-level
    // (output.fieldErrors). Returns their messages, or null so callers keep the generic message.
    customValidationMessage(error) {
        const output = error?.body?.output;
        if (!output) return null;
        const fieldErrors = Object.values(output.fieldErrors || {}).flat();
        const messages = [...(output.errors || []), ...fieldErrors]
            .filter((e) => e?.errorCode === 'FIELD_CUSTOM_VALIDATION_EXCEPTION' && e.message)
            .map((e) => e.message);
        return messages.length ? [...new Set(messages)].join('\n') : null;
    }
    message(error) {
        return error?.body?.output?.errors?.[0]?.message || error?.body?.message || error?.message || 'Please try again.';
    }
}
