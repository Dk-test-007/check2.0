import { LightningElement, api, wire } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getLayout } from 'lightning/uiLayoutApi';
import QUOTE_ACCOUNT_ID_FIELD from '@salesforce/schema/Quote.AccountId';
import PRICEBOOK_OBJECT from '@salesforce/schema/Pricebook2';
import getPricebooks from '@salesforce/apex/PricebookSyncController_CC.getPricebooks';
import getPreview from '@salesforce/apex/PricebookSyncController_CC.getPreview';
import save from '@salesforce/apex/PricebookSyncController_CC.save';

const PRICEBOOK = { label: 'Pricebook', fieldName: 'pricebookName', hideDefaultActions: true };
const PRODUCT = { label: 'Product', fieldName: 'productUrl', type: 'url', hideDefaultActions: true, typeAttributes: { label: { fieldName: 'productName' }, target: '_blank' } };
const price = (label, fieldName) => ({ label, fieldName, type: 'currency', hideDefaultActions: true, cellAttributes: { alignment: 'left' }, typeAttributes: { currencyCode: { fieldName: 'currencyIsoCode' }, currencyDisplayAs: 'code' } });

const SECTIONS = [
    { name: 'CREATE', title: 'To be created', description: 'These products do not have an entry in this pricebook. Select the products for which a new pricebook entry should be created.', columns: [PRODUCT, price('List Price', 'newPrice')], className: 'review-section create-section' },
    { name: 'UPDATE', title: 'To be updated', description: 'These products already exist in this pricebook. Select the products whose list prices should be updated to match the Quote sales price.', columns: [PRODUCT, price('Current List Price', 'currentPrice'), price('New List Price', 'newPrice')], className: 'review-section update-section' },
    { name: 'NO_CHANGE', title: 'No change', description: 'These products already have the same active list price as the Quote sales price. No update will be made.', columns: [PRODUCT, price('List Price', 'currentPrice')], className: 'review-section no-change-section' }
];

export default class PricebookSync_CC extends LightningElement {
    @api recordId;
    @wire(getRecord, { recordId: '$recordId', fields: [QUOTE_ACCOUNT_ID_FIELD] }) quoteRecord;
    @wire(getLayout, { objectApiName: PRICEBOOK_OBJECT, layoutType: 'Full', mode: 'Create' }) pricebookLayout;

    pricebooks;
    pricebooksResult;
    rows;
    selectedPricebook;
    selectedCreateKeys = [];
    selectedUpdateKeys = [];
    isBusy = false;
    isCreatePricebookOpen = false;
    hasInitializedPricebooks = false;
    openSections = SECTIONS.map((s) => s.name);

    @wire(getPricebooks, { quoteId: '$recordId' })
    wiredPricebooks(result) {
        this.pricebooksResult = result;
        if (result.data) {
            this.pricebooks = result.data;
            if (!this.hasInitializedPricebooks) {
                this.hasInitializedPricebooks = true;
                if (result.data.length > 0) {
                    this.selectedPricebook = result.data[0];
                    this.loadPreview();
                }
            }
        } else if (result.error) {
            this.pricebooks = undefined;
            this.toast('Unable to load pricebooks', result.error.body?.message ?? 'Unexpected error.', 'error');
        }
    }

    get pricebookUrl() {
        return this.selectedPricebook ? `/lightning/r/Pricebook2/${this.selectedPricebook.Id}/view` : '';
    }

    get quoteAccountId() {
        return this.quoteRecord.data ? getFieldValue(this.quoteRecord.data, QUOTE_ACCOUNT_ID_FIELD) : undefined;
    }

    get pricebookLayoutSections() {
        const sections = this.pricebookLayout.data?.sections ?? [];
        return sections.map((section, sectionIndex) => ({
            key: `section-${sectionIndex}`,
            heading: section.heading,
            rows: (section.layoutRows ?? []).map((row, rowIndex) => ({
                key: `section-${sectionIndex}-row-${rowIndex}`,
                items: (row.layoutItems ?? []).map((item, itemIndex) => ({
                    key: `section-${sectionIndex}-row-${rowIndex}-item-${itemIndex}`,
                    fields: (item.layoutComponents ?? [])
                        .filter((component) => component.componentType === 'Field' && component.apiName)
                        .map((component) => ({
                            apiName: component.apiName,
                            value: component.apiName === 'Entity__c' ? this.quoteAccountId : undefined
                        }))
                })).filter((item) => item.fields.length > 0)
            })).filter((row) => row.items.length > 0)
        }));
    }

    get isPricebookLayoutLoading() {
        return !this.pricebookLayout.data && !this.pricebookLayout.error;
    }

    get hasPricebookLayoutError() {
        return !!this.pricebookLayout.error;
    }

    get pricebookLayoutError() {
        return this.pricebookLayout.error?.body?.message ?? 'Unable to load the Pricebook page layout.';
    }

    get isPricebooksLoading() {
        return !this.pricebooks && !this.pricebooksResult?.error;
    }

    get hasPricebook() {
        return (this.pricebooks ?? []).length > 0;
    }

    get noPricebook() {
        return this.pricebooks !== undefined && this.pricebooks.length === 0;
    }

    get hasPricebookError() {
        return !!this.pricebooksResult?.error;
    }

    get pricebookErrorMessage() {
        return this.pricebooksResult?.error?.body?.message ?? 'Unable to load the Entity Pricebook.';
    }

    get panelTitle() {
        return this.isCreatePricebookOpen ? 'Create Entity Pricebook' : 'Update pricebook from quote prices';
    }

    get currentStep() {
        return this.isReview ? '2' : '1';
    }

    get isReview() {
        return this.rows !== undefined;
    }

    get noQuoteLines() {
        return (this.rows ?? []).length === 0;
    }

    get createRows() {
        return (this.rows ?? []).filter((r) => r.action === 'CREATE');
    }

    get updateRows() {
        return (this.rows ?? []).filter((r) => r.action === 'UPDATE');
    }

    get noChangeRows() {
        return (this.rows ?? []).filter((r) => r.action === 'NO_CHANGE');
    }

    get createCount() {
        return this.createRows.length;
    }

    get updateCount() {
        return this.updateRows.length;
    }

    get noChangeCount() {
        return this.noChangeRows.length;
    }

    get selectedCreateCount() {
        return this.selectedCreateKeys.length;
    }

    get selectedUpdateCount() {
        return this.selectedUpdateKeys.length;
    }

    get selectedChangeCount() {
        return this.selectedCreateCount + this.selectedUpdateCount;
    }

    get hasChanges() {
        return this.createCount + this.updateCount > 0;
    }

    get reviewChangesMessage() {
        return `${this.selectedCreateCount} new ${this.selectedCreateCount === 1 ? 'entry' : 'entries'} selected for creation and ${this.selectedUpdateCount} ${this.selectedUpdateCount === 1 ? 'entry' : 'entries'} selected for update.`;
    }

    get sections() {
        return SECTIONS.map((s) => {
            const rows = (this.rows ?? []).filter((r) => r.action === s.name);
            return { ...s, rows, label: `${s.title} (${rows.length})`, isCreate: s.name === 'CREATE', isUpdate: s.name === 'UPDATE' };
        });
    }

    get saveDisabled() {
        return this.isBusy || this.selectedChangeCount === 0;
    }

    get isCreateSaveDisabled() {
        return this.isBusy;
    }

    get hasSelectedPricebook() {
        return !!this.selectedPricebook;
    }

    async loadPreview() {
        if (!this.selectedPricebook) {
            return;
        }
        this.rows = undefined;
        this.selectedCreateKeys = [];
        this.selectedUpdateKeys = [];
        const previewRows = await this.callApex(getPreview({
            quoteId: this.recordId,
            pricebookIds: [this.selectedPricebook.Id]
        }));
        if (previewRows !== undefined) {
            this.rows = previewRows;
        }
    }

    handleCreateSelection(event) {
        this.selectedCreateKeys = event.detail.selectedRows.map((row) => row.key);
    }

    handleUpdateSelection(event) {
        this.selectedUpdateKeys = event.detail.selectedRows.map((row) => row.key);
    }

    async handleSave() {
        const selectedRowKeys = [...new Set([...this.selectedCreateKeys, ...this.selectedUpdateKeys])];
        if (selectedRowKeys.length === 0) {
            return;
        }

        const count = await this.callApex(save({
            quoteId: this.recordId,
            pricebookIds: [this.selectedPricebook.Id],
            selectedRowKeys
        }));

        if (count !== undefined) {
            this.toast('Pricebooks updated', `${count} pricebook entr${count === 1 ? 'y' : 'ies'} saved.`, 'success');
            this.close();
        }
    }

    handleCreatePricebook() {
        if (!this.quoteAccountId) {
            this.toast('Unable to create pricebook', 'The Quote does not have an Account. Add an Account to the Quote and try again.', 'error');
            return;
        }
        this.isCreatePricebookOpen = true;
    }

    handleCancelCreatePricebook() {
        this.isCreatePricebookOpen = false;
    }

    handlePricebookSubmit(event) {
        event.preventDefault();
        const fields = { ...event.detail.fields };
        fields.Entity__c = this.quoteAccountId;
        event.target.submit(fields);
    }

    async handlePricebookCreated(event) {
        this.isCreatePricebookOpen = false;
        this.isBusy = true;
        try {
            await refreshApex(this.pricebooksResult);
            const createdPricebookId = event.detail.id;
            this.selectedPricebook = (this.pricebooks ?? []).find((pb) => pb.Id === createdPricebookId) ?? null;

            if (this.selectedPricebook) {
                this.toast('Pricebook created', 'The Entity Pricebook was created successfully.', 'success');
                await this.loadPreview();
            } else {
                this.toast('Pricebook created but inactive', 'The pricebook was created, but it is not active. Activate it before using it for Quote price updates.', 'warning');
            }
        } catch (error) {
            this.toast('Pricebook created', 'The pricebook was created, but the list could not be refreshed. Close and reopen this action to see it.', 'warning');
        } finally {
            this.isBusy = false;
        }
    }

    // ---------- Helpers

    async callApex(promise) {
        this.isBusy = true;
        try {
            return await promise;
        } catch (error) {
            this.toast('Something went wrong', error.body?.message ?? 'Unexpected error.', 'error');
            return undefined;
        } finally {
            this.isBusy = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}