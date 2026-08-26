import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import closeAsNFU
    from '@salesforce/apex/PawnResearchController.closeAsNFU';

export default class PawnWizardFooter extends LightningElement {

    @api currentStep;
    @api opportunityId;
    @api disableStep1Actions = false;

    showNFUConfirmModal = false;
    showCommentsModal = false;
    closingComments = '';

    @api nfuClosed;
    
    // =========================================
    // Step Visibility
    // =========================================

    get showPrev() {
        return this.currentStep === 'step2'
            || this.currentStep === 'step3';
    }

    get showSaveEnquiry() {
        return this.currentStep === 'step1'
            || this.currentStep === 'step2';
    }

    get showContinue() {
        return this.currentStep === 'step1'
            || this.currentStep === 'step2';
    }

    get showSubmit() {
        return this.currentStep === 'step3';
    }

    // =========================================
    // Footer Actions
    // =========================================

    handlePrev() {

        this.dispatchEvent(
            new CustomEvent('prev')
        );
    }

    handleSaveEnquiry() {

        this.dispatchEvent(
            new CustomEvent('saveenquiry')
        );
    }

    handleContinue() {

        this.dispatchEvent(
            new CustomEvent('continue')
        );
    }

    handleSubmit() {

        this.dispatchEvent(
            new CustomEvent('submit')
        );
    }

    // =========================================
    // NFU
    // =========================================

    handleNFU() {

        if (!this.opportunityId) {

            this.showToast(
                'Validation Error',
                'Please save the enquiry first.',
                'error'
            );

            return;
        }

        this.showNFUConfirmModal = true;
    }

    closeNFUModal() {

        this.showNFUConfirmModal = false;
    }

    openCommentsModal() {

        this.showNFUConfirmModal = false;
        this.showCommentsModal = true;
    }

    closeCommentsModal() {

        this.showCommentsModal = false;
    }

    handleClosingComments(event) {

        this.closingComments =
            event.detail.value;
    }

    async saveNFU() {

        if (
            !this.closingComments ||
            !this.closingComments.trim()
        ) {

            this.showToast(
                'Validation Error',
                'Closing Comments are required.',
                'error'
            );

            return;
        }

        try {

            await closeAsNFU({

                opportunityId:
                    this.opportunityId,

                closingComments:
                    this.closingComments
            });

            this.isNFUClosed = true;
            this.nfuClosed = true;

            this.showCommentsModal = false;

            this.showToast(
                'Success',
                'Enquiry marked as NFU.',
                'success'
            );

            this.dispatchEvent(
                new CustomEvent(
                    'nfucomplete'
                )
            );

        } catch (error) {

            this.showToast(
                'Error',
                error?.body?.message ||
                error?.message ||
                'Unknown error occurred.',
                'error'
            );
        }
    }

    renderedCallback() {
        console.log(
            'FOOTER nfuClosed =',
            this.nfuClosed
        );
    }
    // =========================================
    // Utilities
    // =========================================

    showToast(
        title,
        message,
        variant
    ) {

        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }
}