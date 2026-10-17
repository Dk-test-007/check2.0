import { LightningElement } from 'lwc';
import searchProducts from '@salesforce/apex/ProductAvailabilityController_CC.searchProducts';
import getInventory from '@salesforce/apex/ProductAvailabilityController_CC.getInventory';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class ProductAvailabilityCC extends LightningElement {
    searchKey = '';
    selectedProducts = [];
    searchResults = [];
    inventoryGroups = [];
    isSearching = false;
    isLoading = false;
    hasSearched = false;
    searchError;
    inventoryError;
    searchRequestId = 0;

    get hasSelectedProducts() {
        return this.selectedProducts.length > 0;
    }

    get isCheckDisabled() {
        return !this.hasSelectedProducts || this.isLoading;
    }

    get showSearchResults() {
        return this.searchResults.length > 0;
    }

    get hasInventoryResults() {
        return this.hasSearched && this.inventoryGroups.length > 0;
    }

    get showInventoryError() {
        return Boolean(this.inventoryError);
    }

    get showSearchError() {
        return Boolean(this.searchError);
    }

    async handleSearchChange(event) {
        this.searchKey = event.target.value;
        this.searchError = undefined;

        this.hasSearched = false;
        this.inventoryGroups = [];
        this.inventoryError = undefined;

        const requestId = ++this.searchRequestId;

        if (!this.searchKey || this.searchKey.trim().length < 2) {
            this.searchResults = [];
            this.isSearching = false;
            return;
        }

        this.isSearching = true;

        try {
            const results = await searchProducts({
                searchKey: this.searchKey.trim()
            });

            if (requestId !== this.searchRequestId) {
                return;
            }

            const selectedIds = new Set(
                this.selectedProducts.map(product => product.Id)
            );

            this.searchResults = results.filter(
                product => !selectedIds.has(product.Id)
            );
        } catch (error) {
            if (requestId === this.searchRequestId) {
                this.searchResults = [];
                this.searchError = this.getErrorMessage(error);
            }
        } finally {
            if (requestId === this.searchRequestId) {
                this.isSearching = false;
            }
        }
    }

    handleSelectProduct(event) {
        const productId = event.currentTarget.dataset.id;
        const product = this.searchResults.find(
            item => item.Id === productId
        );

        if (!product) {
            return;
        }

        this.selectedProducts = [
            ...this.selectedProducts,
            product
        ];

        this.searchRequestId++;
        this.searchKey = '';
        this.searchResults = [];
        this.isSearching = false;
        this.hasSearched = false;
        this.inventoryGroups = [];
        this.inventoryError = undefined;
    }

    handleRemoveProduct(event) {
        this.selectedProducts = this.selectedProducts.filter(
            product => product.Id !== event.detail.name
        );

        this.searchRequestId++;
        this.searchResults = [];
        this.isSearching = false;
        this.hasSearched = false;
        this.inventoryGroups = [];
        this.inventoryError = undefined;
    }

    async handleCheckAvailability() {
        if (!this.hasSelectedProducts || this.isLoading) {
            return;
        }

        this.isLoading = true;
        this.hasSearched = false;
        this.inventoryGroups = [];
        this.inventoryError = undefined;

        try {
            const productIds = this.selectedProducts.map(
                product => product.Id
            );

            const inventory = await getInventory({ productIds });

            this.inventoryGroups = this.groupInventory(inventory);
            this.hasSearched = true;
        } catch (error) {
            this.inventoryError = this.getErrorMessage(error);

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Availability Check Failed',
                    message: this.inventoryError,
                    variant: 'error'
                })
            );
        } finally {
            this.isLoading = false;
        }
    }

    groupInventory(inventory) {
        const productMap = new Map();

        // Create a group for every selected product, even without inventory.
        this.selectedProducts.forEach(product => {
            productMap.set(product.Id, {
                key: product.Id,
                productId: product.Id,
                productName: product.Name,
                productCode: product.ProductCode || '—',
                productUrl: '/' + product.Id,
                lastSynced: product.BC_Last_Modified_Date_Time_CC__c,
                warehouses: [],
                hasWarehouses: false
            });
        });

        // Attach inventory records to their corresponding product groups.
        inventory.forEach(record => {
            const productId = record.Product_CC__c;
            const productGroup = productMap.get(productId);

            if (!productGroup) {
                return;
            }

            productGroup.warehouses.push({
                key: record.Id,
                inventoryId: record.Id,
                warehouseId: record.Warehouse_CC__c,
                warehouseName:
                    record.Warehouse_CC__r?.Name ||
                    'Unknown Warehouse',
                warehouseUrl: record.Warehouse_CC__c
                    ? '/' + record.Warehouse_CC__c
                    : '',
                lastSynced: record.Last_Synced_CC__c,
                stockOnHand: record.Stock_on_Hand_CC__c ?? 0,
                reserved: record.Reserved_CC__c ?? 0,
                committed: record.Committed_CC__c ?? 0,
                restricted: record.Restricted_CC__c ?? 0,
                available: record.Available_CC__c ?? 0,
                availableToOrder:
                    record.Available_To_Order_CC__c ?? 0,
                receiving: record.Receiving_CC__c ?? 0,
                held: record.Held_CC__c ?? 0,
                enteredStock: record.Entered_Stock_CC__c ?? 0,
                damaged: record.Damaged_CC__c ?? 0,
                onHold: record.On_Hold_CC__c ?? 0
            });
        });

        return [...productMap.values()].map(group => ({
            ...group,
            hasWarehouses: group.warehouses.length > 0
        }));
    }

    getErrorMessage(error) {
        return error?.body?.message ||
            error?.message ||
            'An unexpected error occurred.';
    }
}