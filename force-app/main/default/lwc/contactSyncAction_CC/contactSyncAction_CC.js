import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import syncContact from '@salesforce/apex/ContactSyncController_CC.syncContact';

export default class ContactSyncAction extends LightningElement {
    @api recordId;
    isLoading = false;

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleSync() {
        this.isLoading = true;
        
        syncContact({ contactId: this.recordId })
            .then(result => {
                if (result === 'Success') {
                    this.showToast('Success', 'Contact sync request sent to MuleSoft successfully.', 'success');
                    this.dispatchEvent(new CloseActionScreenEvent());
                } else {
                    this.showToast('Sync Blocked', result, 'error');
                }
            })
            .catch(error => {
                let message = error.body ? error.body.message : 'Unknown error occurred';
                this.showToast('Error', message, 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant,
                mode: variant === 'error' ? 'sticky' : 'dismissable'
            })
        );
    }
}