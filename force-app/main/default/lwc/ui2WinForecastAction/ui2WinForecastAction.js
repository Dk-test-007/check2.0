import { LightningElement, api, wire } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { CurrentPageReference } from 'lightning/navigation';

export default class Ui2WinForecastAction extends LightningElement {
    @api recordId;
    @wire(CurrentPageReference) pageReference;
    get opportunityId() {
        return this.recordId || this.pageReference?.state?.recordId ||
            this.pageReference?.attributes?.recordId || new URL(window.location.href).searchParams.get('recordId');
    }
    handleWinSaved() { this.dispatchEvent(new CloseActionScreenEvent()); }
}