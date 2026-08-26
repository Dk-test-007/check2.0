import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getItems from '@salesforce/apex/PawnResearchController.getItems';
import saveItems from '@salesforce/apex/PawnResearchController.saveItems';
import closeAsNFU from '@salesforce/apex/PawnResearchController.closeAsNFU';
import closeItemAsNFU
    from '@salesforce/apex/PawnResearchController.closeItemAsNFU';

export default class PawnPageDocumentation extends LightningElement {

    @api opportunityId;

    @api
    submitWorkflow() {
        return this.handleSave();
    }

    @track items = [];

    isLoading = false;

    showItemNFUConfirmModal = false;
    showItemCommentsModal = false;

    selectedItemId;
    closingComments = '';

    handleItemNFU(event) {

        const itemId =
            event.currentTarget.dataset.id;

        const item =
            this.items.find(
                i => i.Id === itemId
            );

        if (item?.NFU_Status__c) {
            return;
        }

        this.selectedItemId = itemId;

        this.showItemNFUConfirmModal = true;
    }

    closeItemNFUModal() {

        this.showItemNFUConfirmModal = false;
    }

    openItemCommentsModal() {

        this.showItemNFUConfirmModal = false;
        this.showItemCommentsModal = true;
    }

    closeItemCommentsModal() {

        this.showItemCommentsModal = false;
    }

    handleClosingComments(event) {

        this.closingComments =
            event.detail.value;
    }

    async saveItemNFU() {

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

            await closeItemAsNFU({
                itemId: this.selectedItemId,
                closingComments: this.closingComments
            });

            this.items = this.items.map(item =>

                item.Id === this.selectedItemId

                    ? {
                        ...item,
                        NFU_Status__c: true
                    }

                    : item
            );

            this.showItemCommentsModal = false;

            this.closingComments = '';
            this.selectedItemId = null;

            this.showToast(
                'Success',
                'Item marked as NFU.',
                'success'
            );

        } catch (error) {

            this.showToast(
                'Error',
                this.reduceError(error),
                'error'
            );
        }
    }

    connectedCallback() {

        this.loadItems();
    }

    async loadItems() {

        if (!this.opportunityId) {
            return;
        }

        this.isLoading = true;

        try {

            const result = await getItems({
                opportunityId: this.opportunityId
            });

            const activeItems = result.filter(
                item => !item.NFU_Status__c
            );

            this.items = activeItems.map((item, index) => {

                const rt =
                    item.RecordType?.DeveloperName;

                return {

                    ...item,

                    displayNumber: index + 1,

                    showLoanDetails:
                        rt !== 'Others',

                    isOpen: index === 0,

                    iconName:
                        index === 0
                            ? 'utility:chevrondown'
                            : 'utility:chevronright',

                    certificateDocumentation:
                        item.certificateDocumentation || false,

                    proofOfOwnershipReceiptBox:
                        item.proofOfOwnershipReceiptBox || false,

                    provenancePaperwork:
                        item.provenancePaperwork || false,

                    authenticatedBox:
                        item.authenticatedBox || false,

                    imagesOfGoods:
                        item.imagesOfGoods || false,

                    photoId:
                        item.photoId || false,

                    proofOfAddress:
                        item.proofOfAddress || false,

                    PurchaseReceipt__c:
                        item.PurchaseReceipt__c || false,

                    OfferedLoan__c:
                        item.OfferedLoan__c,

                    BuyIn__c:
                        item.BuyIn__c,

                    showImagesOfGoods: true,

                    showPhotoId: true,

                    showProofOfAddress: true,

                    showProofOfOwnership: true,

                    showAuthenticationProof:
                        [
                            'Watch',
                            'Jewellery',
                            'Precious_Metal',
                            'Handbag_Purse_and_Wallet',
                            'Others'
                        ].includes(rt),

                    showCertificateDocumentation:
                        [
                            'Watch',
                            'Jewellery',
                            'Precious_Metal',
                            'Handbag_Purse_and_Wallet',
                            'Others'
                        ].includes(rt),

                    showProvenancePaperwork:
                        [
                            'Others'
                        ].includes(rt)
                };
            });

        } catch (error) {

            this.showToast(
                'Error',
                this.reduceError(error),
                'error'
            );

        } finally {

            this.isLoading = false;
        }
    }

    toggleItemSection(event) {
        const itemId = event.currentTarget.dataset.id;

        this.items = this.items.map(item => {
            const isOpen = item.Id === itemId ? !item.isOpen : false;

            return {
                ...item,
                isOpen,
                iconName: isOpen
                    ? 'utility:chevrondown'
                    : 'utility:chevronright'
            };
        });
    }

    handleFieldChange(event) {

        const itemId =
            event.target.dataset.id;

        const field =
            event.target.dataset.field;

        const value =
            event.detail.value;

        this.items =
            this.items.map(item => {

                if (item.Id === itemId) {

                    return {
                        ...item,
                        [field]: value
                    };
                }

                return item;
            });
    }

    handleCheckboxChange(event) {

        const itemId =
            event.target.dataset.id;

        const field =
            event.target.dataset.field;

        const value =
            event.target.checked;

        this.items =
            this.items.map(item => {

                if (item.Id === itemId) {

                    return {
                        ...item,
                        [field]: value
                    };
                }

                return item;
            });
    }

    handleCheckboxFieldChange(event) {

        const itemId =
            event.target.dataset.id;

        const field =
            event.target.dataset.field;

        const value =
            event.target.checked;

        this.items =
            this.items.map(item => {

                if (item.Id === itemId) {

                    return {
                        ...item,
                        [field]: value
                    };
                }

                return item;
            });
    }

    async handleSave() {

        this.isLoading = true;

        try {

            const documentComponents =
                this.template.querySelectorAll(
                    'c-document-upload-table-flow'
                );

            for (const component of documentComponents) {

                const validation =
                    component.validate();

                if (!validation.isValid) {

                    // Child component already displays toast
                    return;
                }
            }

            await saveItems({
                items: this.items
            });

            this.showToast(
                'Success',
                'Pawn workflow completed successfully.',
                'success'
            );

            this.dispatchEvent(
                new CustomEvent(
                    'wizardcomplete',
                    {
                        detail: {
                            opportunityId:
                                this.opportunityId
                        },
                        bubbles: true,
                        composed: true
                    }
                )
            );

        } catch (error) {

            this.showToast(
                'Error',
                this.reduceError(error),
                'error'
            );

        } finally {

            this.isLoading = false;
        }
    }

    handleBack() {

        this.dispatchEvent(
            new CustomEvent(
                'stepback',
                {
                    bubbles: true,
                    composed: true
                }
            )
        );
    }

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

    reduceError(error) {

        if (
            error &&
            error.body &&
            error.body.message
        ) {
            return error.body.message;
        }

        if (
            error &&
            error.message
        ) {
            return error.message;
        }

        return 'Unknown error occurred.';
    }

    get hasItems() {

        return this.items.length > 0;
    }

    get noItems() {

        return (
            !this.isLoading &&
            this.items.length === 0
        );
    }
}