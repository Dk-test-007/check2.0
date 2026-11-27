import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import getContractLines from '@salesforce/apex/ContractContractLinesController_CC.getContractLines';
import saveContractLines from '@salesforce/apex/ContractContractLinesController_CC.saveContractLines';
import prepareRecordPageRefresh from '@salesforce/apex/ContractContractLinesController_CC.refreshRecordPage';

const TOAST_DELAY_MS = 1000;
const DEFAULT_MINIMUM_ORDER_QUANTITY = 0;
const ORDERS_RELATED_LIST_ID = 'Orders';
const ORDER_FIELDS = ['Order.Id', 'Order.Status'];

export default class ContractContractLines_CC extends LightningElement {
    _recordId;
    loadedRecordId;
    lines = [];
    drafts = {};
    isLoading = false;
    isSaving = false;
    isEditing = false;
    errorMessage;
    lastRecalculatedCount = 0;
    orderStatusSignature;
    pendingSync = false;
    toastTimeoutIds = [];

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;
        if (value && value !== this.loadedRecordId) {
            this.loadedRecordId = value;
            this.orderStatusSignature = undefined;
            this.syncWithOrders();
        }
    }

    disconnectedCallback() {
        this.toastTimeoutIds.forEach(timeoutId => clearTimeout(timeoutId));
        this.toastTimeoutIds = [];
    }

    // Watches the Status of every Order created from this Contract. Lightning
    // Data Service pushes a new value whenever an Order changes (Path, edit,
    // Order LWC), even while this Contract page stays open or cached. When a
    // Status changes (e.g. an Order is Cancelled), the lines are reloaded:
    // Apex recalculates Remaining SKU, then the Contract record page is
    // refreshed so the Sales Contract Line related list shows the released
    // quantity without opening anything or clicking Save.
    @wire(getRelatedListRecords, { parentRecordId: '$recordId', relatedListId: ORDERS_RELATED_LIST_ID, fields: ORDER_FIELDS, pageSize: 200 })
    wiredOrders({ data }) {
        if (!data) return;
        const signature = (data.records || [])
            .map(record => `${record.id}:${record.fields?.Status?.value ?? ''}`)
            .sort()
            .join('|');
        const previousSignature = this.orderStatusSignature;
        this.orderStatusSignature = signature;
        if (previousSignature === undefined || previousSignature === signature) return;
        this.syncWithOrders();
    }

    get isBusy() {
        return this.isLoading || this.isSaving;
    }

    get hasLines() {
        return this.lines.length > 0;
    }

    get showEmptyState() {
        return !this.isLoading && !this.errorMessage && this.lines.length === 0;
    }

    get showEditButton() {
        return this.hasLines && !this.isEditing;
    }

    get rows() {
        return this.lines.map(line => {
            const draft = this.isEditing ? this.drafts[line.contractLineId] : undefined;
            const moqRequired = draft ? draft.moqRequired : line.moqRequired;
            const minimumOrderQuantity = draft ? draft.minimumOrderQuantity : line.minimumOrderQuantity;
            const hasMinimum = minimumOrderQuantity !== null && minimumOrderQuantity !== undefined && minimumOrderQuantity > 0;
            const isChanged = draft ? this.isLineChanged(line, draft) : false;
            return {
                ...line,
                moqRequired,
                minimumOrderQuantity,
                displayMinimum: moqRequired ? minimumOrderQuantity : DEFAULT_MINIMUM_ORDER_QUANTITY,
                moqRequiredLabel: moqRequired ? 'Yes' : 'No',
                moqBadgeClass: moqRequired ? 'slds-theme_warning' : '',
                showMinimumInput: this.isEditing && moqRequired,
                minimumMissing: !this.isEditing && moqRequired && !hasMinimum,
                rowClass: isChanged ? 'slds-is-edited' : ''
            };
        });
    }

    // Load (Apex recalculates Remaining SKU) and refresh the Contract page.
    // Runs on open and every time an Order Status changes.
    async syncWithOrders() {
        if (this.isSaving || this.isLoading) {
            this.pendingSync = true;
            return;
        }
        this.pendingSync = false;
        const loaded = await this.loadLines();
        if (loaded) await this.refreshRecordPage(this.lastRecalculatedCount > 0);
        if (this.pendingSync) this.syncWithOrders();
    }

    async loadLines() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const result = await getContractLines({ contractId: this._recordId });
            this.lastRecalculatedCount = result?.recalculatedLineCount || 0;
            this.lines = (result?.lines || []).map(line => ({
                ...line,
                moqRequired: line.moqRequired === true,
                minimumOrderQuantity: line.moqRequired === true
                    ? line.minimumOrderQuantity ?? null
                    : line.minimumOrderQuantity ?? DEFAULT_MINIMUM_ORDER_QUANTITY
            }));
            return true;
        } catch (error) {
            this.lines = [];
            this.errorMessage = this.getErrorMessage(error);
            return false;
        } finally {
            this.isLoading = false;
        }
    }

    handleEdit() {
        const drafts = {};
        this.lines.forEach(line => {
            drafts[line.contractLineId] = {
                moqRequired: line.moqRequired,
                minimumOrderQuantity: line.minimumOrderQuantity
            };
        });
        this.drafts = drafts;
        this.errorMessage = undefined;
        this.isEditing = true;
    }

    handleCancel() {
        this.drafts = {};
        this.errorMessage = undefined;
        this.isEditing = false;
    }

    handleMoqChange(event) {
        const lineId = event.target.dataset.id;
        const moqRequired = event.target.checked;
        const current = this.drafts[lineId];
        const currentMinimum = current.minimumOrderQuantity;
        this.drafts = {
            ...this.drafts,
            [lineId]: {
                moqRequired,
                // MOQ off -> 0. MOQ on -> keep a real minimum, otherwise empty so the required check prompts for one.
                minimumOrderQuantity: moqRequired
                    ? (currentMinimum > 0 ? currentMinimum : null)
                    : DEFAULT_MINIMUM_ORDER_QUANTITY
            }
        };
    }

    handleMinimumChange(event) {
        const lineId = event.target.dataset.id;
        const rawValue = event.detail.value;
        this.drafts = {
            ...this.drafts,
            [lineId]: {
                ...this.drafts[lineId],
                minimumOrderQuantity: rawValue === null || rawValue === undefined || rawValue === '' ? null : Number(rawValue)
            }
        };
    }

    async handleSave() {
        if (this.isSaving) return;
        this.errorMessage = undefined;

        const inputs = [...this.template.querySelectorAll('lightning-input.minimum-input')];
        const inputsValid = inputs.reduce((valid, input) => input.reportValidity() && valid, true);

        if (!inputsValid) {
            this.errorMessage = 'Correct the highlighted Minimum Order Quantity values before saving.';
            return;
        }

        const changedLines = this.lines
            .filter(line => this.isLineChanged(line, this.drafts[line.contractLineId]))
            .map(line => {
                const draft = this.drafts[line.contractLineId];
                return {
                    contractLineId: line.contractLineId,
                    moqRequired: draft.moqRequired,
                    minimumOrderQuantity: draft.moqRequired ? draft.minimumOrderQuantity : DEFAULT_MINIMUM_ORDER_QUANTITY
                };
            });

        if (changedLines.length === 0) {
            this.showToast('Info', 'No changes were made.', 'info');
            this.handleCancel();
            return;
        }

        this.isSaving = true;
        try {
            const updatedCount = await saveContractLines({ contractId: this._recordId, linesJson: JSON.stringify(changedLines) });
            this.drafts = {};
            this.isEditing = false;
            await this.loadLines();
            await this.refreshRecordPage(true);
            this.showToastDelayed('Success', `${updatedCount} Contract Line(s) updated.`, 'success');
        } catch (error) {
            const message = this.getErrorMessage(error);
            this.errorMessage = message;
            this.showToast('Error', message, 'error');
        } finally {
            this.isSaving = false;
            if (this.pendingSync) this.syncWithOrders();
        }
    }

    // touchContract = true  -> Apex gives the Contract a new record version so
    //                          the whole Contract page re-renders (used when
    //                          data actually changed).
    // touchContract = false -> no DML; only tells Lightning to re-read the
    //                          Contract and its lines (used on a plain open).
    async refreshRecordPage(touchContract) {
        let recordIds = [this._recordId, ...this.lines.map(line => line.contractLineId)];
        if (touchContract) {
            try {
                const pageRecordIds = await prepareRecordPageRefresh({ contractId: this._recordId });
                recordIds = [...recordIds, ...(pageRecordIds || [])];
            } catch (e) {}
        }

        const uniqueIds = [...new Set(recordIds.filter(Boolean))];
        await Promise.allSettled(uniqueIds.map(recordId => notifyRecordUpdateAvailable([{ recordId }])));
        this.dispatchEvent(new RefreshEvent());
    }

    isLineChanged(line, draft) {
        if (!draft) return false;
        const draftMinimum = draft.moqRequired ? draft.minimumOrderQuantity : DEFAULT_MINIMUM_ORDER_QUANTITY;
        const lineMinimum = line.moqRequired ? line.minimumOrderQuantity : DEFAULT_MINIMUM_ORDER_QUANTITY;
        return draft.moqRequired !== line.moqRequired || (draftMinimum ?? null) !== (lineMinimum ?? null);
    }

    showToastDelayed(title, message, variant, delay = TOAST_DELAY_MS) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        const timeoutId = setTimeout(() => {
            this.toastTimeoutIds = this.toastTimeoutIds.filter(id => id !== timeoutId);
            this.showToast(title, message, variant);
        }, delay);
        this.toastTimeoutIds = [...this.toastTimeoutIds, timeoutId];
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    getErrorMessage(error) {
        if (!error) return 'An unexpected error occurred.';
        if (Array.isArray(error.body)) return error.body.map(item => item.message).join(', ');
        return error?.body?.message || error?.message || 'An unexpected error occurred.';
    }
}