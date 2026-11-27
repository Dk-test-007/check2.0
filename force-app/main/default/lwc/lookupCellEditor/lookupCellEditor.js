import { api, LightningElement, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';

export default class LookupCellEditor extends LightningElement {
    @api value;
    @api objectApiName;
    @api label;
    @api placeholder;
    @api required = false;
    @api rowId;
    @api fieldName;

    pendingLookupLabel = false;

    get recordFields() {
        return this.objectApiName ? [`${this.objectApiName}.Name`] : [];
    }

    @wire(getRecord, {
        recordId: '$value',
        fields: '$recordFields'
    })
    wiredSelectedRecord({ data }) {
        if (!data || !this.pendingLookupLabel) {
            return;
        }

        this.pendingLookupLabel = false;
        this.dispatchLookupSelection(
            this.value,
            data.fields?.Name?.value
        );
    }

    @api
    get validity() {
        const picker = this.template.querySelector('lightning-record-picker');
        const validity = picker?.validity;

        if (validity) {
            return validity;
        }

        const valueMissing = this.required && !this.value;
        return {
            valid: !valueMissing,
            valueMissing
        };
    }

    handleChange(event) {
        this.value = event.detail.recordId;
        this.pendingLookupLabel = Boolean(this.value);

        this.dispatchEvent(
            new CustomEvent('change', {
                detail: { value: this.value },
                bubbles: true,
                composed: true
            })
        );

        if (!this.value) {
            this.dispatchLookupSelection(null, null);
        }
    }

    dispatchLookupSelection(recordId, recordName) {
        this.dispatchEvent(
            new CustomEvent('lookupselectionchange', {
                detail: {
                    rowId: this.rowId,
                    fieldName: this.fieldName,
                    value: recordId,
                    label: recordName
                },
                bubbles: true,
                composed: true
            })
        );
    }

    @api
    reportValidity() {
        return this.template.querySelector('lightning-record-picker')?.reportValidity() ?? true;
    }

    @api
    showHelpMessageIfInvalid() {
        return this.reportValidity();
    }

    @api
    setCustomValidity(message) {
        this.template.querySelector('lightning-record-picker')?.setCustomValidity(message);
    }

    @api
    focus() {
        this.template.querySelector('lightning-record-picker')?.focus();
    }
}