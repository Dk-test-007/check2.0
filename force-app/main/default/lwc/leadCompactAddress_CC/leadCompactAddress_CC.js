import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import USER_TIME_ZONE from '@salesforce/i18n/timeZone';
import LOCALE from '@salesforce/i18n/locale';
import STREET_FIELD from '@salesforce/schema/Lead.Street';
import ADDRESS_2_FIELD from '@salesforce/schema/Lead.Address_2_CC__c';
import CITY_FIELD from '@salesforce/schema/Lead.City';
import STATE_FIELD from '@salesforce/schema/Lead.State';
import STATE_CODE_FIELD from '@salesforce/schema/Lead.StateCode';
import POSTAL_CODE_FIELD from '@salesforce/schema/Lead.PostalCode';
import COUNTRY_FIELD from '@salesforce/schema/Lead.Country';
import COUNTRY_CODE_FIELD from '@salesforce/schema/Lead.CountryCode';
import { localTimeFor } from './localTime';

const REFRESH_MS = 60000;

/**
 * Lead UI pilot: the Lead address on one compact block, linked to an online map, without the embedded map
 * of the standard Address field. Edit opens the standard Address input inline (same field, same rules), with
 * Address 2 under it. The standard Address field stays on the Company & Contact tab as another edit route.
 * CP27 additions (10 Nov): Address 2 (second address line) and the Lead's local time, with the difference from the
 * viewing user's Salesforce time zone.
 */
export default class LeadCompactAddress_CC extends LightningElement {
    @api recordId;

    record;
    editing = false;
    now = new Date();
    timer;

    @wire(getRecord, {
        recordId: '$recordId',
        optionalFields: [STREET_FIELD, ADDRESS_2_FIELD, CITY_FIELD, STATE_FIELD, STATE_CODE_FIELD, POSTAL_CODE_FIELD,
            COUNTRY_FIELD, COUNTRY_CODE_FIELD]
    })
    wiredRecord({ data }) {
        this.record = data;
    }

    connectedCallback() {
        // Keeps the shown local time current while the page is open (cleared on disconnect).
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = setInterval(() => {
            this.now = new Date();
        }, REFRESH_MS);
    }

    disconnectedCallback() {
        clearInterval(this.timer);
    }

    get street() {
        return this.value(STREET_FIELD);
    }
    get address2() {
        return this.value(ADDRESS_2_FIELD);
    }
    /** Street with Address 2 on its own line, for the formatted address. */
    get streetLines() {
        return [this.street, this.address2].filter(Boolean).join('\n');
    }
    get city() {
        return this.value(CITY_FIELD);
    }
    get province() {
        return this.value(STATE_FIELD);
    }
    get postalCode() {
        return this.value(POSTAL_CODE_FIELD);
    }
    get country() {
        return this.value(COUNTRY_FIELD);
    }
    get hasAddress() {
        return Boolean(this.street || this.address2 || this.city || this.province || this.postalCode || this.country);
    }
    get localTime() {
        return localTimeFor(this.value(COUNTRY_CODE_FIELD), this.value(STATE_CODE_FIELD), USER_TIME_ZONE, this.now, LOCALE);
    }
    get localTimeClass() {
        return this.localTime.known ? '' : 'slds-text-color_weak';
    }

    value(field) {
        return this.record ? getFieldValue(this.record, field) : undefined;
    }

    handleEdit() {
        this.editing = true;
    }

    handleCancel() {
        this.editing = false;
    }

    handleSuccess() {
        this.editing = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Address saved', variant: 'success' }));
    }
}