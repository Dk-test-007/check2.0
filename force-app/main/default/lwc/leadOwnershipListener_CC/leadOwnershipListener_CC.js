import { LightningElement, api } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import USER_ID from '@salesforce/user/Id';

const CHANNEL = '/event/Lead_Ownership_Transferred_CC__e';
const MAX_AGE_MS = 30000;

export default class LeadOwnershipListener extends NavigationMixin(LightningElement) {
    @api recordId;
    subscription = {};
    handled = false;

    connectedCallback() {
        onError((error) => {
            console.error('LISTENER: empApi error', JSON.stringify(error));
        });

        // -2 replays recent events, so a remount during the save window still
        // receives the publish. Stale events are filtered out by age below.
        subscribe(CHANNEL, -2, (message) => this.handleEvent(message)).then((response) => {
            this.subscription = response;
        });
    }

    disconnectedCallback() {
        if (this.subscription?.id) {
            unsubscribe(this.subscription, () => {});
        }
    }

    handleEvent(message) {
        if (this.handled) {
            return;
        }

        const payload = message?.data?.payload;
        if (!payload) {
            return;
        }

        // Discard replayed events from earlier sessions.
        const createdDate = payload.CreatedDate;
        if (createdDate && Date.now() - new Date(createdDate).getTime() > MAX_AGE_MS) {
            return;
        }

        // Every subscriber receives every event, so filter on both axes.
        const forThisUser = this.matches(payload.Recipient_User_Id_CC__c, USER_ID);
        const forThisRecord = this.matches(payload.Lead_Id_CC__c, this.recordId);
        if (!forThisUser || !forThisRecord) {
            return;
        }

        this.finish();
    }

    finish() {
        this.handled = true;

        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Lead moved to Re-Nurture',
                message:
                    'Ownership has been transferred back to Marketing, so this Lead is no longer yours to work.',
                variant: 'success',
                mode: 'sticky'
            })
        );

        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Lead', actionName: 'list' },
            state: { filterName: 'Recent' }
        });
    }

    matches(a, b) {
        return !!a && !!b && a.substring(0, 15) === b.substring(0, 15);
    }
}