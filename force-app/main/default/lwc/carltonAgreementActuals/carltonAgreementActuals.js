import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getOverview from '@salesforce/apex/CarltonAgreementActualsController.getOverview';
import saveActual from '@salesforce/apex/CarltonAgreementActualsController.saveActual';
import saveForecast from '@salesforce/apex/CarltonAgreementActualsController.saveForecast';

export default class CarltonAgreementActuals extends LightningElement {
    @api recordId;
    selectedAgreementId = 'ALL';
    selectedMonthKey = 'ALL';
    overview;
    wiredResult;
    error;
    editing = false;
    restoring = false;
    editingForecast = false;
    editRow;
    draftAmount;
    draftReason = '';
    saveError;
    saving = false;

    @wire(getOverview, { accountId: '$recordId' })
    loadOverview(result) {
        this.wiredResult = result;
        if (result.data) {
            this.overview = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error.body?.message || 'Agreement actuals could not be loaded.';
            this.overview = undefined;
        }
    }

    get agreementOptions() {
        return [{ label: 'All sales agreements', value: 'ALL' },
            ...(this.overview?.agreements || []).map(agreement => ({ label: agreement.name, value: agreement.id }))];
    }

    get rows() {
        return (this.overview?.rows || []).map(row => ({
            ...row,
            statusLabel: row.hasOverride ? 'Recorded override' : 'Salesforce actual',
            amountClass: row.hasOverride ? 'override' : '',
            agreementUrl: `/lightning/r/SalesAgreement/${row.agreementId}/view`,
            opportunityUrl: row.opportunityId ? `/lightning/r/Opportunity/${row.opportunityId}/view` : null
        }));
    }

    get monthOptions() {
        const months = new Map();
        for (const row of this.rows) months.set(row.monthKey, row.monthLabel);
        return [{ label: 'All months', value: 'ALL' },
            ...[...months.entries()].sort((a, b) => b[0].localeCompare(a[0]))
                .map(([value, label]) => ({ value, label }))];
    }

    get visibleRows() {
        return this.rows.filter(row =>
            (this.selectedAgreementId === 'ALL' || row.agreementId === this.selectedAgreementId) &&
            (this.selectedMonthKey === 'ALL' || row.monthKey === this.selectedMonthKey));
    }

    get hasRows() {
        return this.visibleRows.length > 0;
    }

    get currencyTotals() {
        const totals = new Map();
        for (const row of this.visibleRows) {
            const code = row.currencyCode || 'USD';
            if (!totals.has(code)) totals.set(code, { code, sourceActual: 0, effectiveActual: 0, forecastQuantity: 0, forecastRevenueBasis: 0 });
            const total = totals.get(code);
            total.sourceActual += Number(row.sourceActual || 0);
            total.effectiveActual += Number(row.effectiveActual || 0);
            total.forecastQuantity += Number(row.forecastQuantity || 0);
            total.forecastRevenueBasis += Number(row.forecastRevenueBasis || 0);
        }
        return [...totals.values()];
    }

    handleAgreementChange(event) {
        this.selectedAgreementId = event.detail.value;
    }

    handleMonthChange(event) {
        this.selectedMonthKey = event.detail.value;
    }

    openEditor(event, restoring, forecast = false) {
        this.editRow = this.rows.find(row => row.id === event.currentTarget.dataset.id);
        if (!this.editRow) return;
        this.restoring = restoring;
        this.editingForecast = forecast;
        this.draftAmount = forecast ? this.editRow.forecastQuantity : this.editRow.effectiveActual;
        this.draftReason = '';
        this.saveError = undefined;
        this.editing = true;
    }

    handleEdit(event) {
        this.openEditor(event, false);
    }

    handleRestore(event) {
        this.openEditor(event, true);
    }

    handleEditForecast(event) {
        this.openEditor(event, false, true);
    }

    handleAmountChange(event) {
        this.draftAmount = event.detail.value;
    }

    handleReasonChange(event) {
        this.draftReason = event.detail.value;
    }

    handleCancel() {
        this.editing = false;
    }

    async handleSave() {
        const reason = (this.draftReason || '').trim();
        const amount = Number(this.draftAmount);
        if (!reason || (!this.restoring && (this.draftAmount === '' || this.draftAmount === null || !Number.isFinite(amount) || amount < 0 || (this.editingForecast && !Number.isInteger(amount))))) {
            this.saveError = 'Enter a valid amount and a source or reason.';
            return;
        }
        this.saving = true;
        this.saveError = undefined;
        try {
            if (this.editingForecast) {
                await saveForecast({ accountId: this.recordId, scheduleId: this.editRow.id,
                    forecastQuantity: amount, reason });
            } else {
                await saveActual({ accountId: this.recordId, scheduleId: this.editRow.id,
                    overrideAmount: this.restoring ? null : amount, useSourceActual: this.restoring, reason });
            }
            await refreshApex(this.wiredResult);
            this.editing = false;
            this.dispatchEvent(new ShowToastEvent({ title: this.editingForecast ? 'Monthly agreement forecast saved' : 'Actual amount saved', variant: 'success' }));
        } catch (error) {
            this.saveError = error.body?.message || 'The monthly amount could not be saved.';
        } finally {
            this.saving = false;
        }
    }
}