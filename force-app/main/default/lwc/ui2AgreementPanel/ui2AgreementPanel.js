import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import getAgreementView from '@salesforce/apex/SalesAgreementForecastService_CC.getAgreementView';
import reviseForecast from '@salesforce/apex/SalesAgreementForecastService_CC.reviseForecast';
import recalculateActuals from '@salesforce/apex/SalesAgreementForecastService_CC.recalculateActuals';
import extendTerm from '@salesforce/apex/SalesAgreementForecastService_CC.extendTerm';
import resumeActivation from '@salesforce/apex/SalesAgreementActivationJob_CC.resume';
import getEntryContext from '@salesforce/apex/AgreementReleaseOrderService_CC.getEntryContext';
import createRelease from '@salesforce/apex/AgreementReleaseOrderService_CC.createRelease';
import activateOrder from '@salesforce/apex/AgreementReleaseOrderService_CC.activateOrder';
import {
    STATE_CREATED, STATE_EXISTED, STATE_FAILED, monthlyRows, nextRow, nextReleaseNumber, validateRows, requestFor,
    applyResult, summarize, defaultProduct, reconcileProduct, sameProducts, validateLines
} from './releaseRows';

const MODE_ONE = 'one';
const MODE_SEVERAL = 'several';

const MONTH = new Intl.DateTimeFormat(undefined, { month: 'short', year: 'numeric', timeZone: 'UTC' });

export function monthLabel(isoDate) {
    return isoDate ? MONTH.format(new Date(`${isoDate}T00:00:00Z`)) : '';
}

/** ISO date of the first of the month `offset` months after isoDate (UTC, no time-zone drift). */
export function addMonths(isoDate, offset) {
    const d = new Date(`${isoDate}T00:00:00Z`);
    return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + offset, 1)).toISOString().slice(0, 10);
}

const DEFAULT_EXTENSION_MONTHS = 6;

export default class Ui2AgreementPanel extends NavigationMixin(LightningElement) {
    @api recordId;
    @track view;
    @track entry;
    @track edits = {};
    @track lines = [];
    reason = '';
    error;
    busy = false;
    showRevise = false;
    showOrder = false;
    showExtend = false;
    @track extendAmounts = [];
    extendReason = '';
    po = { poNumber: '', releaseNumber: '1', orderDate: new Date().toISOString().slice(0, 10), shipToSiteId: undefined, locationCode: undefined, shipmentMethod: 'EXW', activateNow: true };
    orderMode = MODE_ONE;
    @track releaseRows = [];
    bulk = { count: 6, agreementProductId: undefined, quantity: 1, chosen: false };
    progress = '';
    productsLoading = false;

    connectedCallback() {
        this.refresh();
    }

    async refresh() {
        try {
            this.view = await getAgreementView({ agreementId: this.recordId });
            this.error = undefined;
        } catch (e) {
            this.error = this.message(e);
        }
    }

    get productIds() {
        return (this.entry?.products || []).map((p) => p.value);
    }

    /** Takes a fresh entry context and re-checks every product choice against the agreement's current products. */
    applyEntry(entry) {
        this.entry = entry;
        const ids = this.productIds;
        const base = this.lines.length ? this.lines : [{ key: 'l0', agreementProductId: undefined, quantity: 1, chosen: false }];
        this.lines = base.map((l) => {
            const r = reconcileProduct(l.agreementProductId, l.chosen, ids);
            return { ...l, agreementProductId: r.value, chosen: r.chosen };
        });
        const b = reconcileProduct(this.bulk.agreementProductId, this.bulk.chosen, ids);
        this.bulk = { ...this.bulk, agreementProductId: b.value, chosen: b.chosen };
        this.releaseRows = this.releaseRows.map((r) => (r.state === STATE_CREATED || r.state === STATE_EXISTED
            || !r.agreementProductId || ids.includes(r.agreementProductId) ? r : { ...r, agreementProductId: undefined }));
    }

    /**
     * Products may be added to the agreement on this page after it loaded (Sales Agreement Products list). The form
     * reloads them when it is opened and when a Product box gets focus; nothing changes if the list is the same.
     */
    async reloadProducts() {
        if (this.productsLoading || this.busy) {
            return;
        }
        this.productsLoading = true;
        try {
            const entry = await getEntryContext({ agreementId: this.recordId });
            if (!sameProducts(this.productIds, (entry.products || []).map((p) => p.value))) {
                this.applyEntry(entry);
            }
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.productsLoading = false;
        }
    }
    handleProductFocus() {
        this.reloadProducts();
    }

    get currency() {
        return this.view?.currencyIsoCode;
    }
    get canReviseAgreement() {
        return !!this.view?.canReviseAgreement;
    }
    get hasMonthPlans() {
        return (this.view?.months || []).some((month) => !!month.monthPlanId);
    }
    get canRevisePlan() {
        return this.canReviseAgreement && this.hasMonthPlans;
    }
    get rows() {
        return (this.view?.months || []).map((m) => ({
            ...m,
            label: monthLabel(m.monthStart),
            attainment: m.attainmentPercent === null || m.attainmentPercent === undefined ? 'N/A' : `${m.attainmentPercent}%`,
            actualsText: m.orderActuals === null || m.orderActuals === undefined ? 'See Site split' : null,
            editValue: this.edits[m.monthPlanId] ?? m.currentForecast,
            canEdit: this.showRevise && !m.isUnplanned,
            typeClass: m.isUnplanned ? 'slds-badge slds-theme_warning' : m.isExtension ? 'slds-badge slds-badge_inverse' : 'slds-badge slds-badge_lightest',
            stateClass: m.monthState === 'Completed' ? '' : 'slds-text-color_weak'
        }));
    }
    get termRows() {
        const t = this.view?.totals;
        if (!t) {
            return [];
        }
        return [t.originalTerm, t.extension, t.unplanned, t.combined]
            .filter((s) => s && (s.months > 0 || s.label === 'Combined'))
            .map((s) => ({
                ...s,
                key: s.label,
                range: s.firstMonth ? `${monthLabel(s.firstMonth)} – ${monthLabel(s.lastMonth)} (${s.months})` : '—',
                attainment: s.completedAttainmentPercent === null || s.completedAttainmentPercent === undefined ? 'N/A' : `${s.completedAttainmentPercent}%`,
                rowClass: s.label === 'Combined' ? 'slds-text-title_bold' : ''
            }));
    }
    get isExtended() {
        return this.view?.extensionMonths > 0;
    }
    get extendDisabled() {
        return this.busy || this.view?.canExtend !== true;
    }
    get extendCount() {
        return this.extendAmounts.length;
    }
    get extendTotal() {
        return this.extendAmounts.reduce((sum, a) => sum + (Number(a.value) || 0), 0);
    }
    get extendRange() {
        if (!this.extendAmounts.length) {
            return '';
        }
        return `${this.extendAmounts[0].label} to ${this.extendAmounts[this.extendAmounts.length - 1].label}`;
    }
    get extendStep() {
        const decimals = this.view?.currencyDecimals ?? 2;
        return decimals > 0 ? `0.${'0'.repeat(decimals - 1)}1` : '1';
    }
    get revisions() {
        return (this.view?.revisions || []).map((r, i) => ({ ...r, key: `r${i}`, label: monthLabel(r.monthStart) }));
    }
    get hasRevisions() {
        return this.revisions.length > 0;
    }
    get statusVariant() {
        return this.view?.planStatus === 'Active' ? 'slds-badge slds-theme_success' : this.view?.planStatus === 'Activation Failed' ? 'slds-badge slds-theme_error' : 'slds-badge';
    }
    get canResume() {
        return this.view && this.view.planStatus !== 'Active';
    }
    get completedAttainment() {
        const t = this.view?.totals;
        return !t || t.completedAttainmentPercent === null || t.completedAttainmentPercent === undefined ? 'N/A' : `${t.completedAttainmentPercent}%`;
    }
    get siteOptions() {
        return (this.entry?.sites || []).map((s) => ({ label: s.label, value: s.value }));
    }
    get productOptions() {
        return (this.entry?.products || []).map((p) => ({ label: `${p.label} (${p.amount})`, value: p.value }));
    }
    get locationOptions() {
        return (this.entry?.locationCodes || []).map((o) => ({ label: o.label, value: o.value }));
    }
    get shipmentOptions() {
        return (this.entry?.shipmentMethods || []).map((o) => ({ label: o.label, value: o.value }));
    }
    get orders() {
        return (this.entry?.orders || []).map((o) => ({ ...o, canActivate: o.status === 'Draft' }));
    }
    get hasOrders() {
        return this.orders.length > 0;
    }
    get draftCount() {
        return this.orders.filter((o) => o.canActivate).length;
    }
    get hasDrafts() {
        return this.draftCount > 0;
    }
    get activateDraftsLabel() {
        return `Activate all Drafts (${this.draftCount})`;
    }
    get orderModeOptions() {
        return [{ label: 'One Order', value: MODE_ONE }, { label: 'Several Orders', value: MODE_SEVERAL }];
    }
    get isSeveral() {
        return this.orderMode === MODE_SEVERAL;
    }
    get orderDateLabel() {
        return this.isSeveral ? 'First order date' : 'Order date';
    }
    get releaseRowsView() {
        const productLabel = new Map((this.entry?.products || []).map((p) => [p.value, p.label]));
        return this.releaseRows.map((r, i) => ({
            ...r,
            index: i + 1,
            locked: r.state === STATE_CREATED || r.state === STATE_EXISTED,
            productName: productLabel.get(r.agreementProductId) || '',
            stateClass: r.state === STATE_FAILED ? 'slds-text-color_error' : r.state === STATE_CREATED ? 'slds-text-color_success' : 'slds-text-color_weak'
        }));
    }
    get hasReleaseRows() {
        return this.releaseRows.length > 0;
    }
    get pendingRowCount() {
        return this.releaseRows.filter((r) => r.state !== STATE_CREATED && r.state !== STATE_EXISTED).length;
    }
    get createSeveralLabel() {
        const n = this.pendingRowCount;
        return n === 1 ? 'Create 1 Order' : `Create ${n} Orders`;
    }
    get createSeveralDisabled() {
        return this.busy || this.pendingRowCount === 0;
    }

    toggleRevise() {
        this.showRevise = !this.showRevise;
        this.edits = {};
    }
    toggleOrder() {
        this.showOrder = !this.showOrder;
        if (this.showOrder) {
            this.reloadProducts();
        }
    }
    toggleExtend() {
        this.showExtend = !this.showExtend;
        this.extendReason = '';
        this.buildExtension(DEFAULT_EXTENSION_MONTHS, []);
    }
    /** One input per extension month from the month after the last planned month; keeps values already typed. */
    buildExtension(count, previous) {
        const start = this.view?.nextExtensionMonth;
        const n = Math.max(0, Math.floor(Number(count) || 0));
        this.extendAmounts = start
            ? Array.from({ length: n }, (_, i) => {
                const month = addMonths(start, i);
                return { key: month, month, label: monthLabel(month), value: previous[i]?.value ?? 0 };
            })
            : [];
    }
    handleExtendCount(e) {
        this.buildExtension(e.target.value, this.extendAmounts);
    }
    handleExtendFill(e) {
        const value = e.target.value === '' ? 0 : Number(e.target.value);
        this.extendAmounts = this.extendAmounts.map((a) => ({ ...a, value }));
    }
    handleExtendAmount(e) {
        const key = e.target.dataset.key;
        const value = e.target.value === '' ? 0 : Number(e.target.value);
        this.extendAmounts = this.extendAmounts.map((a) => (a.key === key ? { ...a, value } : a));
    }
    handleExtendReason(e) {
        this.extendReason = e.target.value;
    }

    async handleSaveExtension() {
        await this.run(async () => {
            const message = await extendTerm({
                agreementId: this.recordId,
                monthlyAmounts: this.extendAmounts.map((a) => a.value),
                reason: this.extendReason
            });
            this.toast('Term extended', message, 'success');
            this.showExtend = false;
            this.extendReason = '';
            this.extendAmounts = [];
        });
    }
    handleEdit(e) {
        this.edits = { ...this.edits, [e.target.dataset.id]: e.target.value === '' ? 0 : Number(e.target.value) };
    }
    handleReason(e) {
        this.reason = e.target.value;
    }

    async handleSaveRevision() {
        const changes = Object.entries(this.edits).map(([monthPlanId, newForecast]) => ({ monthPlanId, newForecast }));
        await this.run(async () => {
            const count = await reviseForecast({ agreementId: this.recordId, changes, reason: this.reason });
            this.toast('Forecast revised', `${count} month(s) changed. Original plan and won amount are unchanged.`, 'success');
            this.showRevise = false;
            this.edits = {};
            this.reason = '';
        });
    }

    async handleRecalculate() {
        await this.run(async () => this.toast('Recalculate', await recalculateActuals({ agreementId: this.recordId }), 'info'));
    }

    async handleResume() {
        await this.run(async () => this.toast('Activation', await resumeActivation({ agreementId: this.recordId }), 'info'));
    }

    handlePo(e) {
        const field = e.target.dataset.field;
        const value = e.target.type === 'checkbox' || e.target.type === 'toggle' ? e.target.checked : e.detail?.value ?? e.target.value;
        this.po = { ...this.po, [field]: value };
    }
    handleLineProduct(e) {
        this.lines = this.lines.map((l) => (l.key === e.target.dataset.key ? { ...l, agreementProductId: e.detail.value, chosen: true } : l));
    }
    handleLineQty(e) {
        this.lines = this.lines.map((l) => (l.key === e.target.dataset.key ? { ...l, quantity: Number(e.target.value) } : l));
    }
    handleAddLine() {
        this.lines = [...this.lines, { key: `l${Date.now()}`, agreementProductId: defaultProduct(this.productIds), quantity: 1, chosen: false }];
    }
    handleRemoveLine(e) {
        this.lines = this.lines.filter((l) => l.key !== e.target.dataset.key);
    }

    async handleCreateOrder() {
        const problems = validateLines(this.lines);
        if (problems.length) {
            this.error = problems.join(' ');
            return;
        }
        await this.run(async () => {
            const result = await createRelease({
                request: { ...this.po, agreementId: this.recordId, lines: this.lines.map((l) => ({ agreementProductId: l.agreementProductId, quantity: l.quantity })) }
            });
            this.toast(result.alreadyExisted ? 'Already entered' : 'Order created', `${result.orderNumber}: ${result.message}`, result.alreadyExisted ? 'warning' : 'success');
            this.po = { ...this.po, poNumber: '', releaseNumber: '1' };
        });
    }

    // ---------------------------------------------------------------- several Orders at once

    handleOrderMode(e) {
        this.orderMode = e.detail.value;
        this.reloadProducts();
    }
    handleBulk(e) {
        const field = e.target.dataset.field;
        this.bulk = { ...this.bulk, [field]: e.detail?.value ?? e.target.value, ...(field === 'agreementProductId' ? { chosen: true } : {}) };
    }
    /** Generates monthly release rows from the Order date, numbered after the PO's existing releases. */
    handleGenerateRows() {
        const firstRelease = Math.max(nextReleaseNumber(this.po.poNumber, this.entry?.orders), this.highestRowRelease() + 1);
        const generated = monthlyRows({
            start: this.po.orderDate,
            count: this.bulk.count,
            firstRelease,
            agreementProductId: this.bulk.agreementProductId,
            quantity: this.bulk.quantity
        });
        this.releaseRows = [...this.releaseRows, ...generated];
    }
    handleAddReleaseRow() {
        this.releaseRows = [...this.releaseRows, nextRow(this.releaseRows, {
            start: this.po.orderDate,
            firstRelease: nextReleaseNumber(this.po.poNumber, this.entry?.orders),
            agreementProductId: this.bulk.agreementProductId || defaultProduct(this.productIds)
        })];
    }
    handleRowField(e) {
        const { key, field } = e.target.dataset;
        const value = e.detail?.value ?? e.target.value;
        this.releaseRows = this.releaseRows.map((r) => (r.key === key ? { ...r, [field]: value, state: r.state === STATE_FAILED ? 'pending' : r.state, message: r.state === STATE_FAILED ? '' : r.message } : r));
    }
    handleRemoveReleaseRow(e) {
        this.releaseRows = this.releaseRows.filter((r) => r.key !== e.target.dataset.key);
    }
    handleClearCreatedRows() {
        this.releaseRows = this.releaseRows.filter((r) => r.state !== STATE_CREATED && r.state !== STATE_EXISTED);
    }
    highestRowRelease() {
        return this.releaseRows.reduce((max, r) => Math.max(max, parseInt(r.releaseNumber, 10) || 0), 0);
    }

    /**
     * Creates every pending row, one release at a time (each is its own transaction, with its own duplicate check and
     * result). A failed row stays in the list with its message; the others carry on.
     */
    async handleCreateSeveral() {
        const problems = validateRows(this.po, this.releaseRows);
        if (problems.length) {
            this.error = problems.join(' ');
            return;
        }
        await this.run(async () => {
            const pending = this.releaseRows.filter((r) => r.state !== STATE_CREATED && r.state !== STATE_EXISTED);
            let done = 0;
            for (const row of pending) {
                done += 1;
                this.progress = `Creating release ${row.releaseNumber} (${done} of ${pending.length})…`;
                let updated;
                try {
                    // Sequential on purpose: one release per server call keeps each within its own limits.
                    // eslint-disable-next-line no-await-in-loop
                    const result = await createRelease({ request: requestFor(this.recordId, this.po, row) });
                    updated = applyResult(row, result);
                } catch (err) {
                    updated = applyResult(row, null, this.message(err));
                }
                this.releaseRows = this.releaseRows.map((r) => (r.key === row.key ? updated : r));
            }
            this.progress = '';
            const summary = summarize(this.releaseRows);
            this.toast('Several Orders', summary.text, summary.failed ? 'warning' : 'success');
        });
    }

    async handleActivate(e) {
        const orderId = e.target.dataset.id;
        await this.run(async () => this.toast('Order', await activateOrder({ orderId }), 'success'));
    }

    /** Activates every Draft release Order on this agreement, one at a time; reports how many succeeded. */
    async handleActivateDrafts() {
        const drafts = this.orders.filter((o) => o.canActivate);
        await this.run(async () => {
            let ok = 0;
            const failures = [];
            for (const o of drafts) {
                try {
                    // eslint-disable-next-line no-await-in-loop
                    await activateOrder({ orderId: o.orderId });
                    ok += 1;
                } catch (err) {
                    failures.push(`${o.orderNumber}: ${this.message(err)}`);
                }
            }
            this.toast('Activate Drafts', `${ok} of ${drafts.length} activated.${failures.length ? ' ' + failures.join(' ') : ''}`,
                failures.length ? 'warning' : 'success');
        });
    }

    handleOpen(e) {
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: e.target.dataset.id, actionName: 'view' } });
    }

    async run(work) {
        if (this.busy) {
            return;
        }
        this.busy = true;
        this.error = undefined;
        try {
            await work();
            await this.refresh();
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.busy = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    message(e) {
        return e?.body?.message || e?.message || 'Something went wrong.';
    }
}