import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getSyncContext from '@salesforce/apex/BCSyncController_CC.getSyncContext';
import syncRecord from '@salesforce/apex/BCSyncController_CC.syncRecord';

const SUCCESS = 'Success';
const ERROR_PREFIX = 'Error: ';

export default class BcSyncAction extends NavigationMixin(LightningElement) {
    @api objectApiName;

    context;
    loadErrorMessage;
    isLoadingContext = true;
    isSyncing = false;
    _recordId;

    // Screen quick actions can set recordId after connectedCallback runs,
    // so the pre-sync checks are loaded from the setter instead.
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        if (value && value !== this._recordId) {
            this._recordId = value;
            this.loadContext();
        }
    }

    async loadContext() {
        this.isLoadingContext = true;
        this.loadErrorMessage = undefined;
        try {
            this.context = await getSyncContext({ recordId: this._recordId });
        } catch (error) {
            this.context = undefined;
            this.loadErrorMessage = this.reduceError(error);
        } finally {
            this.isLoadingContext = false;
        }
    }

    // ---------- View state ----------

    get recordLabel() {
        return this.context?.recordLabel || 'Record';
    }

    get panelHeader() {
        return `Sync ${this.recordLabel} to Business Central`;
    }

    get isBusy() {
        return this.isLoadingContext || this.isSyncing;
    }

    get spinnerText() {
        return this.isSyncing ? 'Sending to Business Central' : 'Checking record';
    }

    get blockingMessage() {
        if (this.loadErrorMessage) {
            return this.loadErrorMessage;
        }
        if (this.context && !this.context.canSync) {
            return this.context.blockingMessage;
        }
        return undefined;
    }

    get showConfirmation() {
        return !this.isLoadingContext && this.context?.canSync === true;
    }

    // Lock warning applies to the first sync of an Entity or Site.
    get showLockWarning() {
        return this.context?.isAccount === true && this.context?.isResync !== true;
    }

    get showResyncNote() {
        return this.context?.isResync === true;
    }

    get reviewFields() {
        return this.context?.reviewFields || [];
    }

    get hasReviewFields() {
        return this.reviewFields.length > 0;
    }

    get isContinueDisabled() {
        return this.isBusy || !this.showConfirmation;
    }

    get continueLabel() {
        return this.context?.isResync ? 'Continue and Re-sync' : 'Continue and Sync';
    }

    // Site blocked because its parent Entity is not synced: offer to open the Entity instead.
    get showParentLink() {
        return !this.isLoadingContext && this.context?.canSync === false && !!this.context?.parentRecordId;
    }

    get parentRecordName() {
        return this.context?.parentRecordName || 'the parent Entity';
    }

    // ---------- Actions ----------

    // Cancel never calls Apex, so nothing is sent and the user can edit the record.
    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // Navigate first, then close: closing the panel first can tear down the component.
    handleGoToParent() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.context.parentRecordId,
                objectApiName: 'Account',
                actionName: 'view'
            }
        });
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    async handleContinue() {
        this.isSyncing = true;
        try {
            const result = await syncRecord({
                recordId: this._recordId,
                objectApiName: this.objectApiName
            });

            if (result === SUCCESS) {
                this.showToast(
                    'Sync Requested',
                    `${this.recordLabel} "${this.context.recordName}" has been sent to Business Central.`,
                    'success'
                );
                // Refresh the record page so any sync fields update without a manual reload.
                notifyRecordUpdateAvailable([{ recordId: this._recordId }]).catch(() => {});
                this.dispatchEvent(new CloseActionScreenEvent());
            } else {
                this.showToast('Sync Blocked', this.stripErrorPrefix(result), 'error');
            }
        } catch (error) {
            this.showToast('Error', this.reduceError(error), 'error');
        } finally {
            this.isSyncing = false;
        }
    }

    // ---------- Helpers ----------

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

    stripErrorPrefix(message) {
        if (typeof message === 'string' && message.startsWith(ERROR_PREFIX)) {
            return message.substring(ERROR_PREFIX.length);
        }
        return message;
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'An unknown error occurred.';
    }
}