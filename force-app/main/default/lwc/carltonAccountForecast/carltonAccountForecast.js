import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import ACCOUNT_CURRENCY from '@salesforce/schema/Account.CurrencyIsoCode';
import getOverview from '@salesforce/apex/CarltonAccountForecastController.getOverview';
import ensureUnifiedForecast from '@salesforce/apex/CarltonAccountForecastController.ensureUnifiedForecast';
import saveForecastEdits from '@salesforce/apex/CarltonAccountForecastController.saveForecastEdits';
import getExistingProductOptions from '@salesforce/apex/CarltonAccountForecastController.getExistingProductOptions';
import addExistingProduct from '@salesforce/apex/CarltonAccountForecastController.addExistingProduct';

const ALL = 'ALL';
const number = value => Number(value || 0);
const csvCell = value => `"${String(value ?? '').replaceAll('"', '""')}"`;
const labelMonth = date => new Date(`${date}T12:00:00Z`).toLocaleDateString('en-GB', {
    month: 'short', year: 'numeric', timeZone: 'UTC'
});

export default class CarltonAccountForecast extends LightningElement {
    @api recordId;
    overview;
    wiredOverview;
    error;
    editing = false;
    showAllMonths = false;
    drafts = {};
    saving = false;
    massProduct = ALL;
    massMeasure = 'revenue';
    massAction = 'replace';
    massFrom;
    massThrough;
    massValue;
    massPercent = false;
    productFilter = ALL;
    existingProducts = [];
    selectedExistingProduct;
    accountCurrencyCode;
    currencyRefreshPending = false;

    @wire(getRecord, { recordId: '$recordId', fields: [ACCOUNT_CURRENCY] })
    loadAccountCurrency({ data }) {
        if (!data) return;
        const code = getFieldValue(data, ACCOUNT_CURRENCY);
        if (!code) return;
        const currencyChanged = this.accountCurrencyCode && this.accountCurrencyCode !== code;
        this.accountCurrencyCode = code;
        if (currencyChanged) {
            this.drafts = {};
            this.editing = false;
        }
        this.refreshForAccountCurrency();
    }

    async refreshForAccountCurrency() {
        if (!this.accountCurrencyCode || !this.overview || !this.wiredOverview || this.currencyRefreshPending
            || this.overview.accountCurrencyCode === this.accountCurrencyCode) return;
        this.currencyRefreshPending = true;
        try {
            await refreshApex(this.wiredOverview);
        } catch (error) {
            this.toast(error.body?.message || 'The forecast could not be refreshed after the Account currency changed.', 'error');
        } finally {
            this.currencyRefreshPending = false;
        }
    }

    @wire(getExistingProductOptions, { accountId: '$recordId' })
    loadExistingProducts({ data }) { if (data) this.existingProducts = data; }

    @wire(getOverview, { accountId: '$recordId' })
    loadOverview(result) {
        this.wiredOverview = result;
        if (result.data) {
            this.overview = result.data;
            this.error = undefined;
            void this.refreshForAccountCurrency();
            const months = this.periods;
            if (!this.massFrom && months.length) this.massFrom = months[0].key;
            if (!this.massThrough && months.length) this.massThrough = months[months.length - 1].key;
        } else if (result.error) {
            this.error = result.error.body?.message || 'The account forecast could not be loaded.';
            this.overview = undefined;
        }
    }

    get forecastUrl() {
        return this.overview?.forecastUseId
            ? `/lightning/r/AdvAcctForecastSetUse/${this.overview.forecastUseId}/view` : null;
    }
    get hasForecast() { return !!this.forecastUrl; }
    get hasIndicativeLine() { return (this.overview?.rows || []).some(row => row.isIndicative); }
    get showSetup() { return !!this.overview && !this.hasIndicativeLine; }
    get setupLabel() { return this.hasForecast ? 'Add indicative revenue line' : 'Start account forecast'; }
    get monthToggleLabel() { return this.showAllMonths ? 'Show six months' : 'Show all months'; }
    get hasDrafts() { return Object.keys(this.drafts).length > 0; }
    get currencyCode() { return this.overview?.currencyCode || 'GBP'; }
    get storedCurrencyCode() { return this.overview?.storedCurrencyCode; }
    get shownAccountCurrencyCode() { return this.accountCurrencyCode || this.overview?.accountCurrencyCode; }
    get hasStoredCurrencyMismatch() {
        return !!this.storedCurrencyCode && !!this.shownAccountCurrencyCode
            && this.storedCurrencyCode !== this.shownAccountCurrencyCode;
    }
    get sourceAgreementCurrencyDescription() {
        const sources = this.overview?.sourceAgreementCurrencies || [];
        return sources.length ? sources.map(item =>
            `${item.currencyCode} (${item.agreementCount} ${item.agreementCount === 1 ? 'agreement' : 'agreements'})`
        ).join(', ') : 'none in the visible forecast period';
    }
    get forecastFactCurrencyConsistent() { return this.overview?.forecastFactCurrencyConsistent === true; }
    get nativeForecastLabel() {
        return this.storedCurrencyCode
            ? `Edit Forecasts (standard grid, ${this.storedCurrencyCode})` : 'Edit Forecasts (standard grid)';
    }
    get existingProductOptions() { return this.existingProducts.map(item => ({ label: item.label, value: item.value })); }
    get addProductDisabled() { return this.saving || this.editing || !this.selectedExistingProduct; }
    get periods() {
        return [...new Set((this.overview?.rows || []).filter(row => !row.isTotal)
            .map(row => row.monthStart))].sort().map(key => ({ key, label: labelMonth(key) }));
    }
    get displayedPeriods() { return this.showAllMonths ? this.periods : this.periods.slice(0, 6); }
    get monthOptions() { return this.periods.map(p => ({ label: p.label, value: p.key })); }

    get productFilterOptions() {
        return [{ label: 'All products', value: ALL },
            ...this.allGridRows.map(row => ({ label: row.name, value: row.key }))];
    }
    get totalLabel() { return this.productFilter === ALL ? 'ACCOUNT TOTAL' : 'PRODUCT TOTAL'; }
    get gridRows() {
        return this.allGridRows.filter(row => this.productFilter === ALL || row.key === this.productFilter);
    }
    get allGridRows() {
        const grouped = new Map();
        for (const row of this.overview?.rows || []) {
            if (row.isTotal || !row.productId) continue;
            if (!grouped.has(row.productId)) grouped.set(row.productId, {
                key: row.productId,
                name: row.isIndicative ? 'Indicative revenue (unallocated products)' : row.productName,
                isIndicative: row.isIndicative,
                byMonth: new Map()
            });
            grouped.get(row.productId).byMonth.set(row.monthStart, row);
        }
        return [...grouped.values()].sort((a, b) => Number(a.isIndicative) - Number(b.isIndicative)
            || a.name.localeCompare(b.name)).map(line => {
            const sourced = [...line.byMonth.values()].filter(row => row.sources?.length);
            const valueOnly = sourced.length > 0 && sourced.every(row => row.isValueMode);
            const hasNewSource = sourced.some(row => row.sources.some(source => source.businessType === 'New business'));
            return {
            key: line.key, name: line.name, isIndicative: line.isIndicative || valueOnly,
            businessType: line.isIndicative ? 'Unallocated revenue' : hasNewSource ? 'New business' : 'Existing business',
            cells: this.displayedPeriods.map(period => {
                const row = line.byMonth.get(period.key);
                const draft = row ? this.drafts[row.key] || {} : {};
                const sources = (row?.sources || []).map(source => ({
                    ...source, key: source.scheduleId || source.opportunityId || source.agreementId,
                    agreementUrl: source.agreementId ? `/lightning/r/SalesAgreement/${source.agreementId}/view` : null,
                    scheduleUrl: source.scheduleId ? `/lightning/r/SalesAgreementProductSchedule/${source.scheduleId}/view` : null,
                    opportunityUrl: source.opportunityId
                        ? `/lightning/r/Opportunity/${source.opportunityId}/view` : null
                }));
                return {
                    key: `${line.key}-${period.key}`, factId: row?.key,
                    quantity: draft.quantity ?? number(row?.forecastQuantity),
                    revenue: draft.revenue ?? number(row?.forecastRevenue),
                    agreementQuantity: number(row?.agreementQuantity),
                    actualRevenue: number(row?.actualRevenue),
                    isIndicative: line.isIndicative || valueOnly || !!row?.isValueMode, hasFact: !!row,
                    hasSources: sources.length > 0, sources,
                    quantityLabel: `${line.name} quantity ${period.label}`,
                    revenueLabel: `${line.name} revenue ${period.label}`
                };
            })
        }; });
    }
    get totalCells() {
        return this.displayedPeriods.map((period, index) => {
            const cells = this.gridRows.map(row => row.cells[index]);
            return {
                key: period.key,
                quantity: cells.reduce((sum, cell) => sum + (cell.isIndicative ? 0 : cell.quantity), 0),
                revenue: cells.reduce((sum, cell) => sum + cell.revenue, 0),
                actualRevenue: cells.reduce((sum, cell) => sum + cell.actualRevenue, 0)
            };
        });
    }
    get massProductOptions() {
        return [{ label: 'All displayed lines', value: ALL },
            ...this.gridRows.map(row => ({ label: row.name, value: row.key }))];
    }
    get massMeasureOptions() {
        return [{ label: 'Forecast revenue', value: 'revenue' },
            { label: 'Forecast quantity', value: 'quantity' }];
    }
    get massActionOptions() {
        return [{ label: 'Replace with', value: 'replace' },
            { label: 'Increase by', value: 'increase' },
            { label: 'Decrease by', value: 'decrease' }];
    }

    toggleMonths() { this.showAllMonths = !this.showAllMonths; }
    handleProductFilter(e) {
        this.productFilter = e.detail.value;
        this.massProduct = ALL;
    }
    async refreshForecast() {
        if (!this.wiredOverview) return;
        this.drafts = {};
        this.editing = false;
        try {
            await refreshApex(this.wiredOverview);
        } catch (error) {
            this.toast(error.body?.message || 'The forecast could not be refreshed.', 'error');
        }
    }
    handleExistingProduct(e) { this.selectedExistingProduct = e.detail.value; }
    async handleAddExistingProduct() {
        if (this.addProductDisabled) return;
        this.saving = true;
        try {
            const productId = this.selectedExistingProduct;
            const added = await addExistingProduct({ accountId: this.recordId, productId });
            this.selectedExistingProduct = undefined;
            await refreshApex(this.wiredOverview);
            this.productFilter = productId;
            this.dispatchEvent(new ShowToastEvent({ title: 'Existing business product ready',
                message: added ? `${added} forecast months added. Enter monthly values using Quick edit.` : 'Product already appears in this forecast.',
                variant: 'success' }));
        } catch (e) { this.error = e.body?.message || e.message; }
        finally { this.saving = false; }
    }
    toggleEditing() { this.editing = !this.editing; this.drafts = {}; }
    discard() { this.drafts = {}; this.editing = false; }
    handleMassProduct(e) { this.massProduct = e.detail.value; }
    handleMassMeasure(e) { this.massMeasure = e.detail.value; }
    handleMassAction(e) { this.massAction = e.detail.value; }
    handleMassFrom(e) { this.massFrom = e.detail.value; }
    handleMassThrough(e) { this.massThrough = e.detail.value; }
    handleMassValue(e) { this.massValue = e.target.value; }
    handleMassPercent(e) { this.massPercent = e.target.checked; }
    handleCellChange(e) {
        const factId = e.target.dataset.factId;
        const field = e.target.dataset.field;
        const value = e.target.value === '' ? 0 : Number(e.target.value);
        this.drafts = { ...this.drafts, [factId]: { ...(this.drafts[factId] || {}), [field]: value } };
    }

    applyMassChange() {
        const value = Number(this.massValue);
        if (this.massValue === undefined || this.massValue === '' || !Number.isFinite(value) || value < 0
            || !this.massFrom || !this.massThrough || this.massFrom > this.massThrough
            || (this.massPercent && this.massAction === 'replace')) {
            this.toast('Select a valid month range, action, and nonnegative value.', 'error');
            return;
        }
        const next = { ...this.drafts };
        let count = 0;
        for (const row of this.overview?.rows || []) {
            if (row.isTotal || !row.productId || row.monthStart < this.massFrom || row.monthStart > this.massThrough
                || (this.productFilter !== ALL && row.productId !== this.productFilter)
                || (this.massProduct !== ALL && row.productId !== this.massProduct)
                || ((row.isIndicative || row.isValueMode) && this.massMeasure === 'quantity')) continue;
            const current = next[row.key]?.[this.massMeasure] ?? number(
                this.massMeasure === 'quantity' ? row.forecastQuantity : row.forecastRevenue);
            const delta = this.massPercent ? current * value / 100 : value;
            const target = this.massAction === 'replace' ? value
                : this.massAction === 'increase' ? current + delta : current - delta;
            if (target < 0) {
                this.toast('The change would make a forecast negative. Nothing was staged.', 'error');
                return;
            }
            const rounded = this.massMeasure === 'quantity' ? Math.round(target) : Math.round(target * 100) / 100;
            next[row.key] = { ...(next[row.key] || {}), [this.massMeasure]: rounded };
            count += 1;
        }
        if (!count) {
            this.toast('No forecast months matched that selection.', 'error');
            return;
        }
        this.drafts = next;
        this.toast(`${count} months staged. Review the grid and Save changes.`, 'info');
    }

    async save() {
        const edits = Object.entries(this.drafts).map(([factId, change]) => ({
            factId, forecastQuantity: change.quantity ?? null, forecastRevenue: change.revenue ?? null
        }));
        if (!edits.length) return;
        this.saving = true;
        try {
            const count = await saveForecastEdits({ accountId: this.recordId, edits });
            this.drafts = {};
            this.editing = false;
            await refreshApex(this.wiredOverview);
            this.toast(`${count} forecast months saved. Agreements and order actuals were not changed.`, 'success');
        } catch (error) {
            this.toast(error.body?.message || 'The forecast changes could not be saved.', 'error');
        } finally { this.saving = false; }
    }
    async startForecast() {
        this.saving = true;
        try {
            await ensureUnifiedForecast({ accountId: this.recordId });
            await refreshApex(this.wiredOverview);
            this.toast('The indicative revenue line is ready in the standard forecast grid.', 'success');
        } catch (error) {
            this.toast(error.body?.message || 'The forecast could not be started.', 'error');
        } finally { this.saving = false; }
    }
    exportCsv() {
        try {
        const header = ['Account ID', 'Month', 'Product', 'Forecast quantity', `Forecast revenue ${this.currencyCode}`,
            'Agreement demand quantity', `Agreement demand revenue ${this.currencyCode}`, 'Order actual quantity',
            `Order actual revenue ${this.currencyCode}`, 'Sales agreement IDs', 'Monthly schedule IDs', 'Opportunity IDs'];
        const rows = (this.overview?.rows || []).filter(row => !row.isTotal
            && (this.productFilter === ALL || row.productId === this.productFilter)).map(row => [
            this.recordId, row.monthStart, row.productName, row.forecastQuantity, row.forecastRevenue,
            row.agreementQuantity, row.agreementRevenue, row.actualQuantity, row.actualRevenue,
            (row.sources || []).map(source => source.agreementId).join(';'),
            (row.sources || []).map(source => source.scheduleId).join(';'),
            (row.sources || []).map(source => source.opportunityId).filter(Boolean).join(';')
        ]);
        const csv = [header, ...rows].map(row => row.map(csvCell).join(',')).join('\r\n');
        const url = URL.createObjectURL(new Blob([csv], { type: 'application/octet-stream' }));
        const link = this.template.querySelector('.download-anchor');
        link.href = url;
        link.download = `Carlton-account-forecast-${this.recordId}.csv`;
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 60000);
        } catch (error) {
            this.toast(error.message || 'CSV export failed.', 'error');
        }
    }
    toast(message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title: 'Account forecast', message, variant }));
    }
}