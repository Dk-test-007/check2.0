import { LightningElement, api, wire } from 'lwc';
import getSiteSelectionData  from '@salesforce/apex/SiteSelectionController_CC.getSiteSelectionData';
import saveSites  from '@salesforce/apex/SiteSelectionController_CC.saveSites';
import updatePrimarySite   from '@salesforce/apex/SiteSelectionController_CC.updatePrimarySite';
import updateOrderShipToSite from '@salesforce/apex/SiteSelectionController_CC.updateOrderShipToSite';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import ACCOUNT_OBJECT from '@salesforce/schema/Account';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';

export default class SiteSelection_CC extends NavigationMixin(LightningElement) {

    _recordId;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        console.log('recordId set to: ', value);
        this._recordId = value;
        if (this._recordId) {
            this.loadSiteSelectionData();
        }
    }

    siteSelectionData = {};
    allSitesRelatedToEntity = [];
    existingSites = [];
    selectedSiteIds = [];
    primarySiteId = '';
    currentOrderShipToSiteId = null;
    currentOrderShipToSiteName = '';
    searchTerm = '';
    showSelected = false;
    currentMode = 'options';
    currentStep = 'selection';
    isCreateModalOpen = false;
    isSaving = false;
    siteRecordTypeId;
    siteLayoutSections = [];
    isWaitingForSiteCreateReturn = false;
    hasOpenedSiteCreatePage = false;
    sortedBy = 'Name';
    sortDirection = 'asc';

    @wire(getObjectInfo, { objectApiName: ACCOUNT_OBJECT })
    wiredAccountInfo({ data, error }) {
        if (data) {
            const siteRecordType = Object.values(data.recordTypeInfos)
                .find(recordType =>
                    recordType.name === 'Site' && recordType.available
                );

            this.siteRecordTypeId = siteRecordType?.recordTypeId;
        } else if (error) {
            this.showToast(
                'Error',
                'Unable to retrieve Site record type.',
                'error'
            );
        }
    }

    @wire(CurrentPageReference)
    wiredCurrentPageReference(pageReference) {
        if (!pageReference || !this.isWaitingForSiteCreateReturn) {
            return;
        }

        const isSiteCreatePage =
            pageReference.type === 'standard__objectPage' &&
            pageReference.attributes?.objectApiName === 'Account' &&
            pageReference.attributes?.actionName === 'new';

        if (isSiteCreatePage) {
            this.hasOpenedSiteCreatePage = true;
            return;
        }

        if (this.hasOpenedSiteCreatePage) {
            this.isWaitingForSiteCreateReturn = false;
            this.hasOpenedSiteCreatePage = false;
            this.loadSiteSelectionData();
        }
    }

    get selectSiteNextFooterLabel() {
        return this.requiresPrimarySelection ? 'Next' : 'Save';
    }

    get hasExistingSites() {
        return this.existingSites.length > 0;
    }

    get showModeOptions() {
        return this.hasExistingSites && this.currentMode === 'options';
    }

    get isAddMode() {
        return this.currentMode === 'add';
    }

    get isChangePrimaryMode() {
        return this.currentMode === 'changePrimary';
    }

    get isOrderMode() {
        return this.siteSelectionData?.parentObjectName === 'Order';
    }

    get hasCurrentOrderShipToSite() {
        return this.isOrderMode && !!this.currentOrderShipToSiteId;
    }

    get orderSaveDisabled() {
        return this.isSaving || this.selectedSiteIds.length !== 1;
    }

    get showSelectionScreen() {
        return this.currentStep === 'selection';
    }

    get showPrimaryScreen() {
        return this.currentStep === 'primary';
    }

    get parentAccountId() {
        return this.siteSelectionData?.parentRecord?.AccountId;
    }

    get parentObjectLabel() {
        if (this.siteSelectionData?.parentObjectName === 'Quote') {
            return 'Quote';
        }
        if (this.isOrderMode) {
            return 'Order';
        }
        return 'Opportunity';
    }

    get existingSitesNotRelatedToParent() {
        // Orders select from all Sites under Order.AccountId. They do not use
        // Opportunity_Site__c associations.
        if (this.isOrderMode) {
            // Do not offer the Order's currently assigned Ship-to Customer No.
            // as a replacement option. This filter is Order-only; the
            // Opportunity and Quote site-selection logic below is unchanged.
            return this.allSitesRelatedToEntity.filter(
                site => site.Id !== this.currentOrderShipToSiteId
            );
        }

        const existingSiteIds = new Set(
            this.existingSites.map(site => site.Site__c)
        );

        return this.allSitesRelatedToEntity.filter(
            site => !existingSiteIds.has(site.Id)
        );
    }

    get selectedSites() {
        return this.allSitesRelatedToEntity.filter(
            site => this.selectedSiteIds.includes(site.Id)
        );
    }

    get availableSiteRows() {

        let rows = this.existingSitesNotRelatedToParent.map(site => ({
            ...site,
            shippingAddress: [
                site.ShippingStreet,
                site.ShippingCity,
                site.ShippingState,
                site.ShippingPostalCode,
                site.ShippingCountry
            ].filter(Boolean).join(', ')
        }));

        if (this.searchTerm) {
            rows = rows.filter(site =>
                site.Name?.toLowerCase().includes(this.searchTerm)
            );
        }

        if (this.showSelected) {
            rows = rows.filter(site =>
                this.selectedSiteIds.includes(site.Id)
            );
        }

        return this.sortData(rows);
    }

    get selectedPrimaryOptions() {
        return this.selectedSites.map(site => ({
            label: site.Name,
            value: site.Id
        }));
    }

    get existingPrimaryOptions() {
        return this.existingSites.map(site => ({
            label: site.Site__r?.Name || site.Site_Name_CC__c,
            value: site.Site__c
        }));
    }

    get primarySelectionRows() {

        let rows = [];

        if (this.isChangePrimaryMode || !this.existingSites.some(site => site.Primary__c)) {
            rows = this.existingSites.map(site => ({
                Id: site.Site__c,
                Name: site.Site__r?.Name || site.Site_Name_CC__c,
                shippingAddress: site.Shipping_Address__c,
                isPrimary: site.Site__c === this.primarySiteId
            }));
        }

        if (!this.isChangePrimaryMode) {
            const selectedRows = this.selectedSites.map(site => ({
                Id: site.Id,
                Name: site.Name,
                shippingAddress: [
                    site.ShippingStreet,
                    site.ShippingCity,
                    site.ShippingState,
                    site.ShippingPostalCode,
                    site.ShippingCountry
                ].filter(Boolean).join(', '),
                isPrimary: site.Id === this.primarySiteId
            }));

            rows = [...rows, ...selectedRows];
        }

        return rows;
    }

    get requiresPrimarySelection() {
        return !this.hasExistingSites ||
            !this.existingSites.some(site => site.Primary__c);
    }

    get showAddPrimarySelector() {
        return this.isAddMode && this.requiresPrimarySelection &&
            this.selectedSiteIds.length > 0;
    }

    get selectedLabel() {
        return this.showSelected ? 'Show All' : 'Show Selected';
    }

    get siteColumns() {
        return [
            {
                label: 'Site',
                fieldName: 'Name',
                type: 'text',
                sortable: true
            },
            {
                label: 'Shipping Address',
                fieldName: 'shippingAddress',
                type: 'text',
                sortable: true
            }
        ];
    }

    get saveDisabled() {
        return this.isSaving || this.selectedSiteIds.length === 0;
    }

    get nextDisabled() {
        return this.isSaving || this.selectedSiteIds.length === 0;
    }

    get primarySaveDisabled() {
        return this.isSaving || (this.isChangePrimaryMode && !this.primarySiteId);
    }

    loadSiteSelectionData() {

        getSiteSelectionData({ recordId: this._recordId })
            .then(result => {

                this.siteSelectionData = result;

                this.allSitesRelatedToEntity =
                    result.relatedSiteAccounts || [];

                this.existingSites = result.existingSites || [];
                this.currentOrderShipToSiteId = result.currentOrderShipToSiteId || null;
                this.currentOrderShipToSiteName = result.currentOrderShipToSiteName || '';

                this.selectedSiteIds = [];
                this.primarySiteId = '';

                this.searchTerm = '';
                this.showSelected = false;
                this.currentStep = 'selection';

                this.currentMode = this.isOrderMode
                    ? 'add'
                    : (this.hasExistingSites ? 'options' : 'add');

            })
            .catch(error => {
                this.showToast(
                    'Error',
                    this.getErrorMessage(error),
                    'error'
                );
            });
    }

    handleAddMoreSites() {
        this.currentMode = 'add';
        this.currentStep = 'selection';
        this.selectedSiteIds = [];
        this.primarySiteId = '';
        this.searchTerm = '';
        this.showSelected = false;
    }

    handleChangePrimary() {
        this.currentMode = 'changePrimary';
        this.currentStep = 'primary';
        const currentPrimary = this.existingSites.find(
            site => site.Primary__c
        );

        this.primarySiteId = currentPrimary?.Site__c || '';
    }

    handleBack() {
        this.currentMode = this.hasExistingSites
            ? 'options'
            : 'add';

        this.currentStep = 'selection';
        this.selectedSiteIds = [];
        this.primarySiteId = '';
        this.searchTerm = '';
        this.showSelected = false;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    closeAndRefresh() {
        this.dispatchEvent(new CloseActionScreenEvent());

        window.setTimeout(() => {
            window.location.reload();
        }, 500);
    }

    handleBackToSelection() {
        this.currentStep = 'selection';
    }

    handlePrimaryBack() {
        if (this.isChangePrimaryMode) {
            this.currentMode = 'options';
            this.currentStep = 'selection';
        } else {
            this.handleBackToSelection();
        }
    }

    handleNext() {
        if (!this.selectedSiteIds.length) {
            return;
        }

        if (this.requiresPrimarySelection) {
            // Always show the optional Shipment Site step when no Shipment Site
            // has been designated yet. Do not default-select even a single site.
            this.primarySiteId = '';
            this.currentStep = 'primary';
        } else {
            this.handleSaveSites();
        }
    }

    handleSearch(event) {
        this.searchTerm = event.target.value.toLowerCase().trim();
    }

    handleToggleSelected() {
        this.showSelected = !this.showSelected;
    }

    handleSelection(event) {
        const selectedRows = event.detail.selectedRows || [];

        this.selectedSiteIds = this.isOrderMode
            ? selectedRows.slice(0, 1).map(row => row.Id)
            : selectedRows.map(row => row.Id);

        if (!this.selectedSiteIds.includes(this.primarySiteId)) {
            this.primarySiteId = '';
        }
    }

    handlePrimarySelection(event) {
        this.primarySiteId = event.target.value;
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;
    }

    sortData(data) {
        const field = this.sortedBy;
        const direction = this.sortDirection === 'asc' ? 1 : -1;

        return [...data].sort((a, b) => {

            const valueA = a[field] || '';
            const valueB = b[field] || '';

            return String(valueA).localeCompare(
                String(valueB),
                undefined,
                { numeric: true, sensitivity: 'base' }
            ) * direction;
        });
    }

    handleCreateSite() {
        if (!this.siteRecordTypeId) {
            this.showToast(
                'Error',
                'Site record type is unavailable.',
                'error'
            );
            return;
        }

        if (!this.parentAccountId) {
            this.showToast(
                'Error',
                'Parent Account is not available.',
                'error'
            );
            return;
        }

        const defaultFieldValues = encodeDefaultFieldValues({
            ParentId: this.parentAccountId
        });

        this.isWaitingForSiteCreateReturn = true;
        this.hasOpenedSiteCreatePage = false;

        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Account',
                actionName: 'new'
            },
            state: {
                recordTypeId: this.siteRecordTypeId,
                defaultFieldValues: defaultFieldValues
            }
        });
    }

    handleCloseCreateModal() {
        this.isCreateModalOpen = false;
    }

    handleCreateSiteSubmit(event) {
        event.preventDefault();
        const fields = { ...event.detail.fields };
        fields.ParentId = this.parentAccountId;
        this.template.querySelector('lightning-record-edit-form').submit(fields);
    }

    handleSiteCreated() {
        this.isCreateModalOpen = false;

        this.showToast(
            'Success',
            'Site created successfully.',
            'success'
        );

        this.loadSiteSelectionData();
    }

    handleOrderSave() {
        // Orders always use a single selection screen. Save updates only the
        // Order Ship-to Customer No. and the Order-level Location Code.
        if (!this.isOrderMode || this.selectedSiteIds.length !== 1) {
            return;
        }

        this.saveOrderShipToSite();
    }

    saveOrderShipToSite() {
        this.isSaving = true;

        updateOrderShipToSite({
            orderId: this._recordId,
            siteId: this.selectedSiteIds[0]
        })
            .then(() => {
                this.showToast(
                    'Success',
                    'Order Ship-to Customer No. and Location updated successfully.',
                    'success'
                );
                this.closeAndRefresh();
            })
            .catch(error => {
                this.showToast(
                    'Error',
                    this.getErrorMessage(error),
                    'error'
                );
            })
            .finally(() => {
                this.isSaving = false;
            });
    }

    handleSaveSites() {
        if (!this.selectedSiteIds.length) {
            return;
        }

        this.isSaving = true;

        saveSites({
            recordId: this._recordId,
            siteIds: this.selectedSiteIds,
            primarySiteId: this.primarySiteId || null
        })
            .then(() => {

                this.showToast(
                    'Success',
                    'Sites added successfully.',
                    'success'
                );

                this.closeAndRefresh();
            })
            .catch(error => {
                this.showToast(
                    'Error',
                    this.getErrorMessage(error),
                    'error'
                );
            })
            .finally(() => {
                this.isSaving = false;
            });
    }

    handleSavePrimarySite() {
        if (!this.primarySiteId) {
            return;
        }

        this.isSaving = true;

        updatePrimarySite({
            recordId: this._recordId,
            siteId: this.primarySiteId
        })
            .then(() => {

                this.showToast(
                    'Success',
                    'Shipment Site updated successfully.',
                    'success'
                );

                this.closeAndRefresh();
            })
            .catch(error => {
                this.showToast(
                    'Error',
                    this.getErrorMessage(error),
                    'error'
                );
            })
            .finally(() => {
                this.isSaving = false;
            });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    getErrorMessage(error) {
        return error?.body?.message ||
            error?.message ||
            'An unexpected error occurred. Please contact your System Administrator';
    }
}