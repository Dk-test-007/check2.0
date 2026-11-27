import LightningDatatable from 'lightning/datatable';

import marginPercentTemplate from './marginPercent.html';
import marginPercentEditTemplate from './marginPercentEdit.html';
import lookupTemplate from './lookup.html';
import lookupEditTemplate from './lookupEdit.html';
import picklistTemplate from './picklist.html';
import picklistEditTemplate from './picklistEdit.html';

export default class ProductDataTable_CC extends LightningDatatable {
    static customTypes = {
        lookup: {
            template: lookupTemplate,
            editTemplate: lookupEditTemplate,
            standardCellLayout: true,
            typeAttributes: [
                'objectApiName',
                'recordLabel',
                'recordUrl',
                'placeholder',
                'rowId',
                'fieldName'
            ]
        },
        marginPercent: {
            template: marginPercentTemplate,
            editTemplate: marginPercentEditTemplate,
            standardCellLayout: true,
            typeAttributes: [
                'minimumFractionDigits',
                'maximumFractionDigits',
                'min',
                'max',
                'step',
                'textClass'
            ]
        },
        picklist: {
            template: picklistTemplate,
            editTemplate: picklistEditTemplate,
            standardCellLayout: true,
            typeAttributes: [
                'options',
                'placeholder',
                'displayLabel'
            ]
        }
    };
}