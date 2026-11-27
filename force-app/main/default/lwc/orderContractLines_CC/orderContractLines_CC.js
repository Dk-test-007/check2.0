import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent, registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import ORDER_STATUS_FIELD from '@salesforce/schema/Order.Status';
import getContractLines from '@salesforce/apex/OrderContractLineController_CC.getContractLines';
import saveOrderLines from '@salesforce/apex/OrderContractLineController_CC.saveOrderLines';
import cancelOrder from '@salesforce/apex/OrderContractLineController_CC.cancelOrder';
import getRefreshRecordIds from '@salesforce/apex/OrderContractLineController_CC.getRefreshRecordIds';

const TOAST_DELAY_MS = 1000;
const OWN_REFRESH_WINDOW_MS = 3000;

function buildColumns(isEditable) {
    return [
        { label: 'Product', fieldName: 'productName', type: 'text' },
        { label: 'Contract Quantity', fieldName: 'quantity', type: 'number' },
        { label: 'Remaining SKU', fieldName: 'remainingSKU', type: 'number' },
        { label: 'Minimum Order Quantity', fieldName: 'minimumOrderQuantity', type: 'number' },
        { label: 'Order Quantity', fieldName: 'orderQuantity', type: 'number', editable: isEditable }
    ];
}

// CANCELLATION
// ------------
// "Cancel Order" button: Apex sets the Order Status to Cancelled and
//   recalculates Remaining SKU in the same transaction - the same path Save
//   uses when Order Products are added - then the Order and Contract record
//   pages are refreshed and the toast is shown after the delay.
// The Status watcher and the page refresh handler are kept so the grid also
//   reloads if the Status is changed some other way while this is open.
export default class OrderContractLines_CC extends LightningElement {
    _recordId;
    lines = [];
    draftValues = [];
    errors;
    columns = buildColumns(false);
    orderStatus;
    isEditable = false;
    isCancelled = false;
    canCancel = false;
    isLoading = false;
    isSaving = false;
    hasLoaded = false;
    lastKnownStatus;
    lastRecalculatedCount = 0;
    pendingReload = false;
    pendingReloadIsStatusChange = false;
    ownRefreshAt = 0;
    refreshHandlerId;
    toastTimeoutIds = [];

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;
        if (value && !this.hasLoaded) {
            this.hasLoaded = true;
            this.initialLoad();
        }
    }

    connectedCallback() {
        this.refreshHandlerId = registerRefreshHandler(this, this.handlePageRefresh.bind(this));
    }

    disconnectedCallback() {
        if (this.refreshHandlerId) unregisterRefreshHandler(this.refreshHandlerId);
        this.toastTimeoutIds.forEach(timeoutId => clearTimeout(timeoutId));
        this.toastTimeoutIds = [];
    }

    @wire(getRecord, { recordId: '$recordId', fields: [ORDER_STATUS_FIELD] })
    wiredOrder({ data }) {
        if (!data) return;
        const status = getFieldValue(data, ORDER_STATUS_FIELD);
        const previousStatus = this.lastKnownStatus;
        this.lastKnownStatus = status;
        if (previousStatus === undefined || previousStatus === status) return;
        this.reload(true);
    }

    // Called by the Lightning Refresh API whenever the record page refreshes.
    handlePageRefresh() {
        return new Promise(resolve => {
            // Ignore the RefreshEvent this component dispatched itself.
            if (Date.now() - this.ownRefreshAt > OWN_REFRESH_WINDOW_MS) this.reload(false);
            resolve(true);
        });
    }

    async initialLoad() {
        const loaded = await this.loadLines();
        if (loaded && this.lastRecalculatedCount > 0) await this.refreshRecordPage();
    }

    // Reloads the lines from Apex (recalculating Remaining SKU). While a load
    // or save is running the request is queued and replayed afterwards.
    async reload(isStatusChange) {
        if (this.isLoading || this.isSaving) {
            this.pendingReload = true;
            this.pendingReloadIsStatusChange = this.pendingReloadIsStatusChange || isStatusChange;
            return;
        }
        this.pendingReload = false;
        this.pendingReloadIsStatusChange = false;
        const wasCancelled = this.isCancelled;
        const loaded = await this.loadLines();
        if (loaded) {
            const justCancelled = isStatusChange && this.isCancelled && !wasCancelled;
            if (justCancelled || this.lastRecalculatedCount > 0) await this.refreshRecordPage();
            if (justCancelled) this.showToastDelayed('Success', 'Order cancelled. Its quantities have been released back to the Contract.', 'success');
        }
        if (this.pendingReload) this.reload(this.pendingReloadIsStatusChange);
    }

    get isBusy() {
        return this.isLoading || this.isSaving;
    }

    get hasLines() {
        return this.lines.length > 0;
    }

    get showEmptyState() {
        return !this.isLoading;
    }

    get statusMessage() {
        if (!this.orderStatus || this.isEditable) return null;
        if (this.isCancelled) return 'This Order is cancelled. Its quantities have been released back to the Contract.';
        return `Order Lines can only be changed while the Order is in Draft status. Current status: ${this.orderStatus}.`;
    }

    async loadLines() {
        this.isLoading = true;
        try {
            const result = await getContractLines({ orderId: this._recordId });
            this.orderStatus = result?.orderStatus;
            this.isEditable = result?.isEditable === true;
            this.isCancelled = result?.isCancelled === true;
            this.canCancel = result?.canCancel === true;
            this.lastRecalculatedCount = result?.recalculatedLineCount || 0;
            this.columns = buildColumns(this.isEditable);
            this.lines = result?.lines || [];
            this.draftValues = [];
            this.errors = undefined;
            return true;
        } catch (error) {
            this.showToast('Error', this.getErrorMessage(error), 'error');
            return false;
        } finally {
            this.isLoading = false;
        }
    }

    async handleSave(event) {
        if (this.isSaving || !this.isEditable) return;
        const drafts = event.detail.draftValues || [];
        if (drafts.length === 0) {
            this.showToast('Error', 'No changes were detected.', 'error');
            return;
        }

        const linesByRowId = new Map(this.lines.map(line => [line.rowId, line]));
        const selectedLines = [];
        const rowErrors = {};
        const messages = [];

        drafts.forEach(draft => {
            const line = draft.rowId ? linesByRowId.get(draft.rowId) : undefined;
            if (!line) {
                messages.push('Unable to identify the Contract Line being edited.');
                return;
            }

            const orderQuantity = this.toQuantity(draft.orderQuantity);
            const validationError = this.validateQuantity(line, orderQuantity);

            if (validationError) {
                rowErrors[draft.rowId] = { title: line.productName, messages: [validationError], fieldNames: ['orderQuantity'] };
                messages.push(`${line.productName}: ${validationError}`);
                return;
            }

            selectedLines.push({ contractLineId: draft.rowId, orderQuantity });
        });

        if (messages.length > 0) {
            this.errors = { rows: rowErrors, table: { title: 'Correct the highlighted rows before saving.', messages } };
            return;
        }

        this.isSaving = true;
        this.errors = undefined;

        try {
            const affectedLines = await saveOrderLines({ orderId: this._recordId, selectedLinesJson: JSON.stringify(selectedLines) });
            this.draftValues = [];
            await this.loadLines();
            await this.refreshRecordPage();

            if (affectedLines === 0) {
                this.showToastDelayed('Info', 'No changes were required.', 'info');
            } else {
                this.showToastDelayed('Success', `${affectedLines} Order Line(s) saved successfully.`, 'success');
            }
        } catch (error) {
            const message = this.getErrorMessage(error);
            this.errors = { table: { title: 'Order Lines were not saved.', messages: [message] } };
            this.showToast('Error', message, 'error');
        } finally {
            this.isSaving = false;
            if (this.pendingReload) this.reload(this.pendingReloadIsStatusChange);
        }
    }

    handleCancelEdit() {
        this.draftValues = [];
        this.errors = undefined;
    }

    // Cancel Order: same flow as Save -> Apex (status + recalculation in one
    // transaction) -> reload grid -> refresh record pages -> delayed toast.
    async handleCancelOrder() {
        if (this.isBusy || !this.canCancel) return;

        const confirmed = await LightningConfirm.open({
            label: 'Cancel Order',
            message: 'Cancelling this Order sets its Status to Cancelled and releases all of its reserved quantities back to the Contract. Unsaved changes in the table will be discarded.',
            theme: 'warning'
        });
        if (!confirmed) return;

        this.isSaving = true;
        this.errors = undefined;

        try {
            await cancelOrder({ orderId: this._recordId });
            this.draftValues = [];
            await this.loadLines();
            this.lastKnownStatus = this.orderStatus;
            await this.refreshRecordPage();
            this.showToastDelayed('Success', 'Order cancelled. Its quantities have been released back to the Contract.', 'success');
        } catch (error) {
            this.showToast('Error', this.getErrorMessage(error), 'error');
        } finally {
            this.isSaving = false;
            if (this.pendingReload) this.reload(false);
        }
    }

    async refreshRecordPage() {
        let recordIds = [this._recordId];

        try {
            const relatedIds = await getRefreshRecordIds({ orderId: this._recordId });
            recordIds = [...recordIds, ...(relatedIds || [])];
        } catch (e) {}

        const uniqueIds = [...new Set(recordIds.filter(Boolean))];
        await Promise.allSettled(uniqueIds.map(recordId => notifyRecordUpdateAvailable([{ recordId }])));
        this.ownRefreshAt = Date.now();
        this.dispatchEvent(new RefreshEvent());
    }

    toQuantity(value) {
        if (value === null || value === undefined || value === '') return 0;
        return Number(value);
    }

    validateQuantity(line, requestedQuantity) {
        if (!Number.isFinite(requestedQuantity)) return 'Order Quantity must be a valid number.';
        if (requestedQuantity < 0) return 'Order Quantity cannot be negative.';

        const remainingSKU = line.remainingSKU ?? 0;
        const existingQuantity = line.orderQuantity ?? 0;
        const availableSKU = remainingSKU + existingQuantity;

        if (requestedQuantity > availableSKU) return `Order Quantity cannot exceed the available Remaining SKU. Available: ${availableSKU}.`;
        if (!line.moqRequired) return null;
        if (requestedQuantity === 0) return null;

        const minimumOrderQuantity = line.minimumOrderQuantity;
        if (minimumOrderQuantity === null || minimumOrderQuantity === undefined || minimumOrderQuantity <= 0) return 'Minimum Order Quantity must be defined for this product because MOQ is required.';
        if (requestedQuantity < minimumOrderQuantity) return `Order Quantity must be at least ${minimumOrderQuantity}.`;

        return null;
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

        const body = error.body || {};
        if (body.message) return body.message;
        if (body.pageErrors && body.pageErrors.length > 0) return body.pageErrors[0].message;

        return error.message || 'An unexpected error occurred.';
    }
}