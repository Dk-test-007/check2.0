import { LightningElement, api, wire } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable, getRecord } from 'lightning/uiRecordApi';
import { getFieldValue } from 'lightning/uiRecordApi';
import STATUS_FIELD from '@salesforce/schema/Quote.Status';
import saveToQuote from '@salesforce/apex/QuotePdfService.saveToQuote';

const RESTRICTED_STATUSES = ['Presented', 'Accepted', 'Rejected', 'Cancelled', 'Expired'];

export default class QuotePdfAction extends LightningElement {
    @api recordId;
    isSaving = false;
    quoteStatus;

    @wire(getRecord, { recordId: '$recordId', fields: [STATUS_FIELD] })
    wiredQuote({ data, error }) {
        if (data) {
            this.quoteStatus = getFieldValue(data, STATUS_FIELD);
        } else if (error) {
            this.quoteStatus = undefined;
        }
    }

    get isRestrictedStatus() {
        return RESTRICTED_STATUSES.includes(this.quoteStatus);
    }

    get pdfUrl() {
        return `/apex/CarltonQuoteTemplate3_3?id=${this.recordId}`;
    }

    async handleSave() {
        this.isSaving = true;
        try {
            await saveToQuote({ quoteId: this.recordId });
            this.dispatchEvent(new ShowToastEvent({
                title: 'Success',
                message: 'PDF saved to Quote.',
                variant: 'success'
            }));
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error saving PDF',
                message: 'An unexpected error occurred while processing the request. Please contact your system administrator for assistance.',
                variant: 'error'
            }));
        } finally {
            this.isSaving = false;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}