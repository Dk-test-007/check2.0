import { LightningElement, api } from 'lwc';
import { updateRecord } from 'lightning/uiRecordApi';
import DEDUCTIONS_FIELD from '@salesforce/schema/Opportunity.Deductions__c';

import attachDocuments from '@salesforce/apex/OpportunityDocumentGenerator.attachDocuments';

import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class GenerateOpportunityDocuments extends LightningElement {

    @api recordId;

    deductions;
    isLoading = false;

    handleChange(event) {
        this.deductions = event.target.value;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    async handleGenerate() {

        const input = this.template.querySelector('lightning-input');

        if (!input.reportValidity()) {
            return;
        }

        this.isLoading = true;

        try {

            const fields = {
                Id: this.recordId,
                [DEDUCTIONS_FIELD.fieldApiName]: Number(this.deductions)
            };

            await updateRecord({ fields });

            await attachDocuments({
                opportunityId: this.recordId
            });

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: 'Documents attached successfully.',
                    variant: 'success'
                })
            );

            this.dispatchEvent(new CloseActionScreenEvent());

            // Refresh the record page
            setTimeout(() => {
                window.location.reload();
            }, 500);

        } catch (error) {

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: error?.body?.message || error.message || 'Unknown error',
                    variant: 'error'
                })
            );

        } finally {

            this.isLoading = false;

        }
    }
}