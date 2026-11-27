import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import AMOUNT_FIELD from '@salesforce/schema/Opportunity.Amount';
import getWinContext from '@salesforce/apex/SalesAgreementPlanService_CC.getWinContext';
import winAndPlan from '@salesforce/apex/SalesAgreementPlanService_CC.winAndPlan';
import { equalSpread, sumAmounts, monthList, reconcile, hasWinAmount } from './planMath';

export default class Ui2WinMonthlyForecast extends NavigationMixin(LightningElement) {
    _recordId;
    @api get recordId() { return this._recordId; }
    set recordId(value) {
        if (value && value !== this._recordId) {
            this._recordId = value;
            this.load();
        }
    }
    seenAmount = null;
    @track ctx;
    @track months = [];
    @track productRows = [];
    startMonth;
    term = 12;
    scope = 'Entity-wide';
    siteId;
    agreementChoice;
    agreementSummary = '';
    error;
    saving = false;
    loading = true;
    @wire(getRecord, { recordId: '$recordId', fields: [AMOUNT_FIELD] })
    wiredOpportunity({ data }) {
        if (!data) return;
        const amount = getFieldValue(data, AMOUNT_FIELD) ?? undefined;
        const changed = this.seenAmount !== null && amount !== this.seenAmount.value;
        this.seenAmount = { value: amount };
        if (changed && !this.saving && !this.loading) this.load();
    }
    async load() {
        this.loading = true;
        try {
            this.ctx = await getWinContext({ opportunityId: this.recordId });
            this.startMonth = this.ctx.defaultStartMonth.slice(0, 7);
            this.term = this.ctx.defaultTerm;
            this.months = monthList(this.startMonth, this.term).map((m, index) => ({ ...m, index }));
            const fromOpp = this.ctx.products.filter((p) => p.fromOpportunity);
            this.productRows = (fromOpp.length ? fromOpp : this.ctx.products.slice(0, 1)).map((p, i) => ({
                key: `p${i}`, pricebookEntryId: p.value, mode: 'Value', startMonth: `${this.startMonth}-01`,
                values: i === 0 ? equalSpread(this.ctx.amount, this.term, this.decimals) : Array(this.term).fill(0)
            }));
            this.error = undefined;
        } catch (e) { this.error = this.message(e); }
        finally { this.loading = false; }
    }
    get hasExisting() { return !!this.ctx?.existingAgreementId; }
    get canPlan() { return this.ctx && !this.hasExisting && !this.ctx.hasInitialForecast &&
        this.ctx.isNewBusiness && (this.ctx.stageName === 'Negotiate' || this.ctx.stageName === 'Closed Won'); }
    get tooEarly() { return this.ctx?.isNewBusiness && !this.ctx?.isClosed && this.ctx.stageName !== 'Negotiate'; }
    get hasSavedPlan() { return !!this.ctx?.hasInitialForecast; }
    get agreementOptions() { return [{ label: 'Yes, create an agreement header', value: 'yes' },
        { label: 'No, forecast only', value: 'no' }]; }
    get needsAgreementTerms() { return this.agreementChoice === 'yes'; }
    get decimals() { return this.ctx?.currencyDecimals ?? 2; }
    get currency() { return this.ctx?.currencyIsoCode; }
    get hasAmount() { return hasWinAmount(this.ctx?.amount); }
    get activeProductRows() { return this.productRows.filter((r) => r.values.some((v) => Number(v) > 0)); }
    get productOptions() { return (this.ctx?.products || []).map((p) => ({ label: p.label, value: p.value })); }
    get modeOptions() { return [{ label: 'Value', value: 'Value' }, { label: 'Quantity', value: 'Quantity' }]; }
    get siteOptions() { return (this.ctx?.sites || []).map((s) => ({ label: s.label, value: s.value })); }
    get scopeOptions() { return [
        { label: 'Entity-wide (unallocated to Sites)', value: 'Entity-wide' },
        { label: 'Site-scoped (one Site)', value: 'Site-scoped' }
    ]; }
    get isSiteScoped() { return this.scope === 'Site-scoped'; }
    get monthOptions() { return this.months.map((m) => ({ label: m.label, value: m.key })); }
    get gridRows() {
        return this.productRows.map((row) => {
            const option = this.ctx?.products.find((p) => p.value === row.pricebookEntryId);
            const price = Number(option?.unitPrice) || 0;
            return { ...row,
                cells: this.months.map((m) => ({ key: `${row.key}-${m.key}`, rowKey: row.key, index: m.index,
                    value: row.values[m.index] ?? 0, disabled: m.key < row.startMonth, step: row.mode === 'Quantity' ? '1' : '0.01' })),
                total: row.values.reduce((sum, value) => sum + (Number(value) || 0) * (row.mode === 'Quantity' ? price : 1), 0)
            };
        });
    }
    get monthTotals() {
        return this.months.map((m) => ({ key: m.key, amount: this.gridRows.reduce((sum, row) => {
            const option = this.ctx?.products.find((p) => p.value === row.pricebookEntryId);
            return sum + (Number(row.values[m.index]) || 0) * (row.mode === 'Quantity' ? (Number(option?.unitPrice) || 0) : 1);
        }, 0) }));
    }
    get total() { return sumAmounts(this.monthTotals.map((m) => m.amount), this.decimals); }
    get reconciliation() { return reconcile(this.ctx?.amount, this.total, this.decimals, this.currency); }
    get reconciles() { return this.reconciliation.reconciles; }
    get reconcileClass() { return !this.hasAmount ? 'slds-text-color_weak' : this.reconciles ? 'slds-text-color_success' : 'slds-text-color_error'; }
    get reconcileText() { return this.reconciliation.text; }
    get submitDisabled() {
        return this.saving || this.agreementChoice === undefined || !this.agreementChoice ||
            (this.needsAgreementTerms && !this.agreementSummary.trim()) ||
            !this.hasAmount || !this.reconciles || !this.activeProductRows.length ||
            this.activeProductRows.some((r) => !r.pricebookEntryId) ||
            new Set(this.activeProductRows.map((r) => r.pricebookEntryId)).size !== this.activeProductRows.length ||
            (this.isSiteScoped && !this.siteId);
    }
    resizeGrid() {
        const oldMonths = this.months;
        this.months = monthList(this.startMonth, this.term).map((m, index) => ({ ...m, index }));
        this.productRows = this.productRows.map((r) => {
            const previous = new Map(oldMonths.map((m, i) => [m.key, r.values[i] ?? 0]));
            const startMonth = this.months.some((m) => m.key === r.startMonth) ? r.startMonth : `${this.startMonth}-01`;
            return { ...r, startMonth, values: this.months.map((m) => m.key < startMonth ? 0 : (previous.get(m.key) ?? 0)) };
        });
    }
    handleStart(e) { this.startMonth = e.target.value; this.resizeGrid(); }
    handleTerm(e) { const n = parseInt(e.target.value, 10); if (n >= 1 && n <= 18) { this.term = n; this.resizeGrid(); } }
    handleScope(e) { this.scope = e.detail.value; }
    handleSite(e) { this.siteId = e.detail.value; }
    handleAgreementChoice(e) { this.agreementChoice = e.detail.value; }
    handleAgreementSummary(e) { this.agreementSummary = e.target.value; }
    handleProduct(e) { this.updateRow(e.target.dataset.key, { pricebookEntryId: e.detail.value }); }
    handleMode(e) { this.updateRow(e.target.dataset.key, { mode: e.detail.value, values: Array(this.term).fill(0) }); }
    handleProductStart(e) {
        const startMonth = e.detail.value;
        const row = this.productRows.find((r) => r.key === e.target.dataset.key);
        this.updateRow(row.key, { startMonth, values: row.values.map((v, i) => this.months[i].key < startMonth ? 0 : v) });
    }
    handleCell(e) {
        const key = e.target.dataset.rowKey;
        const i = Number(e.target.dataset.index);
        const row = this.productRows.find((r) => r.key === key);
        const values = [...row.values];
        values[i] = e.target.value === '' ? 0 : Number(e.target.value);
        this.updateRow(key, { values });
    }
    updateRow(key, change) { this.productRows = this.productRows.map((r) => r.key === key ? { ...r, ...change } : r); }
    handleEqual() {
        const spread = equalSpread(this.ctx.amount, this.term, this.decimals);
        this.productRows = this.productRows.map((r, i) => ({ ...r, mode: i === 0 ? 'Value' : r.mode,
            startMonth: i === 0 ? `${this.startMonth}-01` : r.startMonth,
            values: i === 0 ? spread : Array(this.term).fill(0) }));
    }
    handleClear() { this.productRows = this.productRows.map((r) => ({ ...r, values: Array(this.term).fill(0) })); }
    handleAddProduct() {
        const used = new Set(this.productRows.map((r) => r.pricebookEntryId));
        const next = this.ctx.products.find((p) => !used.has(p.value));
        this.productRows = [...this.productRows, { key: `p${Date.now()}`, pricebookEntryId: next?.value,
            mode: 'Value', startMonth: `${this.startMonth}-01`, values: Array(this.term).fill(0) }];
    }
    handleRemoveProduct(e) { this.productRows = this.productRows.filter((r) => r.key !== e.target.dataset.key); }
    async handleSubmit() {
        if (this.saving) return;
        this.saving = true;
        this.error = undefined;
        try {
            const result = await winAndPlan({ request: {
                opportunityId: this.recordId, startMonth: `${this.startMonth}-01`, termMonths: this.term,
                monthlyAmounts: this.monthTotals.map((m) => Number(m.amount.toFixed(this.decimals))),
                products: this.activeProductRows.map((r) => ({ pricebookEntryId: r.pricebookEntryId,
                    mode: r.mode, startMonth: r.startMonth, monthlyValues: r.values.map((v) => Number(v) || 0) })),
                scope: this.scope, siteIds: this.isSiteScoped && this.siteId ? [this.siteId] : [],
                agreementNeeded: this.needsAgreementTerms, agreementSummary: this.agreementSummary
            } });
            this.dispatchEvent(new ShowToastEvent({ title: 'Win saved', message: result.message, variant: result.alreadyExisted ? 'info' : 'success' }));
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            await this.load();
            this.dispatchEvent(new CustomEvent('winsaved', { bubbles: true, composed: true }));
            if (result.salesAgreementId) this.navigateToAgreement(result.salesAgreementId);
        } catch (e) { this.error = this.message(e); }
        finally { this.saving = false; }
    }
    handleOpenAgreement() { this.navigateToAgreement(this.ctx.existingAgreementId); }
    handleAccountForecast() { this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: {
        recordId: this.ctx.accountId, objectApiName: 'Account', actionName: 'view' } }); }
    navigateToAgreement(recordId) { this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: {
        recordId, objectApiName: 'SalesAgreement', actionName: 'view' } }); }
    message(e) { return e?.body?.message || e?.message || 'Something went wrong.'; }
}