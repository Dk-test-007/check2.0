import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getDuplicateProductNames from '@salesforce/apex/QuoteDuplicateLineItemController_CC.getDuplicateProductNames';
import hasNegativeMargin from '@salesforce/apex/QuoteDuplicateLineItemController_CC.hasNegativeMargin';

export default class QuoteDuplicateLineItemsBanner_CC extends LightningElement {
    @api recordId;

    duplicateProductNames = '';
    hasDuplicates = false;
    hasNegativeMargin = false;

    duplicateProductsResult;
    negativeMarginResult;

    @wire(getDuplicateProductNames, { quoteId: '$recordId' })
    wiredDuplicateProducts(result) {
        this.duplicateProductsResult = result;

        const { data, error } = result;

        if (data) {
            this.hasDuplicates = data.length > 0;
            this.duplicateProductNames = data.join(', ');
        } else if (error) {
            this.hasDuplicates = false;
            this.duplicateProductNames = '';
            console.error(
                'Error checking duplicate Quote Line Items',
                error
            );
        }
    }

    @wire(hasNegativeMargin, { quoteId: '$recordId' })
    wiredNegativeMargin(result) {
        this.negativeMarginResult = result;

        const { data, error } = result;

        if (data !== undefined) {
            this.hasNegativeMargin = data;
        } else if (error) {
            this.hasNegativeMargin = false;
            console.error(
                'Error checking negative Quote Line Item margin',
                error
            );
        }
    }

    handleRefresh() {
        refreshApex(this.duplicateProductsResult);
        refreshApex(this.negativeMarginResult);
    }
}