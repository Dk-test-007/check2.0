import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import savePdfToOrder from '@salesforce/apex/OrderPdfController.savePdfToOrder';

export default class OrderPdfPreview extends NavigationMixin(LightningElement)  {
    @api recordId;
    isSaving = false;

    // Visualforce page name goes here (not the Apex class name)
    get pdfUrl() {
        return `/apex/CarltonOrderTemplate_CC?id=${this.recordId}`;
    }

    async handleSave() {
        this.isSaving = true;
        try {
            await savePdfToOrder({ orderId: this.recordId });
            this.dispatchEvent(new ShowToastEvent({
                title: 'Success',
                message: 'PDF saved to the Order Files.',
                variant: 'success'
            }));
            // Refresh the page so the new file appears in Files
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.recordId,
                    objectApiName: 'Order',
                    actionName: 'view'
                }
            });
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not save PDF',
                message: error?.body?.message || 'Unknown error',
                variant: 'error'
            }));
        } finally {
            this.isSaving = false;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}