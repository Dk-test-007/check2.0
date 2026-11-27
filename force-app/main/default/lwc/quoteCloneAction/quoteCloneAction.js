import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import cloneQuote from '@salesforce/apex/QuoteCloneController_CC.cloneQuote';
import hasAcceptedQuote from '@salesforce/apex/QuoteCloneController_CC.hasAcceptedQuote';

export default class QuoteCloneAction extends NavigationMixin(LightningElement) {

    _recordId;
    isLoading = false;
    isChecking = true;
    isBlocked = false;

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;

        if (value) {
            this.checkAcceptedQuote();
        }
    }

    get isCloneDisabled() {
        return this.isLoading || this.isChecking || this.isBlocked;
    }

    async checkAcceptedQuote() {
        this.isChecking = true;

        try {
            this.isBlocked = await hasAcceptedQuote({
                quoteId: this._recordId
            });
        } catch (error) {
            this.isBlocked = true;

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: 'An unexpected error occurred while processing the request. Please contact your system administrator for assistance.',
                    variant: 'error'
                })
            );
        } finally {
            this.isChecking = false;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    async handleClone() {
        if (this.isCloneDisabled) {
            return;
        }

        this.isLoading = true;

        try {
            const newQuoteId = await cloneQuote({
                quoteId: this._recordId
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