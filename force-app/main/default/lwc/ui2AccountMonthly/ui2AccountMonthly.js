import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getAccountView from '@salesforce/apex/AccountMonthlyForecastController_CC.getAccountView';

export function attainmentText(value) {
    return value === null || value === undefined ? 'N/A' : `${value}%`;
}

export default class Ui2AccountMonthly extends NavigationMixin(LightningElement) {
    @api recordId;
    @track view;
    year = new Date().getFullYear();
    error;
    loading = false;

    connectedCallback() {
        this.load();
    }

    async load() {
        this.loading = true;
        try {
            this.view = await getAccountView({ accountId: this.recordId, year: this.year });
            this.error = undefined;
        } catch (e) {
            this.error = e?.body?.message || e?.message || 'Something went wrong.';
        } finally {
            this.loading = false;
        }
    }

    get yearOptions() {
        const now = new Date().getFullYear();
        return [now - 1, now, now + 1].map((y) => ({ label: String(y), value: String(y) }));
    }
    get yearValue() {
        return String(this.year);
    }
    get hasData() {
        return this.view?.currencies?.length > 0;
    }
    get hasExceptions() {
        return this.view?.exceptions?.length > 0;
    }
    get exceptions() {
        return (this.view?.exceptions || []).map((text, i) => ({ key: `e${i}`, text }));
    }
    get title() {
        return this.view?.isSite ? `Site monthly view (Entity: ${this.view.entityName})` : 'Account monthly view';
    }
    get blocks() {
        return (this.view?.currencies || []).map((b) => ({
            ...b,
            key: b.currencyIsoCode,
            ytdAttainment: attainmentText(b.ytdAttainmentPercent),
            showUnallocated: b.unallocatedPlan !== null && b.unallocatedPlan !== undefined,
            showEntityWideShipTo: b.entityWideShipToActuals !== null && b.entityWideShipToActuals !== undefined,
            months: b.months.map((m) => ({
                ...m,
                attainment: attainmentText(m.attainmentPercent),
                rowClass: m.state === 'Completed' ? '' : 'slds-text-color_weak',
                stateText: m.state,
                hasUnplanned: m.unplannedActuals > 0
            })),
            terms: [b.originalTerm, b.extension, b.unplanned, b.combined]
                .filter((s) => s && (s.months > 0 || s.label === 'Combined'))
                .map((s) => ({
                    ...s,
                    key: s.label,
                    attainment: attainmentText(s.completedAttainmentPercent),
                    rowClass: s.label === 'Combined' ? 'slds-text-title_bold' : ''
                })),
            agreements: b.agreements.map((a, i) => ({ ...a, key: `a${i}`, hasUnplanned: a.unplannedActuals > 0 })),
            sites: b.sites.map((s, i) => ({ ...s, key: `s${i}` })),
            products: b.products.map((p, i) => ({ ...p, key: `p${i}` })),
            hasProducts: b.products.length > 0
        }));
    }

    handleYear(e) {
        this.year = parseInt(e.detail.value, 10);
        this.load();
    }

    handleRefresh() {
        this.load();
    }

    handleOpen(e) {
        const recordId = e.target.dataset.id;
        if (recordId) {
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, actionName: 'view' } });
        }
    }
}