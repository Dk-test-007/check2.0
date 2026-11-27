import { api, LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { deleteRecord, getRecord } from 'lightning/uiRecordApi';
import { RefreshEvent, registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import getInitialData from '@salesforce/apex/ProductRelatedListController_CC.getInitialData';
import getPricebooks from '@salesforce/apex/ProductRelatedListController_CC.getPricebooks';
import getProducts from '@salesforce/apex/ProductRelatedListController_CC.getProducts';
import changePricebook from '@salesforce/apex/ProductRelatedListController_CC.changePricebook';
import saveProducts from '@salesforce/apex/ProductRelatedListController_CC.saveProducts';

const AMOUNT_FORMATTER = new Intl.NumberFormat(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
});

// New Business Orders permit edits only to these line-item fields.
const NEW_BUSINESS_EDITABLE_FIELDS = new Set([
    'Warehouse_CC__c',
    'Shipment_Date_CC__c',
    'Location_Code_CC__c'
]);

export default class ProductRelatedList_CC extends NavigationMixin(LightningElement) {
    @api recordId;
    @api showAddProducts;
    @api showEditProducts;
    @api showChoosePricebook;

    vm;
    rows = [];
    relatedColumns = [];
    editColumns = [];
    editRows = [];
    productColumns = [];
    productRows = [];
    pricebooks = [];
    selectedProducts = [];

    nextProductCursorName;
    nextProductCursorEntryId;
    hasMoreProducts = false;
    loadingMoreProducts = false;
    loadedProductSearchTerm = '';
    productRequestId = 0;

    selectedPricebookId;
    searchTerm = '';
    searchTimeout;
    drafts = [];
    removedIds = [];
    showSelectedOnly = false;
    refreshHandlerId;

    rowEditFields = [];
    rowEditLastModifiedDate;
    availabilityProductIds = [];

    editTableResizeObserver;
    editTableResizeTarget;
    availabilityOverlayResizeObserver;
    availabilityOverlayResizeTarget;
    lastEditTableWidth = 0;
    editColumnWidthsReady = false;
    editTableHostStyle = 'width: 100%; min-width: 100%;';
    editColumnResizeRatios = null;


    sortedBy;
    sortDirection = 'asc';

    modal;
    rowEditRecordId;
    afterPricebook = false;
    isAddProductFlow = false;
    showAvailabilityModal = false;
    deleteTarget;
    busy = false;

    connectedCallback() {
        this.refreshHandlerId = registerRefreshHandler(
            this,
            this.handleViewRefresh
        );

        this.refresh();
    }

    renderedCallback() {
        const container = this.template.querySelector('.edit-product-table-container');

        if (!container) {
            this.editTableResizeObserver?.disconnect();
            this.editTableResizeObserver = null;
            this.editTableResizeTarget = null;
            this.lastEditTableWidth = 0;
        } else {
            if (container !== this.editTableResizeTarget) {
                this.editTableResizeObserver?.disconnect();
                this.editTableResizeObserver = null;
                this.editTableResizeTarget = container;
                this.lastEditTableWidth = 0;

                const ResizeObserverConstructor = window.ResizeObserver;
                if (ResizeObserverConstructor) {
                    this.editTableResizeObserver = new ResizeObserverConstructor((entries) => {
                        this.handleEditTableResize(entries[0]?.contentRect?.width);
                    });
                    this.editTableResizeObserver.observe(container);
                }
            }

            // Calculate widths before the datatable is mounted. This ensures the first
            // datatable render receives the configured fixedWidth values.
            this.handleEditTableResize(container.getBoundingClientRect().width);
        }

        // The availability panel is sized to the actual visible modal surface
        // (header through footer), not the full-height SLDS modal container.
        this.syncAvailabilityModalOverlay();
    }

    syncAvailabilityModalOverlay() {
        const overlay = this.template.querySelector('.availability-modal-overlay');
        const modalContainer = this.template.querySelector('.standard-modal-container');

        if (!overlay || !modalContainer) {
            this.availabilityOverlayResizeObserver?.disconnect();
            this.availabilityOverlayResizeObserver = null;
            this.availabilityOverlayResizeTarget = null;
            return;
        }

        this.updateAvailabilityModalOverlayBounds(modalContainer, overlay);

        if (modalContainer === this.availabilityOverlayResizeTarget) {
            return;
        }

        this.availabilityOverlayResizeObserver?.disconnect();
        this.availabilityOverlayResizeObserver = null;
        this.availabilityOverlayResizeTarget = modalContainer;

        const ResizeObserverConstructor = window.ResizeObserver;
        if (!ResizeObserverConstructor) {
            return;
        }

        this.availabilityOverlayResizeObserver = new ResizeObserverConstructor(() => {
            this.updateAvailabilityModalOverlayBounds(modalContainer, overlay);
        });

        // Observe only the visible modal panel. The original close button is
        // intentionally excluded because it sits above the panel header.
        [
            modalContainer,
            modalContainer.querySelector('.slds-modal__header'),
            modalContainer.querySelector('.modal-content'),
            modalContainer.querySelector('.slds-modal__footer')
        ].filter(Boolean).forEach((element) => {
            this.availabilityOverlayResizeObserver.observe(element);
        });
    }

    updateAvailabilityModalOverlayBounds(modalContainer, overlay) {
        // Use the actual CSS containing block for absolute positioning instead
        // of assuming the modal container is always the offset parent.
        const positioningParent = overlay.offsetParent || modalContainer;
        const parentRect = positioningParent.getBoundingClientRect();
        const visibleElements = [
            modalContainer.querySelector('.slds-modal__header'),
            modalContainer.querySelector('.modal-content'),
            modalContainer.querySelector('.slds-modal__footer')
        ].filter(Boolean);

        const rects = visibleElements
            .map((element) => element.getBoundingClientRect())
            .filter((rect) => rect.width > 0 && rect.height > 0);

        if (!rects.length || parentRect.width <= 0 || parentRect.height <= 0) {
            return;
        }

        // Cover the actual Edit Products panel from header through footer.
        // Do not include .modal-close: it is positioned with a negative top
        // offset outside the panel and would pull the nested modal upward.
        const top = Math.min(...rects.map((rect) => rect.top));
        const bottom = Math.max(...rects.map((rect) => rect.bottom));
        const left = Math.min(...rects.map((rect) => rect.left));
        const right = Math.max(...rects.map((rect) => rect.right));

        const topOffset = top - parentRect.top - (positioningParent.clientTop || 0) +
            (positioningParent.scrollTop || 0);
        const leftOffset = left - parentRect.left - (positioningParent.clientLeft || 0) +
            (positioningParent.scrollLeft || 0);

        overlay.style.top = `${Math.max(0, topOffset)}px`;
        overlay.style.left = `${Math.max(0, leftOffset)}px`;
        overlay.style.width = `${Math.max(0, right - left)}px`;
        overlay.style.height = `${Math.max(0, bottom - top)}px`;
        overlay.style.right = 'auto';
        overlay.style.bottom = 'auto';
    }

    handleEditTableResize(width) {
        const measuredWidth = Math.floor(Number(width) || 0);
        if (
            measuredWidth <= 0 ||
            (measuredWidth === this.lastEditTableWidth && this.editColumnWidthsReady)
        ) {
            return;
        }

        this.lastEditTableWidth = measuredWidth;
        this.applyEditColumnWidths(measuredWidth);
    }

    disconnectedCallback() {
        if (this.refreshHandlerId) {
            unregisterRefreshHandler(this.refreshHandlerId);
        }
        this.editTableResizeObserver?.disconnect();
        this.editTableResizeObserver = null;
        this.editTableResizeTarget = null;
        this.availabilityOverlayResizeObserver?.disconnect();
        this.availabilityOverlayResizeObserver = null;
        this.availabilityOverlayResizeTarget = null;

        this.rowEditNavigationPending = false;
        this.rowEditPageOpened = false;
    }

    // Related list properties
    get header() {
        return this.vm?.header || 'Products';
    }

    get headerIcon() {
        return this.vm?.headerIcon || 'standard:product';
    }

    get rowCount() {
        return this.vm?.totalCount ?? this.rows.length;
    }

    get hasPricebook() {
        return Boolean(this.vm?.pricebookId);
    }

    get pricebookName() {
        return this.vm?.pricebookName || '';
    }

    get noRows() {
        return this.rows.length === 0;
    }

    get isAvailabilityButtonDisabled() {
        return this.busy || !(this.editRows || []).some((row) => row.productId);
    }

    // New Business mode is supplied by Apex from Order_Source_CC__c.
    get isRestrictedEditMode() {
        return this.vm?.isRestrictedEditMode === true;
    }

    get shouldShowAddProducts() {
        return this.hasPricebook && !this.isRestrictedEditMode && this.showAddProducts;
    }

    get shouldShowEditProducts() {
        return this.hasPricebook && (this.isRestrictedEditMode
            ? this.vm?.canEdit === true
            : this.showEditProducts);
    }

    get shouldShowChoosePricebook() {
        return !this.isRestrictedEditMode && this.showChoosePricebook;
    }

    // Keep the existing metadata setting, then narrow it for New Business Orders.
    isColumnEditable(column) {
        if (!column?.editable) {
            return false;
        }

        if (!this.isRestrictedEditMode) {
            return true;
        }

        return column.source === 'LINE_ITEM' &&
            NEW_BUSINESS_EDITABLE_FIELDS.has(column.apiName);
    }

    get enableProductInfiniteLoading() {
        return !this.showSelectedOnly && this.hasMoreProducts;
    }

    get isEditDisabled() {
        return !this.vm?.canEdit || this.noRows || this.busy;
    }

    get isPricebookDisabled() {
        return !this.vm?.canChangePricebook || this.busy;
    }

    get isAddDisabled() {
        return !this.vm?.canCreate || this.busy;
    }

    // Modal properties
    get showModal() {
        return Boolean(this.modal);
    }

    get isPricebook() {
        return this.modal === 'pricebook';
    }

    get isConfirm() {
        return this.modal === 'confirm';
    }

    get showProductScreen() {
        return this.modal === 'products';
    }

    get isEdit() {
        return this.modal === 'edit';
    }

    get isRowEdit() {
        return this.modal === 'rowEdit' && Boolean(this.rowEditRecordId);
    }


    get showBackToProducts() {
        return this.isEdit && this.isAddProductFlow;
    }

    get isDelete() {
        return this.modal === 'delete';
    }

    get modalTitle() {
        const titles = {
            pricebook: 'Choose Price Book',
            confirm: 'Confirm Price Book Change',
            products: 'Add Products',
            edit: 'Edit Selected Products',
            rowEdit: 'Edit Product'
            // FUTURE PHASE: siteAllocation: 'Manage Product Site Allocations'
        };

        return this.isDelete ? this.deleteTitle : titles[this.modal] || '';
    }

    get deleteTitle() {
        const labels = {
            Opportunity: 'Opportunity Product',
            Quote: 'Quote Line Item',
            Order: 'Order Product'
        };

        return `Delete ${labels[this.vm?.parentObjectApiName] || 'Product'}`;
    }

    get deleteMessage() {
        const labels = {
            Opportunity: 'opportunity product',
            Quote: 'quote line item',
            Order: 'order product'
        };

        const label = labels[this.vm?.parentObjectApiName] || 'product';

        return `Are you sure you want to delete this ${label}?`;
    }

    get parentRecordLabel() {
        const labels = {
            Opportunity: 'opportunity',
            Quote: 'quote',
            Order: 'order'
        };

        return labels[this.vm?.parentObjectApiName] || 'record';
    }

    get pricebookHelpText() {
        const parent = this.parentRecordLabel;

        return `Select a Price Book to associate with this ${parent}. ` +
            `You can add products only from the Price Book you associate ` +
            `with this ${parent}. Changing the Price Book deletes all ` +
            `products from the ${parent}.`;
    }

    get modalSectionClass() {
        return this.isPricebook || this.isConfirm || this.isDelete
            ? 'slds-modal slds-fade-in-open compact-modal'
            : 'slds-modal slds-fade-in-open slds-modal_large';
    }

    get modalContainerClass() {
        if (this.isPricebook || this.isConfirm) {
            return 'slds-modal__container compact-modal-container pricebook-modal-container';
        }

        if (this.isDelete) {
            return 'slds-modal__container compact-modal-container delete-modal-container';
        }

        return 'slds-modal__container standard-modal-container';
    }

    get modalContentClass() {
        if (this.isPricebook) {
            return 'slds-modal__content pricebook-modal-content';
        }

        if (this.isConfirm) {
            return 'slds-modal__content confirmation-content';
        }

        if (this.isDelete) {
            return 'slds-modal__content delete-modal-content';
        }

        return 'slds-modal__content slds-p-around_medium modal-content';
        // FUTURE PHASE: Restore the Site Allocation modal content class when that workflow is reactivated.
    }


    get selectedCount() {
        return this.selectedProducts.length;
    }

    get visibleProductRows() {
        const source = this.showSelectedOnly
            ? this.selectedProducts
            : this.productRows;

        return this.sortProductRows(source);
    }

    get selectedLabel() {
        return this.showSelectedOnly
            ? 'Show All'
            : `Show Selected (${this.selectedCount})`;
    }

    get selectedProductIds() {
        const visibleRows = this.showSelectedOnly ? this.selectedProducts : this.productRows;
        const visibleIds = new Set(visibleRows.map((product) => product.Id));
        return this.selectedProducts
            .filter((product) => visibleIds.has(product.Id))
            .map((product) => product.Id);
    }

    get noSelection() {
        return this.selectedProducts.length === 0;
    }

    // Load related list
    async refresh() {
        if (!this.recordId) {
            return;
        }

        this.busy = true;

        try {
            const initialData = await getInitialData({
                recordId: this.recordId
            });

            // FUTURE PHASE: When Site/Warehouse allocation is reactivated, use the metadata flag
            // to hide the Edit Products Quantity column and derive it from the Site allocations.
            // this.vm = {
            //     ...initialData,
            //     editColumns: initialData.showSitesWarehousesSelection
            //         ? (initialData.editColumns || []).filter((column) => !this.isQuantityColumn(column))
            //         : (initialData.editColumns || [])
            // };
            this.vm = initialData;

            // Prepare edit rows first so the related list can reuse the exact
            // percentage-point margin value already used by the Edit screen.
            this.editRows = this.prepareEditRows(initialData.editRows || []);
            this.rows = this.applyPreparedMarginsToRelatedRows(
                this.prepareDisplayRows(
                    this.vm.rows || [],
                    this.vm.relatedColumns || [],
                    true
                )
            );
            this.vm = { ...initialData, editRows: this.editRows };

            this.relatedColumns = (this.vm.relatedColumns || []).map(
                (column) => this.decorateColumn(column)
            );

            // View is available to users who can access the displayed records.
            const rowActions = [
                { label: 'View', name: 'view' }
            ];

            if (this.vm.canEdit) {
                rowActions.push({
                    label: 'Edit',
                    name: 'edit'
                });
            }

            if (this.vm.canDelete) {
                rowActions.push({
                    label: 'Delete',
                    name: 'delete'
                });
            }

            this.relatedColumns.push({
                type: 'action',
                typeAttributes: { rowActions }
            });

            this.editColumns = (this.vm.editColumns || []).map(
                (column) => this.decorateColumn(column, true)
            );


        } catch (error) {
            this.toast('Error', this.message(error), 'error');
        } finally {
            this.busy = false;
        }
    }

    // Pricebook selection
    async openChoosePricebook() {
        if (this.isRestrictedEditMode) {
            return;
        }
        this.afterPricebook = false;
        await this.openPricebook();
    }

    async openPricebook() {
        this.busy = true;

        try {
            this.pricebooks = await getPricebooks({
                recordId: this.recordId
            });

            this.selectedPricebookId = this.vm?.pricebookId || null;
            this.modal = 'pricebook';

        } catch (error) {
            this.toast('Error', this.message(error), 'error');
        } finally {
            this.busy = false;
        }
    }

    handlePricebookChange(event) {
        this.selectedPricebookId = event.detail.value;
    }

    async handlePricebookNext() {
        if (!this.selectedPricebookId) {
            this.toast(
                'Select a Price Book',
                'Choose a price book to continue.',
                'warning'
            );
            return;
        }

        const isChangingPricebook =
            this.hasPricebook &&
            this.selectedPricebookId !== this.vm.pricebookId;

        if (isChangingPricebook) {
            this.modal = 'confirm';
            return;
        }

        await this.applyPricebook();
    }

    async handleConfirmPricebook() {
        await this.applyPricebook();
    }

    async applyPricebook() {
        this.busy = true;

        try {
            await changePricebook({
                recordId: this.recordId,
                pricebookId: this.selectedPricebookId
            });

            await this.refresh();
            this.modal = null;

            if (this.afterPricebook) {
                this.afterPricebook = false;
                await this.openProducts();
            } else {
                this.toast(
                    'Success',
                    'Price Book updated.',
                    'success'
                );
            }

        } catch (error) {
            this.toast('Error', this.message(error), 'error');
        } finally {
            this.busy = false;
        }
    }

    // Add products
    async openAdd() {
        if (this.isRestrictedEditMode) {
            return;
        }
        this.isAddProductFlow = true;

        if (!this.hasPricebook) {
            this.afterPricebook = true;
            await this.openPricebook();
            return;
        }

        await this.openProducts();
    }

    async openProducts() {
        this.clearSearchTimeout();
        this.modal = 'products';
        this.searchTerm = '';
        this.loadedProductSearchTerm = '';
        this.showSelectedOnly = false;
        this.selectedProducts = [];
        this.editRows = [];
        this.productRows = [];
        this.productColumns = [];
        this.nextProductCursorName = null;
        this.nextProductCursorEntryId = null;
        this.hasMoreProducts = false;
        this.loadingMoreProducts = false;
        this.sortedBy = undefined;
        this.sortDirection = 'asc';

        // FUTURE PHASE: Reset retained Site/Warehouse allocation state when that workflow is reactivated.
        // this.siteAllocationProducts = [];
        // this.siteAllocationSignature = '';

        await this.loadProducts();
    }

    // Search Products with a 500ms debounce. Selection is retained across searches.
    handleSearch(event) {
        this.searchTerm = event.detail.value || '';
        this.clearSearchTimeout();

        const searchTerm = this.searchTerm;
        this.searchTimeout = setTimeout(async () => {
            this.searchTimeout = null;
            if (this.modal !== 'products' || this.searchTerm !== searchTerm) {
                return;
            }

            const needsFullResultSet = Boolean(this.sortedBy) && !this.showSelectedOnly;
            const loaded = await this.loadProducts({ loadAll: needsFullResultSet });
            if (!loaded && needsFullResultSet) {
                this.sortedBy = undefined;
                this.sortDirection = 'asc';
            }
        }, 500);
    }

    clearSearchTimeout() {
        if (this.searchTimeout) {
            clearTimeout(this.searchTimeout);
            this.searchTimeout = null;
        }
    }

    // Load the first batch, append the next batch, or retrieve all matches when sorting.
    async loadProducts({ append = false, loadAll = false } = {}) {
        if (append && (
            this.loadingMoreProducts ||
            !this.hasMoreProducts ||
            this.searchTimeout ||
            this.loadedProductSearchTerm !== this.searchTerm
        )) {
            return false;
        }

        const requestId = append ? this.productRequestId : ++this.productRequestId;
        const searchTerm = this.searchTerm;
        const previousPage = {
            rows: this.productRows,
            columns: this.productColumns,
            hasMore: this.hasMoreProducts,
            cursorName: this.nextProductCursorName,
            cursorEntryId: this.nextProductCursorEntryId,
            loadedSearchTerm: this.loadedProductSearchTerm
        };
        const pageSize = loadAll ? 200 : 30;
        let cursorName = append ? this.nextProductCursorName : null;
        let cursorEntryId = append ? this.nextProductCursorEntryId : null;
        let isFirstPage = !append;

        if (append) {
            this.loadingMoreProducts = true;
        } else {
            this.busy = true;
            this.loadingMoreProducts = false;
        }

        try {
            do {
                const result = await getProducts({
                    recordId: this.recordId,
                    searchTerm,
                    cursorName,
                    cursorEntryId,
                    pageSize
                });

                // Ignore responses from an earlier search or a screen the user has left.
                if (
                    requestId !== this.productRequestId ||
                    this.modal !== 'products' ||
                    searchTerm !== this.searchTerm
                ) {
                    if (requestId === this.productRequestId) {
                        this.productRows = previousPage.rows;
                        this.productColumns = previousPage.columns;
                        this.hasMoreProducts = previousPage.hasMore;
                        this.nextProductCursorName = previousPage.cursorName;
                        this.nextProductCursorEntryId = previousPage.cursorEntryId;
                        this.loadedProductSearchTerm = previousPage.loadedSearchTerm;
                    }
                    return false;
                }

                if (isFirstPage) {
                    this.productRows = [];
                    this.hasMoreProducts = false;
                    this.nextProductCursorName = null;
                    this.nextProductCursorEntryId = null;
                    this.loadedProductSearchTerm = searchTerm;
                    this.productColumns = (result.columns || []).map((column) => ({
                        ...this.decorateColumn(column),
                        sortable: true
                    }));
                }

                const nextRows = this.prepareDisplayRows(
                    result.rows || [],
                    this.productColumns
                );
                this.productRows = [...this.productRows, ...nextRows];

                this.hasMoreProducts = result.hasMore === true;
                this.nextProductCursorName = result.nextCursorName || null;
                this.nextProductCursorEntryId = result.nextCursorEntryId || null;
                isFirstPage = false;

                if (!loadAll || !this.hasMoreProducts) {
                    break;
                }

                cursorName = this.nextProductCursorName;
                cursorEntryId = this.nextProductCursorEntryId;
            } while (this.hasMoreProducts);

            return true;
        } catch (error) {
            if (requestId === this.productRequestId) {
                this.productRows = previousPage.rows;
                this.productColumns = previousPage.columns;
                this.hasMoreProducts = previousPage.hasMore;
                this.nextProductCursorName = previousPage.cursorName;
                this.nextProductCursorEntryId = previousPage.cursorEntryId;
                this.loadedProductSearchTerm = previousPage.loadedSearchTerm;
                if (this.searchTerm === searchTerm) {
                    this.searchTerm = previousPage.loadedSearchTerm;
                }
                this.toast('Error', this.message(error), 'error');
            }
            return false;
        } finally {
            if (requestId === this.productRequestId) {
                this.busy = false;
                this.loadingMoreProducts = false;
            }
        }
    }

    // Called by lightning-datatable when the user reaches the end of loaded rows.
    async loadMoreProducts() {
        await this.loadProducts({ append: true, loadAll: Boolean(this.sortedBy) });
    }

    // Sorting is global: fetch all matching pages before sorting the complete result set.
    async handleProductSort(event) {
        this.clearSearchTimeout();
        const previousState = {
            sortedBy: this.sortedBy,
            sortDirection: this.sortDirection,
            rows: this.productRows,
            hasMore: this.hasMoreProducts,
            cursorName: this.nextProductCursorName,
            cursorEntryId: this.nextProductCursorEntryId,
            searchTerm: this.loadedProductSearchTerm
        };
        this.sortedBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;

        if (
            !this.showSelectedOnly &&
            (this.hasMoreProducts || this.searchTerm !== this.loadedProductSearchTerm)
        ) {
            const loaded = await this.loadProducts({ loadAll: true });
            if (!loaded) {
                this.sortedBy = previousState.sortedBy;
                this.sortDirection = previousState.sortDirection;
                this.productRows = previousState.rows;
                this.hasMoreProducts = previousState.hasMore;
                this.nextProductCursorName = previousState.cursorName;
                this.nextProductCursorEntryId = previousState.cursorEntryId;
                this.loadedProductSearchTerm = previousState.searchTerm;
                this.searchTerm = previousState.searchTerm;
            }
        }
    }

    sortProductRows(sourceRows) {
        if (!this.sortedBy) {
            return sourceRows;
        }

        const column = this.productColumns.find((item) => item.fieldName === this.sortedBy);
        const isLandingCost = column && this.isLandingCostColumn(column);
        const sortField = isLandingCost
            ? 'landingCost'
            : column?.type === 'url'
                ? column.typeAttributes?.label?.fieldName || this.sortedBy
                : this.sortedBy;
        const isNumeric = isLandingCost ||
            ['number', 'currency', 'percent', 'marginPercent'].includes(column?.type);
        const isDate = ['date', 'date-local'].includes(column?.type);
        const direction = this.sortDirection === 'asc' ? 1 : -1;

        return [...sourceRows].sort((first, second) => {
            const firstValue = first[sortField];
            const secondValue = second[sortField];

            if (firstValue == null) return 1;
            if (secondValue == null) return -1;

            const comparison = isNumeric
                ? Number(firstValue) - Number(secondValue)
                : isDate
                    ? new Date(firstValue).getTime() - new Date(secondValue).getTime()
                    : String(firstValue).localeCompare(
                        String(secondValue),
                        undefined,
                        { numeric: true, sensitivity: 'base' }
                    );

            return comparison * direction;
        });
    }

    // Manually refresh the related list.
    async handleRefresh() {
        await this.refresh();
    }

    // Identify the calculated margin column in either column configuration.
    // The related-list metadata may omit source='CALCULATED', so use the
    // matching field from editColumns as a reliable fallback.
    getConfiguredMarginColumn() {
        return (this.vm?.editColumns || []).find((column) =>
            String(column.source || '').trim().toUpperCase() === 'CALCULATED' &&
            ['percent', 'percentage'].includes(String(column.type || '').trim().toLowerCase())
        ) || null;
    }

    getConfiguredMarginApiName() {
        return this.getConfiguredMarginColumn()?.apiName || null;
    }

    // Keep the related-list margin in sync with the already-prepared Edit value.
    // Both screens represent the same line item, but may use different generated field names.
    applyPreparedMarginsToRelatedRows(rows) {
        const editMarginColumn = this.getConfiguredMarginColumn();
        if (!editMarginColumn || !rows.length || !this.editRows?.length) {
            return rows;
        }

        const relatedMarginColumn = (this.vm?.relatedColumns || []).find((column) =>
            this.isMarginColumn(column, editMarginColumn.apiName)
        );
        if (!relatedMarginColumn) {
            return rows;
        }

        const marginByLineItemId = new Map(
            this.editRows.map((row) => [
                row.lineItemId || row.Id,
                row[editMarginColumn.fieldName]
            ])
        );

        return rows.map((row) => {
            const lineItemId = row.lineItemId || row.Id;
            if (!marginByLineItemId.has(lineItemId)) {
                return row;
            }

            const marginValue = marginByLineItemId.get(lineItemId);
            const hasMarginValue = marginValue !== null &&
                marginValue !== undefined &&
                marginValue !== '' &&
                Number.isFinite(Number(marginValue));

            return {
                ...row,
                [relatedMarginColumn.fieldName]: marginValue,
                marginCellClass: hasMarginValue && Number(marginValue) < 0
                    ? 'slds-text-color_error slds-text-title_bold'
                    : ''
            };
        });
    }

    isMarginColumn(config, marginApiName = this.getConfiguredMarginApiName()) {
        const columnType = String(config?.type || '').trim().toLowerCase();
        const isPercentage = ['percent', 'percentage', 'marginpercent'].includes(columnType);
        const isCalculated = String(config?.source || '').trim().toUpperCase() === 'CALCULATED';
        const configuredMargin = this.getConfiguredMarginColumn();
        const sameApiName = marginApiName && config?.apiName &&
            String(config.apiName).trim().toLowerCase() === String(marginApiName).trim().toLowerCase();
        const sameLabel = configuredMargin?.label && config?.label &&
            String(config.label).trim().toLowerCase() === String(configuredMargin.label).trim().toLowerCase();

        // Match the configured margin across screens; fieldName values are generated separately.
        return isPercentage && (isCalculated || sameApiName || sameLabel);
    }

    // Dynamic columns
    decorateColumn(config, useMarginEditor = false) {
        const configuredType = String(config.type || 'text').toLowerCase();
        const columnType = configuredType === 'percentage'
                        ? 'percent'
                        : configuredType;
        // Salesforce Date fields must use date-local; date renders date and time.
        const renderedColumnType = useMarginEditor && columnType === 'date'
            ? 'date-local'
            : columnType;
        const isMarginColumn = this.isMarginColumn(config);
        const isMargin = isMarginColumn;
        const isLandingCost = this.isLandingCostColumn(config);

        const isLookup =
            useMarginEditor &&
            config.source === 'LINE_ITEM' &&
            columnType === 'lookup';
        const isPicklist =
            useMarginEditor &&
            config.source === 'LINE_ITEM' &&
            columnType === 'picklist';

        const column = {
            label: config.label,
            fieldName: config.fieldName,
            type: isMargin ? 'marginPercent' : isLandingCost ? 'text' : isLookup ? 'lookup' : isPicklist ? 'picklist' : renderedColumnType,
            editable: isLandingCost ? false : this.isColumnEditable(config),
            required: config.required,
            apiName: config.apiName,
            labelFieldName: config.labelFieldName,
            widthPercent: config.widthPercent,
            hideDefaultActions: true
        };

        if (['number', 'currency', 'percent'].includes(columnType)) {
            column.cellAttributes = {
                alignment: 'left'
            };

            if (isMarginColumn) {
                column.cellAttributes.class = {
                    fieldName: 'marginCellClass'
                };
            }
        }

        if (columnType === 'number') {
            column.typeAttributes = {
                minimumFractionDigits: 2,
                maximumFractionDigits: 2
            };
        }

        if (columnType === 'currency') {
            column.typeAttributes = {
                currencyCode: { fieldName: 'currencyIsoCode' },
                currencyDisplayAs: 'code',
                minimumFractionDigits: 2,
                maximumFractionDigits: 2
            };
        }

        if (isLookup) {
            column.typeAttributes = {
                objectApiName: config.lookupObjectApiName,
                recordLabel: { fieldName: config.labelFieldName },
                recordUrl: { fieldName: config.urlFieldName },
                placeholder: `Search ${config.label}...`,
                rowId: { fieldName: 'Id' },
                fieldName: config.fieldName
            };
        }

        if (isPicklist) {
            column.typeAttributes = {
                options: config.picklistOptions || [],
                placeholder: `Select ${config.label}...`,
                displayLabel: { fieldName: config.labelFieldName }
            };
        }

        if (isMargin) {
            column.typeAttributes = {
                minimumFractionDigits: 2,
                maximumFractionDigits: 2,
                min: null,
                max: 99.99,
                step: 0.01,
                textClass: { fieldName: 'marginCellClass' }
            };
        }

        if (columnType === 'percent' && !isMargin) {
            column.typeAttributes = {
                minimumFractionDigits: 2,
                maximumFractionDigits: 2
            };
        }

        if (columnType === 'url') {
            column.typeAttributes = {
                label: { fieldName: config.labelFieldName },
                target: '_self'
            };
        }

        return column;
    }

    // Prepare display values in one pass; only the related list converts percent fractions.
    prepareDisplayRows(rows, columns, convertPercentages = false) {
        const marginApiName = this.getConfiguredMarginApiName();
        const sourceColumns = columns || [];
        const percentageColumns = convertPercentages
            ? sourceColumns.filter((column) =>
                ['percent', 'percentage'].includes(String(column.type || '').toLowerCase())
            )
            : [];
        const marginColumns = sourceColumns.filter((column) =>
            this.isMarginColumn(column, marginApiName)
        );
        const landingCostColumns = sourceColumns.filter((column) =>
            this.isLandingCostColumn(column)
        );

        if (!percentageColumns.length && !marginColumns.length && !landingCostColumns.length) {
            return rows;
        }

        return rows.map((row) => {
            const updatedRow = { ...row };
            const formattedMarginFields = new Set();

            percentageColumns.forEach((column) => {
                const value = updatedRow[column.fieldName];
                const isMargin = this.isMarginColumn(column, marginApiName);

                if (value !== null && value !== undefined && value !== '') {
                    // Custom margin cells use percentage points; standard percent cells use fractions.
                    updatedRow[column.fieldName] = isMargin
                        ? Number(value) * 100
                        : Number(value) / 100;
                }

                if (isMargin) {
                    formattedMarginFields.add(column.fieldName);
                    updatedRow.marginCellClass = Number(updatedRow[column.fieldName]) < 0
                        ? 'slds-text-color_error slds-text-title_bold'
                        : '';
                }
            });

            // Add Products uses the standard percent formatter for other percent columns.
            // Convert only its custom margin cells into the percentage points they display.
            marginColumns.forEach((column) => {
                if (formattedMarginFields.has(column.fieldName)) {
                    return;
                }
                const value = updatedRow[column.fieldName];
                if (value !== null && value !== undefined && value !== '') {
                    updatedRow[column.fieldName] = Number(value) * 100;
                }
                updatedRow.marginCellClass = Number(updatedRow[column.fieldName]) < 0
                    ? 'slds-text-color_error slds-text-title_bold'
                    : '';
            });

            landingCostColumns.forEach((column) => {
                updatedRow[column.fieldName] = this.formatLandingCost(
                    row,
                    row[column.fieldName]
                );
            });

            // Set the shared cell class after all column transformations so a second
            // calculated percentage column cannot accidentally clear the margin style.
            const marginColumn = marginColumns[0] || percentageColumns.find((column) =>
                this.isMarginColumn(column, marginApiName)
            );
            if (marginColumn) {
                const marginValue = updatedRow[marginColumn.fieldName];
                updatedRow.marginCellClass = Number(marginValue) < 0
                    ? 'slds-text-color_error slds-text-title_bold'
                    : '';
            }

            return updatedRow;
        });
    }

    // Identify the configured Product Estimated Landing Price column.
    isLandingCostColumn(column) {
        const fieldName = this.vm?.landingCostFieldApiName;

        if (!fieldName || !column?.apiName) {
            return false;
        }

        return [
            fieldName,
            `Product2.${fieldName}`,
            `PricebookEntry.Product2.${fieldName}`
        ].includes(column.apiName);
    }

    // Format the Product currency and the user's converted currency together.
    formatLandingCost(row, fallbackValue) {
        const amount = row.landingCost ?? fallbackValue;
        if (amount === null || amount === undefined || amount === '') {
            return '';
        }

        const formattedAmount = AMOUNT_FORMATTER.format(Number(amount));
        const productCurrency = row.landingCostCurrencyIsoCode;
        const primaryValue = productCurrency
            ? `${productCurrency} ${formattedAmount}`
            : formattedAmount;

        const convertedAmount = row.convertedLandingCost;
        const convertedCurrency = row.convertedCurrencyIsoCode;

        if (
            convertedAmount === null ||
            convertedAmount === undefined ||
            !convertedCurrency ||
            convertedCurrency === productCurrency
        ) {
            return primaryValue;
        }

        return `${primaryValue} (${convertedCurrency} ${AMOUNT_FORMATTER.format(Number(convertedAmount))})`;
    }

    // Return a common currency basis for margin calculations.
    getMarginCurrencyValues(row) {
        if (row.landingCost === null || row.landingCost === undefined || row.landingCost === '') {
            return null;
        }

        const rawLandingCost = Number(row.landingCost);
        const convertedLandingCost = row.convertedLandingCost == null
            ? null
            : Number(row.convertedLandingCost);

        let exchangeRate = 1;

        if (
            row.unitPrice != null &&
            row.convertedUnitPrice != null &&
            Number(row.unitPrice) !== 0
        ) {
            exchangeRate = Number(row.convertedUnitPrice) / Number(row.unitPrice);
        } else if (
            row.currencyIsoCode &&
            row.convertedCurrencyIsoCode &&
            row.currencyIsoCode !== row.convertedCurrencyIsoCode
        ) {
            return null;
        }

        let landingCostInUserCurrency = convertedLandingCost;

        if (landingCostInUserCurrency == null) {
            if (
                row.convertedCurrencyIsoCode &&
                row.landingCostCurrencyIsoCode &&
                row.convertedCurrencyIsoCode !== row.landingCostCurrencyIsoCode
            ) {
                return null;
            }

            landingCostInUserCurrency = rawLandingCost;
        }

        if (
            !Number.isFinite(landingCostInUserCurrency) ||
            !Number.isFinite(exchangeRate) ||
            exchangeRate <= 0
        ) {
            return null;
        }

        return {
            landingCost: landingCostInUserCurrency,
            exchangeRate
        };
    }


    // Resolve a picklist option by its API value (never by its display label).
    getPicklistOption(column, value) {
        if (value === null || value === undefined || value === '') {
            return null;
        }

        return (column.picklistOptions || []).find(
            (item) => String(item.value) === String(value)
        ) || null;
    }

    // Resolve the user-facing label for a configured picklist value.
    getPicklistLabel(column, value) {
        if (value === null || value === undefined || value === '') {
            return '';
        }

        return this.getPicklistOption(column, value)?.label || String(value);
    }

    // Prepare edit rows once: defaults, display formatting and negative-margin styling.
    prepareEditRows(rows, cloneRows = true, marginValuesArePercentagePoints = false) {
        const columns = this.vm?.editColumns || [];
        const marginColumn = columns.find((column) =>
            column.source === 'CALCULATED' &&
            ['percent', 'percentage'].includes(String(column.type || '').toLowerCase())
        );
        const landingCostColumns = columns.filter((column) =>
            this.isLandingCostColumn(column)
        );

        return rows.map((row) => {
            const updatedRow = cloneRows ? { ...row } : row;

            columns.forEach((column) => {
                const isDefaultableLookup =
                    column.source === 'LINE_ITEM' &&
                    this.isColumnEditable(column) &&
                    String(column.type || '').toLowerCase() === 'lookup' &&
                    column.defaultValue !== null &&
                    column.defaultValue !== undefined;

                if (isDefaultableLookup) {
                    const currentValue = updatedRow[column.fieldName];
                    if (currentValue === null || currentValue === undefined || currentValue === '') {
                        updatedRow[column.fieldName] = column.defaultValue;
                        updatedRow[column.labelFieldName] = column.defaultLabel;
                        updatedRow[column.urlFieldName] = `/${column.defaultValue}`;
                    }
                }

                const isDefaultablePicklist =
                    column.source === 'LINE_ITEM' &&
                    this.isColumnEditable(column) &&
                    String(column.type || '').toLowerCase() === 'picklist' &&
                    column.defaultValue !== null &&
                    column.defaultValue !== undefined &&
                    column.defaultValue !== '';

                if (isDefaultablePicklist) {
                    const currentValue = updatedRow[column.fieldName];
                    if (currentValue === null || currentValue === undefined || currentValue === '') {
                        const defaultOption = this.getPicklistOption(column, column.defaultValue);
                        // Only default when the parent field value exactly matches an API value.
                        if (defaultOption) {
                            updatedRow[column.fieldName] = defaultOption.value;
                        }
                    }
                }

                const isDefaultableDate =
                    column.source === 'LINE_ITEM' &&
                    this.isColumnEditable(column) &&
                    ['date', 'date-local'].includes(String(column.type || '').toLowerCase()) &&
                    column.defaultValue !== null &&
                    column.defaultValue !== undefined &&
                    column.defaultValue !== '';

                if (isDefaultableDate) {
                    const currentValue = updatedRow[column.fieldName];
                    if (currentValue === null || currentValue === undefined || currentValue === '') {
                        updatedRow[column.fieldName] = column.defaultValue;
                    }
                }

                if (
                    column.source === 'LINE_ITEM' &&
                    String(column.type || '').toLowerCase() === 'picklist' &&
                    column.labelFieldName
                ) {
                    updatedRow[column.labelFieldName] = this.getPicklistLabel(
                        column,
                        updatedRow[column.fieldName]
                    );
                }
            });

            if (marginColumn) {
                const marginValue = updatedRow[marginColumn.fieldName];
                updatedRow[marginColumn.fieldName] = marginValue == null
                    ? null
                    : Number((marginValuesArePercentagePoints
                        ? Number(marginValue)
                        : Number(marginValue) * 100
                    ).toFixed(2));
                updatedRow.marginCellClass = Number(updatedRow[marginColumn.fieldName]) < 0
                    ? 'slds-text-color_error slds-text-title_bold'
                    : '';
            }

            landingCostColumns.forEach((column) => {
                updatedRow[column.fieldName] = this.formatLandingCost(
                    row,
                    row[column.fieldName]
                );
            });

            return updatedRow;
        });
    }

    // Apply metadata percentages as real widths. Totals above 100% intentionally
    // make the table wider than its viewport so users can scroll to later columns.
    applyEditColumnWidths(tableWidth) {
        if (!this.isEdit || !Array.isArray(this.editColumns) || !this.editColumns.length || tableWidth <= 0) {
            return;
        }

        const columns = this.editColumns;
        const deleteColumn = columns.find((column) =>
            column.type === 'button-icon' && column.label === 'Delete'
        );
        const dataColumns = columns.filter((column) => column !== deleteColumn);
        const rowNumberGutter = 50;
        const baseWidth = Math.max(1, Math.floor(tableWidth - rowNumberGutter));
        const minimumWidth = 35;
        const deleteWidthPercent = 6;
        const pixelWidths = new Map();
        const configuredWidths = new Map();
        let configuredTotal = 0;
        const missingColumns = [];

        dataColumns.forEach((column) => {
            const rawWidth = column.widthPercent;
            const widthPercent = rawWidth === null || rawWidth === undefined || String(rawWidth).trim() === ''
                ? NaN
                : Number(rawWidth);

            if (Number.isFinite(widthPercent) && widthPercent > 0) {
                configuredWidths.set(column, widthPercent);
                configuredTotal += widthPercent;
            } else {
                missingColumns.push(column);
            }
        });

        const hasUserWidths = Array.isArray(this.editColumnResizeRatios) &&
            this.editColumnResizeRatios.length === columns.length &&
            this.editColumnResizeRatios.every((width) => Number.isFinite(Number(width)) && Number(width) > 0);

        if (hasUserWidths) {
            // Store resize values as percentages of the viewport, not normalized
            // to 100%, so a user-sized wide table remains horizontally scrollable.
            columns.forEach((column, index) => {
                pixelWidths.set(
                    column,
                    Math.max(minimumWidth, Math.round(baseWidth * Number(this.editColumnResizeRatios[index]) / 100))
                );
            });
        } else if (configuredTotal >= 100) {
            // Width (%) now represents a percentage of the visible table viewport.
            // For example, 124% of configured data columns creates genuine overflow.
            dataColumns.forEach((column) => {
                const widthPercent = configuredWidths.has(column)
                    ? configuredWidths.get(column)
                    : 10; // Sensible default for a newly added column with no Width (%) value.
                pixelWidths.set(
                    column,
                    Math.max(minimumWidth, Math.round(baseWidth * widthPercent / 100))
                );
            });

            if (deleteColumn) {
                pixelWidths.set(
                    deleteColumn,
                    Math.max(50, Math.round(baseWidth * deleteWidthPercent / 100))
                );
            }
        } else {
            // When configured widths leave room, use the remaining space for
            // unconfigured columns and the generated Delete column as before.
            const weights = new Map(configuredWidths);
            const remainingSlots = missingColumns.length + (deleteColumn ? 1 : 0);

            if (remainingSlots > 0) {
                const remainingShare = Math.max(0, 100 - configuredTotal) / remainingSlots;
                missingColumns.forEach((column) => weights.set(column, remainingShare));
                if (deleteColumn) {
                    weights.set(deleteColumn, remainingShare);
                }
            } else if (!deleteColumn && configuredTotal > 0) {
                dataColumns.forEach((column) => {
                    weights.set(column, configuredWidths.get(column) * 100 / configuredTotal);
                });
            } else if (deleteColumn) {
                weights.set(deleteColumn, Math.max(0, 100 - configuredTotal));
            }

            if (configuredTotal === 0 && !remainingSlots) {
                columns.forEach((column) => weights.set(column, 100 / columns.length));
            }

            const totalWeight = columns.reduce(
                (total, column) => total + (weights.get(column) || 0),
                0
            ) || columns.length;

            columns.forEach((column) => {
                const weight = weights.get(column) || 1;
                pixelWidths.set(
                    column,
                    Math.max(minimumWidth, Math.round(baseWidth * weight / totalWeight))
                );
            });
        }

        this.editColumns = columns.map((column) => {
            const { initialWidth, fixedWidth, ...definition } = column;
            return {
                ...definition,
                initialWidth: pixelWidths.get(column) || minimumWidth
            };
        });

        // Keep the datatable host at the modal viewport width. The datatable's
        // native horizontal scroller handles columns whose combined widths exceed it.
        this.editTableHostStyle = 'width: 100%; min-width: 100%; max-width: 100%;';
        this.editColumnWidthsReady = true;
    }

    // Persist user-resized widths as viewport-relative ratios without forcing
    // the total table width back down to the visible container width.
    handleEditColumnResize(event) {
        const detail = event.detail || {};
        if (!detail.isUserTriggered) {
            return;
        }

        const reportedWidths = detail.columnWidths;
        let widths = Array.isArray(reportedWidths)
            ? reportedWidths.map(Number)
            : reportedWidths && typeof reportedWidths === 'object'
                ? Object.values(reportedWidths).map(Number)
                : [];

        if (widths.length === this.editColumns.length + 1) {
            widths = widths.slice(1);
        }

        if (
            widths.length !== this.editColumns.length ||
            widths.some((width) => !Number.isFinite(width) || width <= 0)
        ) {
            return;
        }

        const containerWidth = this.editTableResizeTarget?.getBoundingClientRect().width || this.lastEditTableWidth;
        const baseWidth = Math.max(1, Math.floor(containerWidth - 50));
        this.editColumnResizeRatios = widths.map((width) => width / baseWidth * 100);
        this.applyEditColumnWidths(containerWidth);
    }

    // Delete icon column
    getRemoveActionColumn() {
        return {
            label: 'Delete',
            fieldName: 'Id',
            type: 'button-icon',
            hideDefaultActions: true,
            cellAttributes: {
                alignment: 'left'
            },
            typeAttributes: {
                iconName: 'utility:delete',
                name: 'remove',
                title: this.isRestrictedEditMode
                    ? 'Deletion is disabled for New Business orders'
                    : 'Delete Product',
                alternativeText: 'Delete Product',
                disabled: this.isRestrictedEditMode,
                variant: 'border',
                iconClass: 'slds-icon-text-error'
            }
        };
    }

    // Product selection
    handleSelection(event) {
        const visibleRows = this.showSelectedOnly ? this.selectedProducts : this.productRows;
        const visibleIds = new Set(visibleRows.map((product) => product.Id));

        this.selectedProducts = [
            ...this.selectedProducts.filter(
                (product) => !visibleIds.has(product.Id)
            ),
            ...event.detail.selectedRows
        ];
    }

    async toggleSelected() {
        this.showSelectedOnly = !this.showSelectedOnly;

        // A sort shown on the full product list must cover every matching record.
        if (
            !this.showSelectedOnly &&
            this.sortedBy &&
            (this.hasMoreProducts || this.searchTerm !== this.loadedProductSearchTerm)
        ) {
            this.clearSearchTimeout();
            const previousPage = {
                rows: this.productRows,
                hasMore: this.hasMoreProducts,
                cursorName: this.nextProductCursorName,
                cursorEntryId: this.nextProductCursorEntryId,
                searchTerm: this.loadedProductSearchTerm
            };
            const loaded = await this.loadProducts({ loadAll: true });

            if (!loaded) {
                this.productRows = previousPage.rows;
                this.hasMoreProducts = previousPage.hasMore;
                this.nextProductCursorName = previousPage.cursorName;
                this.nextProductCursorEntryId = previousPage.cursorEntryId;
                this.loadedProductSearchTerm = previousPage.searchTerm;
                this.searchTerm = previousPage.searchTerm;
            }
        }
    }

    handleProductNext() {
        if (this.isRestrictedEditMode || this.noSelection || this.busy) {
            return;
        }

        this.isAddProductFlow = true;

        const previousEditRows = new Map(
            (this.editRows || []).map((row) => [row.Id, row])
        );
        const editMarginColumn = (this.vm.editColumns || []).find((column) =>
            String(column.source || '').toUpperCase() === 'CALCULATED' &&
            ['percent', 'percentage'].includes(String(column.type || '').toLowerCase())
        );
        const addProductMarginColumn = editMarginColumn
            ? this.productColumns.find((column) =>
                column.apiName === editMarginColumn.apiName && this.isMarginColumn(column)
            ) || this.productColumns.find((column) => this.isMarginColumn(column))
            : this.productColumns.find((column) => this.isMarginColumn(column));
        const rows = this.selectedProducts.map((product) => {
            const existingRow = previousEditRows.get(product.Id);
            if (existingRow) {
                return { ...existingRow };
            }

            const row = {
                Id: product.Id,
                lineItemId: null,
                pricebookEntryId: product.pricebookEntryId,
                productId: product.productId,
                productName: product.productName,
                currencyIsoCode: product.currencyIsoCode,
                unitPrice: product.unitPrice ?? product.listPrice,
                convertedUnitPrice: product.convertedUnitPrice,
                landingCost: product.landingCost,
                landingCostCurrencyIsoCode: product.landingCostCurrencyIsoCode,
                convertedLandingCost: product.convertedLandingCost,
                convertedCurrencyIsoCode: product.convertedCurrencyIsoCode
            };

            (this.vm.editColumns || []).forEach((column) => {
                if (this.isLandingCostColumn(column)) {
                    row[column.fieldName] = product.landingCost;
                    return;
                }

                if (column.source === 'CALCULATED') {
                    // Add Products has already converted the displayed margin to percentage points.
                    // Reuse that value so the Edit screen does not convert it a second time.
                    const displayMargin = addProductMarginColumn
                        ? product[addProductMarginColumn.fieldName]
                        : null;
                    const marginValue = displayMargin ?? product.margin;
                    row[column.fieldName] = marginValue == null
                        ? null
                        : Number(displayMargin == null ? marginValue * 100 : marginValue);
                    return;
                }

                if (column.source !== 'LINE_ITEM') {
                    return;
                }

                if (column.apiName === 'Quantity') {
                    row[column.fieldName] = 1;
                } else if (column.apiName === 'UnitPrice') {
                    row[column.fieldName] = product.listPrice;
                } else if (String(column.type || '').toLowerCase() === 'url') {
                    const productColumn = this.productColumns.find(
                        (item) => item.apiName === column.apiName
                    );
                    const productLabel = productColumn
                        ? productColumn.labelFieldName
                            ? product[productColumn.labelFieldName]
                            : product[productColumn.fieldName]
                        : null;

                    if (column.labelFieldName) {
                        row[column.labelFieldName] = productLabel ?? product.productName;
                    }

                    row[column.fieldName] = productColumn &&
                        String(productColumn.type || '').toLowerCase() === 'url'
                            ? product[productColumn.fieldName]
                            : '/' + product.productId;
                }
            });

            return row;
        });

        // These rows are already in percentage points, so skip margin conversion here.
        this.editRows = this.prepareEditRows(rows, false, true);

        this.editColumns = (this.vm.editColumns || []).map(
            (column) => this.decorateColumn(column, true)
        );

        this.editColumns.push(this.getRemoveActionColumn());

        this.drafts = [];
        this.removedIds = [];
        this.editColumnResizeRatios = null;
        this.editColumnWidthsReady = false;
        this.editTableHostStyle = 'width: 100%; min-width: 100%;';
        this.lastEditTableWidth = 0;
        this.modal = 'edit';
    }


    // Return to Add Products without losing the current product selection.
    async handleEditBack() {
        if (!this.isAddProductFlow || this.busy) {
            return;
        }

        this.clearSearchTimeout();
        this.modal = 'products';
        this.drafts = [];

        // The product list remains in memory. Reload only when a search was still debouncing.
        if (this.searchTerm !== this.loadedProductSearchTerm) {
            await this.loadProducts({
                loadAll: Boolean(this.sortedBy) && !this.showSelectedOnly
            });
        }
    }

    // Edit existing products
    openEdit() {
        if (this.isEditDisabled) {
            return;
        }

        this.isAddProductFlow = false;

        this.editRows = (this.vm.editRows || []).map((row) => ({ ...row }));

        this.editColumns = (this.vm.editColumns || []).map(
            (column) => this.decorateColumn(column, true)
        );

        if (this.vm.canDelete || this.isRestrictedEditMode) {
            this.editColumns.push(this.getRemoveActionColumn());
        }

        this.drafts = [];
        this.removedIds = [];
        this.editColumnResizeRatios = null;
        this.editColumnWidthsReady = false;
        this.editTableHostStyle = 'width: 100%; min-width: 100%;';
        this.lastEditTableWidth = 0;
        this.modal = 'edit';
    }

    // Bidirectional Sales Price and Margin calculation
    handleCellChange(event) {
        const changedDrafts = event.detail.draftValues || [];

        const priceColumn = (this.vm.editColumns || []).find(
            (column) =>
                column.source === 'LINE_ITEM' &&
                column.apiName === 'UnitPrice'
        );

        const marginColumn = (this.vm.editColumns || []).find(
            (column) =>
                column.source === 'CALCULATED' &&
                column.type === 'percent'
        );

        const draftMap = new Map(
            this.drafts.map((draft) => [draft.Id, { ...draft }])
        );

        changedDrafts.forEach((changedDraft) => {
            const previousDraft = draftMap.get(changedDraft.Id) || {
                Id: changedDraft.Id
            };

            const draft = {
                ...previousDraft,
                ...changedDraft
            };

            const row = this.editRows.find(
                (item) => item.Id === changedDraft.Id
            );

            if (!row || !priceColumn || !marginColumn) {
                draftMap.set(changedDraft.Id, draft);
                return;
            }

            const priceField = priceColumn.fieldName;
            const marginField = marginColumn.fieldName;

            const marginChanged = Object.prototype.hasOwnProperty.call(
                changedDraft,
                marginField
            );

            const priceChanged = Object.prototype.hasOwnProperty.call(
                changedDraft,
                priceField
            );

            const marginCurrencyValues = this.getMarginCurrencyValues(row);
            const landingCost = marginCurrencyValues?.landingCost;
            const exchangeRate = marginCurrencyValues?.exchangeRate;

            // Margin changed: validate and calculate Sales Price.
            if (marginChanged) {
                const marginPercent = Number(changedDraft[marginField]);

                if (
                    landingCost == null ||
                    exchangeRate == null ||
                    !Number.isFinite(marginPercent) ||
                    marginPercent >= 100
                ) {
                    this.toast(
                        'Invalid Margin',
                        'Enter a valid margin below 100%. Ensure Landing Cost is available.',
                        'error'
                    );

                    draft[marginField] =
                        previousDraft[marginField] ?? row[marginField];

                    draft[priceField] =
                        previousDraft[priceField] ?? row[priceField];

                } else {
                    const margin = marginPercent / 100;
                    const salesPriceInUserCurrency = landingCost / (1 - margin);
                    const salesPrice = salesPriceInUserCurrency / exchangeRate;

                    draft[priceField] = Number(salesPrice.toFixed(2));
                    draft[marginField] = Number(marginPercent.toFixed(2));
                }
            }

            // Sales Price changed: calculate Margin.
            else if (priceChanged) {
                const salesPrice = Number(changedDraft[priceField]);

                const salesPriceInUserCurrency = salesPrice * (exchangeRate || 1);

                draft[marginField] =
                    landingCost == null ||
                    exchangeRate == null ||
                    !Number.isFinite(salesPriceInUserCurrency) ||
                    salesPriceInUserCurrency === 0
                        ? null
                        : Number(
                            (((salesPriceInUserCurrency - landingCost) /
                                salesPriceInUserCurrency) * 100).toFixed(2)
                        );
            }

            draftMap.set(changedDraft.Id, draft);
        });

        this.drafts = Array.from(draftMap.values());

        this.editRows = this.editRows.map((row) => {
            const draft = draftMap.get(row.Id);
            if (!draft) {
                return row;
            }

            const updatedRow = { ...row, ...draft };
            if (marginColumn) {
                const marginValue = updatedRow[marginColumn.fieldName];
                updatedRow.marginCellClass =
                    marginValue !== null &&
                    marginValue !== undefined &&
                    Number(marginValue) < 0
                        ? 'slds-text-color_error slds-text-title_bold'
                        : '';
            }

            (this.vm.editColumns || []).forEach((column) => {
                if (
                    column.source === 'LINE_ITEM' &&
                    String(column.type || '').toLowerCase() === 'picklist' &&
                    column.labelFieldName
                ) {
                    updatedRow[column.labelFieldName] = this.getPicklistLabel(
                        column,
                        updatedRow[column.fieldName]
                    );
                }
            });

            return updatedRow;
        });
    }

    // Update the Lookup display label after a record is selected.
    handleLookupSelectionChange(event) {
        const { rowId, fieldName, value, label } = event.detail;
        const column = (this.vm.editColumns || []).find(
            (item) => item.fieldName === fieldName
        );

        if (!rowId || !column || !this.isColumnEditable(column)) {
            return;
        }

        this.editRows = this.editRows.map((row) =>
            row.Id === rowId
                ? {
                    ...row,
                    [fieldName]: value,
                    [column.labelFieldName]: label,
                    [column.urlFieldName]: value ? `/${value}` : null
                }
                : row
        );
    }

    // Remove selected product
    handleEditRowAction(event) {
        if (this.isRestrictedEditMode || event.detail.action.name !== 'remove') {
            return;
        }

        const row = event.detail.row;

        if (row.lineItemId) {
            this.removedIds = [
                ...this.removedIds,
                row.lineItemId
            ];
        }

        this.editRows = this.editRows.filter(
            (item) => item.Id !== row.Id
        );

        if (this.isAddProductFlow && !row.lineItemId) {
            this.selectedProducts = this.selectedProducts.filter(
                (product) => product.Id !== row.Id
            );
        }

        this.drafts = this.drafts.filter(
            (draft) => draft.Id !== row.Id
        );
    }

    // Save products using the standard Edit Products flow.
    async handleSaveProducts() {
        if (this.busy) {
            return;
        }

        const draftsById = new Map(
            this.drafts.map((draft) => [draft.Id, draft])
        );

        const requiredColumns = (this.vm.editColumns || []).filter(
            (column) =>
                column.source === 'LINE_ITEM' &&
                this.isColumnEditable(column) &&
                column.required
        );

        for (const row of this.editRows) {
            const draft = draftsById.get(row.Id) || {};

            for (const column of requiredColumns) {
                const value = Object.prototype.hasOwnProperty.call(
                    draft,
                    column.fieldName
                )
                    ? draft[column.fieldName]
                    : row[column.fieldName];

                if (
                    value === null ||
                    value === undefined ||
                    (typeof value === 'string' && value.trim() === '')
                ) {
                    this.toast(
                        'Required Field Missing',
                        `${column.label} is required for ${row.productName || 'the selected product'}.`,
                        'warning'
                    );
                    return;
                }
            }
        }

        const payload = this.editRows.map((row) => {
            const draft = draftsById.get(row.Id) || {};
            const values = {};

            (this.vm.editColumns || []).forEach((column) => {
                if (
                    column.source !== 'LINE_ITEM' ||
                    !this.isColumnEditable(column)
                ) {
                    return;
                }

                const value = Object.prototype.hasOwnProperty.call(
                    draft,
                    column.fieldName
                )
                    ? draft[column.fieldName]
                    : row[column.fieldName];

                if (value !== undefined) {
                    values[column.apiName] = value;
                }
            });

            return {
                lineItemId: row.lineItemId || null,
                pricebookEntryId: row.pricebookEntryId,
                values
            };
        });

        const isFirstOpportunityProductAdd =
            this.isAddProductFlow &&
            this.vm?.parentObjectApiName === 'Opportunity' &&
            this.vm?.totalCount === 0;

        this.busy = true;

        try {
            await saveProducts({
                recordId: this.recordId,
                payloadJson: JSON.stringify(payload),
                deleteIdsJson: JSON.stringify(this.removedIds)
            });

            this.modal = null;
            this.isAddProductFlow = false;

            this.toast(
                'Success',
                'Products saved.',
                'success'
            );

            if (isFirstOpportunityProductAdd) {
                this.dispatchEvent(new RefreshEvent());
            } else {
                await this.refresh();
            }

        } catch (error) {
            this.toast('Error', this.message(error), 'error');
        } finally {
            this.busy = false;
        }
    }


    async handleViewRefresh() {
        await this.refresh();
        return true;
    }

    // Watch the line item through Lightning Data Service.
    @wire(getRecord, {
        recordId: '$rowEditRecordId',
        fields: '$rowEditFields'
    })
    wiredRowEditRecord({ data }) {
        if (!data) {
            return;
        }

        const lastModifiedDate = data.fields?.LastModifiedDate?.value;
        if (!lastModifiedDate) {
            return;
        }

        // Store the initial value before the user edits the record.
        if (!this.rowEditLastModifiedDate) {
            this.rowEditLastModifiedDate = lastModifiedDate;
            return;
        }

        // Refresh when the standard Edit action saves the record.
        if (this.rowEditLastModifiedDate !== lastModifiedDate) {
            this.rowEditLastModifiedDate = lastModifiedDate;
            this.refresh();
        }
    }

    // Related list row actions
    handleRelatedAction(event) {
        const row = event.detail.row;
        const actionName = event.detail.action.name;

        if (actionName === 'view' || actionName === 'edit') {
            if (actionName === 'edit') {
                this.rowEditRecordId = row.Id;
                this.rowEditNavigationPending = true;
                this.rowEditPageOpened = false;
            }

            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: row.Id,
                    objectApiName: this.vm.lineItemObjectApiName,
                    actionName: actionName
                }
            });
        } else if (actionName === 'delete') {
            this.deleteTarget = row;
            this.modal = 'delete';
        }
    }

    // Refresh the Apex-backed related list after the standard record form saves.
    async handleRowEditSuccess() {
        this.modal = null;
        this.rowEditRecordId = null;
        await this.refresh();
        this.toast('Success', 'Product updated successfully.', 'success');
    }

    handleRowEditCancel() {
        this.modal = null;
        this.rowEditRecordId = null;
    }

    // Delete product
    async confirmDelete() {
        if (!this.deleteTarget || this.busy) {
            return;
        }

        this.busy = true;

        try {
            await deleteRecord(this.deleteTarget.Id);

            this.modal = null;
            this.deleteTarget = null;

            this.toast(
                'Success',
                'Product deleted.',
                'success'
            );

            await this.refresh();

        } catch (error) {
            this.toast('Error', this.message(error), 'error');
        } finally {
            this.busy = false;
        }
    }

    // View All
    viewAll() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordRelationshipPage',
            attributes: {
                recordId: this.recordId,
                objectApiName: this.vm.parentObjectApiName,
                relationshipApiName: this.vm.relationshipApiName,
                actionName: 'view'
            }
        });
    }

    // Common methods
    closeModal() {
        if (this.busy) {
            return;
        }

        this.clearSearchTimeout();
        this.productRequestId += 1;
        this.loadingMoreProducts = false;
        this.modal = null;
        this.rowEditRecordId = null;
        this.drafts = [];
        this.deleteTarget = null;
        this.isAddProductFlow = false;
        this.availabilityOverlayResizeObserver?.disconnect();
        this.availabilityOverlayResizeObserver = null;
        this.availabilityOverlayResizeTarget = null;
        this.showAvailabilityModal = false;
        this.availabilityProductIds = [];
    }

    openProductAvailability() {
        if (!this.isEdit || this.busy || this.showAvailabilityModal) {
            return;
        }

        const productIds = [...new Set(
            (this.editRows || []).map((row) => row.productId).filter(Boolean)
        )];

        if (!productIds.length) {
            this.toast(
                'No Products',
                'There are no products available for an availability check.',
                'warning'
            );
            return;
        }

        this.availabilityProductIds = productIds;
        this.showAvailabilityModal = true;
    }

    closeProductAvailability() {
        this.availabilityOverlayResizeObserver?.disconnect();
        this.availabilityOverlayResizeObserver = null;
        this.availabilityOverlayResizeTarget = null;
        this.showAvailabilityModal = false;
        this.availabilityProductIds = [];
    }

    toast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    message(error) {
        return error?.body?.message ||
            error?.message ||
            'Unexpected error';
    }


    // -------------------------------------------------------------------------
    // FUTURE SCOPE: Site/Warehouse allocation (parked until this phase is active)
    // -------------------------------------------------------------------------
    // FUTURE PHASE: import getSiteAllocationData from '@salesforce/apex/ProductRelatedListController_CC.getSiteAllocationData';

    /* FUTURE PHASE: Site/Warehouse allocation state.
    siteRecords = [];
    warehouseRecords = [];
    inventoryByProductWarehouse = {};
    siteAllocationProducts = [];
    availabilityProductIds = [];
    showAvailabilityModal = false;
    siteAllocationRowCounter = 0;
    siteAllocationSignature = '';
    */

    /* FUTURE PHASE: Site/Warehouse modal state, metadata column rendering and allocation validation getters. The standard Edit Products screen remains active until this feature is reactivated.
    get showSiteAllocationScreen() {
        return this.modal === 'siteAllocation';
    }

    get showSitesWarehousesSelection() {
        return this.vm?.showSitesWarehousesSelection === true;
    }

    get showEditNext() {
        return this.isEdit && this.showSitesWarehousesSelection;
    }

    get showEditSave() {
        return this.isEdit && !this.showSitesWarehousesSelection;
    }

    */

    /* FUTURE PHASE: Site Account filtering, Site Allocation metadata column mapping, and allocation Save validation.
    get siteRecordFilter() {
        if (!this.vm?.accountId || !this.vm?.siteRecordTypeId) {
            return undefined;
        }

        return {
            criteria: [
                { fieldPath: 'ParentId', operator: 'eq', value: this.vm.accountId },
                { fieldPath: 'RecordTypeId', operator: 'eq', value: this.vm.siteRecordTypeId }
            ]
        };
    }

    get allocationColumns() {
        const configured = this.vm?.siteAllocationColumns || [];
        const seen = new Set();

        const rolesByApiName = {
            sites_cc__c: 'site',
            shippingaddress: 'address',
            warehouse_cc__c: 'warehouse',
            quantity: 'quantity'
        };

        const rolesByLabel = {
            site: 'site',
            'shipping address': 'address',
            'fulfillment warehouse': 'warehouse',
            warehouse: 'warehouse',
            quantity: 'quantity'
        };

        const roleLabels = {
            site: 'Site',
            address: 'Shipping Address',
            warehouse: 'Fulfillment Warehouse',
            quantity: 'Quantity'
        };

        const mapped = configured.reduce((result, column, index) => {
            const apiName = String(column.apiName || '').trim().toLowerCase();
            const label = String(column.label || '').trim().toLowerCase();

            let key = rolesByApiName[apiName];

            if (!key || seen.has(key)) {
                const labelKey = rolesByLabel[label];

                if (labelKey && !seen.has(labelKey)) {
                    key = labelKey;
                }
            }

            if (!key || seen.has(key)) {
                return result;
            }

            seen.add(key);

            result.push({
                key,
                label: column.label || roleLabels[key],
                order: column.displayOrder == null
                    ? index + 1
                    : Number(column.displayOrder),
                isSite: key === 'site',
                isAddress: key === 'address',
                isWarehouse: key === 'warehouse',
                isQuantity: key === 'quantity'
            });

            return result;
        }, []);

        mapped.sort((first, second) => first.order - second.order);

        mapped.push({
            key: 'delete',
            label: '',
            order: Number.MAX_SAFE_INTEGER,
            isDelete: true
        });

        return mapped;
    }

    get allocationColumnCount() {
        return this.allocationColumns.length + 1;
    }

    get allocationSaveDisabled() {
        return this.busy || this.hasSiteAllocationIssues;
    }

    // Availability warnings do not block saving.
    // Every product must have at least one complete allocation row.
    get hasSiteAllocationIssues() {
        return !this.siteAllocationProducts.length ||
            this.siteAllocationProducts.some((product) => {
                if (!product.siteRows || product.siteRows.length === 0) {
                    return true;
                }

                return product.siteRows.some((row) => {
                    const hasQuantity = row.quantity !== '' &&
                        row.quantity !== null &&
                        row.quantity !== undefined;

                    const quantity = Number(row.quantity);

                    return !row.siteId ||
                        !row.warehouseId ||
                        !hasQuantity ||
                        !Number.isInteger(quantity) ||
                        quantity <= 0;
                });
            });
    }

    */

    /* FUTURE PHASE: Conditional Quantity-column hiding for the future Site/Warehouse workflow.
    // Identify the configured line-item Quantity column.
    isQuantityColumn(column) {
        const apiName = String(column?.apiName || '').trim().toLowerCase();
        return apiName === 'quantity' || apiName.endsWith('.quantity');
    }

    */

    /* FUTURE PHASE: Site/Warehouse Allocation screen navigation, Site and Warehouse selectors, allocation rows, inventory availability calculations, and Product Availability modal handlers.
    // Continue from Edit Products to Site/Warehouse allocation.
    async handleEditNext() {
        if (!this.showSitesWarehousesSelection || this.busy) {
            return;
        }

        const signature = this.editRows
            .map((row) => row.lineItemId || row.Id || row.pricebookEntryId)
            .join('|');

        if (this.siteAllocationSignature === signature && this.siteAllocationProducts.length) {
            this.recalculateSiteAvailability();
            this.modal = 'siteAllocation';
            return;
        }

        const productIds = [...new Set(
            this.editRows.map((row) => row.productId).filter(Boolean)
        )];

        if (!productIds.length) {
            this.toast('No Products', 'No products are available for Site allocation.', 'warning');
            return;
        }

        this.busy = true;
        try {
            const data = await getSiteAllocationData({
                recordId: this.recordId,
                productIds
            });

            this.vm = {
                ...this.vm,
                siteRecordTypeId: data.siteRecordTypeId
            };
            this.siteRecords = data.sites || [];
            this.warehouseRecords = data.warehouses || [];
            this.inventoryByProductWarehouse = {};

            (data.inventory || []).forEach((item) => {
                const inventoryKey = `${item.productId}:${item.warehouseId}`;
                this.inventoryByProductWarehouse[inventoryKey] =
                    (this.inventoryByProductWarehouse[inventoryKey] || 0) +
                    (Number(item.available) || 0);
            });

            this.siteAllocationProducts = this.editRows.map((row, index) => ({
                key: row.lineItemId || row.Id || `${row.productId}-${index}`,
                productId: row.productId,
                productName: row.productName || 'Product',
                productCode: row.productCode || '',
                pricebookEntryId: row.pricebookEntryId,
                lineItemId: row.lineItemId || null,
                totalSiteQuantity: 0,
                accordionLabel: `${row.productName || 'Product'} | Total Quantity: 0`,
                isExpanded: true,
                chevronIcon: 'utility:chevrondown',
                hasSiteRows: false,
                siteRows: []
            }));

            this.siteAllocationSignature = signature;
            this.recalculateSiteAvailability();
            this.modal = 'siteAllocation';
        } catch (error) {
            this.toast('Error', this.message(error), 'error');
        } finally {
            this.busy = false;
        }
    }

    handleAllocationBack() {
        this.modal = 'edit';
    }

    toggleAllocationProduct(event) {
        const productKey = event.currentTarget.dataset.productKey;
        this.siteAllocationProducts = this.siteAllocationProducts.map((product) =>
            product.key === productKey
                ? {
                    ...product,
                    isExpanded: !product.isExpanded,
                    chevronIcon: product.isExpanded
                        ? 'utility:chevronright'
                        : 'utility:chevrondown'
                }
                : product
        );
    }

    handleAddSite(event) {
        const productKey = event.currentTarget.dataset.productKey;
        this.siteAllocationRowCounter += 1;

        this.siteAllocationProducts = this.siteAllocationProducts.map((product) => {
            if (product.key !== productKey) {
                return product;
            }

            const newRow = {
                key: `site-row-${this.siteAllocationRowCounter}`,
                siteId: null,
                siteName: '',
                shippingAddress: '',
                warehouseId: null,
                warehouseName: '',
                quantity: '',
                quantityError: '',
                availabilityWarning: ''
            };

            return {
                ...product,
                isExpanded: true,
                siteRows: [...product.siteRows, newRow]
            };
        });

        this.recalculateSiteAvailability();
    }

    handleSiteChange(event) {
        const productKey = event.currentTarget.dataset.productKey;
        const rowKey = event.currentTarget.dataset.rowKey;
        const siteId = event.detail.recordId;
        const selectedSite = this.siteRecords.find((site) => site.Id === siteId);

        this.updateSiteAllocationRow(productKey, rowKey, (row) => {
            const updatedRow = {
                ...row,
                siteId: siteId || null,
                siteName: selectedSite?.name || '',
                shippingAddress: selectedSite?.shippingAddress || ''
            };

            // TO BE UNCOMMENTED after Account.Warehouse_CC__c is created:
            // updatedRow.warehouseId = selectedSite?.defaultWarehouseId || null;
            // updatedRow.warehouseName = selectedSite?.defaultWarehouseName || '';

            return updatedRow;
        });
        this.recalculateSiteAvailability();
    }

    handleWarehouseChange(event) {
        const productKey = event.currentTarget.dataset.productKey;
        const rowKey = event.currentTarget.dataset.rowKey;
        const warehouseId = event.detail.recordId;
        const selectedWarehouse = this.warehouseRecords.find(
            (warehouse) => warehouse.Id === warehouseId
        );

        this.updateSiteAllocationRow(productKey, rowKey, (row) => ({
            ...row,
            warehouseId: warehouseId || null,
            warehouseName: selectedWarehouse?.name || '',
            availabilityWarning: ''
        }));
        this.recalculateSiteAvailability();
    }

    handleSiteQuantityChange(event) {
        const productKey = event.currentTarget.dataset.productKey;
        const rowKey = event.currentTarget.dataset.rowKey;
        const value = event.detail.value;

        this.updateSiteAllocationRow(productKey, rowKey, (row) => ({
            ...row,
            quantity: value === '' || value === null ? '' : Number(value)
        }));
        this.recalculateSiteAvailability();
    }

    handleRemoveSite(event) {
        const productKey = event.currentTarget.dataset.productKey;
        const rowKey = event.currentTarget.dataset.rowKey;

        this.siteAllocationProducts = this.siteAllocationProducts.map((product) =>
            product.key === productKey
                ? {
                    ...product,
                    siteRows: product.siteRows.filter((row) => row.key !== rowKey)
                }
                : product
        );
        this.recalculateSiteAvailability();
    }

    updateSiteAllocationRow(productKey, rowKey, updateRow) {
        this.siteAllocationProducts = this.siteAllocationProducts.map((product) =>
            product.key === productKey
                ? {
                    ...product,
                    siteRows: product.siteRows.map((row) =>
                        row.key === rowKey ? updateRow(row) : row
                    )
                }
                : product
        );
    }

    // Recalculate remaining availability across every Site row for each Product/Warehouse pair.
    recalculateSiteAvailability() {
        const remainingByProductWarehouse = new Map();
        const warningMessage =
            'The requested Quantity of this Product is not available in this Warehouse, please select a different Warehouse';

        this.siteAllocationProducts = this.siteAllocationProducts.map((product) => {
            let totalSiteQuantity = 0;
            const siteRows = product.siteRows.map((row, rowIndex) => {
                const updatedRow = {
                    ...row,
                    rowNumber: rowIndex + 1,
                    warningKey: `${row.key}-warning`,
                    quantityError: '',
                    availabilityWarning: ''
                };

                const quantity = Number(updatedRow.quantity);
                const hasQuantity = updatedRow.quantity !== '' &&
                    updatedRow.quantity !== null &&
                    updatedRow.quantity !== undefined;
                const validQuantity = hasQuantity &&
                    Number.isInteger(quantity) &&
                    quantity > 0;

                if (hasQuantity && !validQuantity) {
                    updatedRow.quantityError = 'Enter a whole number greater than 0.';
                }

                if (validQuantity) {
                    totalSiteQuantity += quantity;
                }

                if (updatedRow.warehouseId && validQuantity) {
                    const availabilityKey = `${product.productId}:${updatedRow.warehouseId}`;
                    const available = this.inventoryByProductWarehouse[availabilityKey] ?? 0;
                    const remaining = remainingByProductWarehouse.has(availabilityKey)
                        ? remainingByProductWarehouse.get(availabilityKey)
                        : available;

                    if (quantity > remaining) {
                        updatedRow.availabilityWarning = warningMessage;
                        remainingByProductWarehouse.set(availabilityKey, 0);
                    } else {
                        remainingByProductWarehouse.set(
                            availabilityKey,
                            remaining - quantity
                        );
                    }
                }

                return updatedRow;
            });

            return {
                ...product,
                siteRows,
                hasSiteRows: siteRows.length > 0,
                totalSiteQuantity,
                accordionLabel: `${product.productName} | Total Quantity: ${totalSiteQuantity}`
            };
        });
    }

    openProductAvailability(event) {
        const productId = event.currentTarget.dataset.productId;
        if (!productId) {
            return;
        }

        this.availabilityProductIds = [productId];
        this.showAvailabilityModal = true;
    }

    closeProductAvailability() {
        this.showAvailabilityModal = false;
        this.availabilityProductIds = [];
    }

    */

    /* FUTURE PHASE: Site/Warehouse-specific Save implementation.
       This version builds the allocation JSON, derives line-item Quantity from
       Site rows, and passes siteAllocationJson to Apex. Restore only when the
       Site/Warehouse screen moves back into active scope.
    async handleSaveProducts() {
        if (this.busy) {
            return;
        }

        const isSavingSiteAllocations =
            this.vm?.showSitesWarehousesSelection === true;

        if (isSavingSiteAllocations && this.hasSiteAllocationIssues) {
            this.toast(
                'Incomplete Site Allocations',
                'Add at least one complete Site/Warehouse row for every product and enter a positive whole-number Quantity.',
                'warning'
            );
            return;
        }

        const draftsById = new Map(
            this.drafts.map((draft) => [draft.Id, draft])
        );

        const allocationsByLineKey = new Map(
            this.siteAllocationProducts.map((product) => [product.key, product])
        );

        const payload = this.editRows.map((row) => {
            const draft = draftsById.get(row.Id) || {};
            const values = {};

            (this.vm.editColumns || []).forEach((column) => {
                if (
                    column.source !== 'LINE_ITEM' ||
                    !column.editable
                ) {
                    return;
                }

                const value = Object.prototype.hasOwnProperty.call(
                    draft,
                    column.fieldName
                )
                    ? draft[column.fieldName]
                    : row[column.fieldName];

                if (value !== undefined) {
                    values[column.apiName] = value;
                }
            });

            if (isSavingSiteAllocations) {
                const lineKey = row.lineItemId || row.Id || row.pricebookEntryId;
                const allocation = allocationsByLineKey.get(lineKey);

                values.Quantity = allocation?.totalSiteQuantity ?? 0;
            }

            return {
                clientKey: row.lineItemId || row.Id || row.pricebookEntryId,
                lineItemId: row.lineItemId || null,
                pricebookEntryId: row.pricebookEntryId,
                values
            };
        });

        // Always serialize the allocation payload.
        // Do not conditionally pass null to Apex.
        const siteAllocationPayload = isSavingSiteAllocations
            ? this.siteAllocationProducts.map((product) => ({
                clientKey: product.key,
                lineItemId: product.lineItemId,
                pricebookEntryId: product.pricebookEntryId,
                siteRows: product.siteRows.map((row) => ({
                    siteId: row.siteId,
                    warehouseId: row.warehouseId,
                    quantity: row.quantity
                }))
            }))
            : [];

        const siteAllocationJson = JSON.stringify(siteAllocationPayload);

        this.busy = true;

        try {
            await saveProducts({
                recordId: this.recordId,
                payloadJson: JSON.stringify(payload),
                deleteIdsJson: JSON.stringify(this.removedIds),
                siteAllocationJson: siteAllocationJson
            });

            this.modal = null;
            this.siteAllocationProducts = [];
            this.siteAllocationSignature = '';
            this.isAddProductFlow = false;

            this.toast(
                'Success',
                isSavingSiteAllocations
                    ? 'Products and Site/Warehouse allocations saved successfully.'
                    : 'Products saved.',
                'success'
            );

            await this.refresh();

        } catch (error) {
            this.toast('Error', this.message(error), 'error');
        } finally {
            this.busy = false;
        }
    }

    */
}