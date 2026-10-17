import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import cloneQuote from '@salesforce/apex/QuoteCloneController_CC.cloneQuote';

export default class QuoteCloneAction extends NavigationMixin(LightningElement) {

    @api recordId;
    isLoading = false;

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    async handleClone() {
        this.isLoading = true;

        try {
            const newQuoteId = await cloneQuote({
                quoteId: this.recordId
            });

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: 'Quote cloned successfully.',
                    variant: 'success'
                })
            );

            this.dispatchEvent(new CloseActionScreenEvent());

            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: newQuoteId,
                    objectApiName: 'Quote',
                    actionName: 'view'
                }
            });

        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: 'An unexpected error occurred while processing the request. Please contact your system administrator for assistance.',
                    variant: 'error'
                })
            );
        } finally {
            this.isLoading = false;
        }
    }
}