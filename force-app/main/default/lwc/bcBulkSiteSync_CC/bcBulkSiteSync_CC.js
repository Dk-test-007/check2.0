import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getSiteSyncSummary from '@salesforce/apex/BCBulkSiteSyncController_CC.getSiteSyncSummary';
import syncSites from '@salesforce/apex/BCBulkSiteSyncController_CC.syncSites';

const SITE_NAME_COLUMN = {
    label: 'Site Name',
    fieldName: 'recordUrl',
    type: 'url',
    typeAttributes: { label: { fieldName: 'name' }, target: '_blank' }
};

const ELIGIBLE_COLUMNS = [
    SITE_NAME_COLUMN,
    { label: 'Sync Type', fieldName: 'syncType', type: 'text', initialWidth: 120 }
];

const EXCLUDED_COLUMNS = [
    SITE_NAME_COLUMN,
    { label: 'Issue', fieldName: 'issue', type: 'text', wrapText: true }
];

export default class BcBulkSiteSync extends LightningElement {
    eligibleColumns = ELIGIBLE_COLUMNS;
    excludedColumns = EXCLUDED_COLUMNS;

    summary;
    loadErrorMessage;
    selectedIds = [];
    isLoading = true;
    isSyncing = false;
    _recordId;

    // Screen quick actions can set recordId after connectedCallback runs.
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        if (value && value !== this._recordId) {
            this._recordId = value;
            this.loadSummary();
        }
    }

    async loadSummary() {
        this.isLoading = true;
        this.loadErrorMessage = undefined;
        try {
            this.summary = await getSiteSyncSummary({ entityId: this._recordId });
            // New Sites are selected by default. Already-synced Sites must be opted in.
            this.selectedIds = this.eligibleSites
                .filter((row) => row.syncType === 'New')
                .map((row) => row.id);
        } catch (error) {
            this.summary = undefined;
            this.loadErrorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    // ---------- View state ----------

    get eligibleSites() {
        return this.summary?.eligibleSites || [];
    }

    get excludedSites() {
        return this.summary?.excludedSites || [];
    }

    get hasEligibleSites() {
        return this.eligibleSites.length > 0;
    }

    get hasExcludedSites() {
        return this.excludedSites.length > 0;
    }

    get isBusy() {
        return this.isLoading || this.isSyncing;
    }

    get spinnerText() {
        return this.isSyncing ? 'Sending Sites to Business Central' : 'Checking Sites';
    }

    get blockingMessage() {
        if (this.loadErrorMessage) {
            return this.loadErrorMessage;
        }
        if (this.summary && !this.summary.canSync) {
            return this.summary.blockingMessage;
        }
        return undefined;
    }

    get showSummary() {
        return !this.isLoading && this.summary?.canSync === true;
    }

    get summaryText() {
        const total = this.summary?.totalSites || 0;
        return `${this.summary?.entityName} has ${total} ${total === 1 ? 'Site' : 'Sites'}: `
            + `${this.eligibleSites.length} ready to sync and `
            + `${this.excludedSites.length} that cannot be synced yet.`;
    }

    get eligibleHeading() {
        return `Ready to sync (${this.selectedIds.length} of ${this.eligibleSites.length} selected)`;
    }

    get excludedHeading() {
        return `Missing mandatory fields: will not be synced (${this.excludedSites.length})`;
    }

    get isContinueDisabled() {
        return this.isBusy || !this.showSummary || this.selectedIds.length === 0;
    }

    get continueLabel() {
        const count = this.selectedIds.length;
        return count === 1 ? 'Sync 1 Site' : `Sync ${count} Sites`;
    }

    // ---------- Actions ----------

    handleRowSelection(event) {
        this.selectedIds = event.detail.selectedRows.map((row) => row.id);
    }

    // Cancel never calls Apex, so nothing is sent and the user can fix the Sites.
    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    async handleContinue() {
        this.isSyncing = true;
        const sentIds = [...this.selectedIds];
        try {
            const result = await syncSites({ entityId: this._recordId, siteIds: sentIds });
            this.showToast('Sync Requested', this.buildResultMessage(result), 'success');

            // Refresh the Entity page and the Sites so sync fields update without a reload.
            const refreshIds = [this._recordId, ...sentIds].map((recordId) => ({ recordId }));
            notifyRecordUpdateAvailable(refreshIds).catch(() => {});

            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (error) {
            this.showToast('Sync Failed', this.reduceError(error), 'error');
        } finally {
            this.isSyncing = false;
        }
    }

    // ---------- Helpers ----------

    buildResultMessage(result) {
        const parts = [];
        if (result.createdCount) {
            parts.push(`${result.createdCount} new ${result.createdCount === 1 ? 'Site' : 'Sites'}`);
        }
        if (result.updatedCount) {
            parts.push(`${result.updatedCount} ${result.updatedCount === 1 ? 'update' : 'updates'}`);
        }
        let message = `${parts.join(' and ')} sent to Business Central.`;
        if (result.skippedCount) {
            message += ` ${result.skippedCount} selected ${result.skippedCount === 1 ? 'Site was' : 'Sites were'} `
                + 'skipped because they no longer meet the sync rules.';
        }
        return message;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant,
                mode: variant === 'error' ? 'sticky' : 'dismissable'
            })
        );
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'An unknown error occurred.';
    }
}