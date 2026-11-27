import { LightningElement, api } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { RefreshEvent } from 'lightning/refresh';
import refreshPrices from '@salesforce/apex/OrderRefreshPriceController_CC.refreshPrices';

/**
 * Headless quick action: no template is rendered. Salesforce calls invoke()
 * when the user clicks "Refresh Price" on the Order record page.
 */
export default class RefreshOrderPriceCC extends LightningElement {
    @api recordId;

    isExecuting = false;

    @api
    async invoke() {
        // Ignore repeated clicks while a refresh is already running.
        if (this.isExecuting) {
            return;
        }
        this.isExecuting = true;

        try {
            const confirmed = await LightningConfirm.open({
                label: 'Refresh Price',
                message: 'All Order Products on this Order will get an updated Price.',
                theme: 'warning'
            });
            if (!confirmed) {
                return;
            }

            this.showToast('Checking prices', 'Please wait while the Order Product prices are checked.', 'info');

            const result = await refreshPrices({ orderId: this.recordId });

            if (result.refreshed) {
                // Lines were recreated: refresh the Order record (totals) and the Order Products related list.
                await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                this.dispatchEvent(new RefreshEvent());
                this.showToast('Success', result.message, 'success');
            } else {
                // Prices already current (or no Order Products): nothing changed, nothing to refresh.
                this.showToast('No changes needed', result.message, 'info');
            }
        } catch (error) {
            this.showToast('Refresh Price failed', this.getErrorMessage(error), 'error');
        } finally {
            this.isExecuting = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    getErrorMessage(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'An unexpected error occurred.';
    }
}