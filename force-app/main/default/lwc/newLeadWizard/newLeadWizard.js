import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getObjectInfo, getPicklistValuesByRecordType } from 'lightning/uiObjectInfoApi';
import LEAD_OBJECT from '@salesforce/schema/Lead';

import getInitData from '@salesforce/apex/NewLeadWizardController_CC.getInitData';
import checkDuplicates from '@salesforce/apex/NewLeadWizardController_CC.checkDuplicates';
import createLead from '@salesforce/apex/NewLeadWizardController_CC.createLead';
import isLeadReadable from '@salesforce/apex/NewLeadWizardController_CC.isLeadReadable';

import {
    ACTION,
    EMPTY_FORM,
    FAIL_OPTIONS,
    FIELD_RULES,
    MATCH_OPTIONS,
    NAME_KNOWN,
    NAME_OPTIONS,
    NAME_UNKNOWN,
    SOURCE,
    addressProblem,
    buildCandidate,
    placeholderLastName,
    reduceErrors
} from './wizardLogic';

const STEP = Object.freeze({
    LOADING: 'loading',
    LOAD_ERROR: 'loadError',
    NO_ACCESS: 'noAccess',
    COMPANY: 'company',
    ADDRESS: 'address',
    CONTACT: 'contact',
    CHECK_FAILED: 'checkFailed',
    MATCHES: 'matches',
    REVIEW: 'review',
    CREATE_ERROR: 'createError',
    DONE: 'done',
    DONE_NO_ACCESS: 'doneNoAccess',
    STOPPED: 'stopped'
});

/** Screen labels from the flow. */
const STEP_TITLES = {
    [STEP.LOADING]: 'Loading',
    [STEP.LOAD_ERROR]: 'New Lead Wizard Unavailable',
    [STEP.NO_ACCESS]: 'New Lead Wizard Not Available',
    [STEP.COMPANY]: 'Company and Source',
    [STEP.ADDRESS]: 'Address',
    [STEP.CONTACT]: 'Contact',
    [STEP.CHECK_FAILED]: 'Duplicate Check Not Completed',
    [STEP.MATCHES]: 'Possible Matches',
    [STEP.REVIEW]: 'Review',
    [STEP.CREATE_ERROR]: 'Lead Not Created',
    [STEP.DONE]: 'Lead Created',
    [STEP.DONE_NO_ACCESS]: 'Lead Created',
    [STEP.STOPPED]: 'No Lead Created'
};

/** Screens that show a Back button (allowBack = true in the flow). */
const BACK_ALLOWED = new Set([
    STEP.ADDRESS,
    STEP.CONTACT,
    STEP.CHECK_FAILED,
    STEP.MATCHES,
    STEP.REVIEW,
    STEP.CREATE_ERROR
]);

/** Final screens: the only button is Finish. */
const TERMINAL = new Set([STEP.NO_ACCESS, STEP.LOAD_ERROR, STEP.DONE, STEP.DONE_NO_ACCESS, STEP.STOPPED]);

/** Screens with required inputs (shows the "* = Required Information" legend). */
const HAS_REQUIRED_FIELDS = new Set([STEP.COMPANY, STEP.CONTACT, STEP.CHECK_FAILED, STEP.MATCHES]);

const PROGRESS_STEPS = ['company', 'address', 'contact', 'check', 'review'];
const PROGRESS_FOR_STEP = {
    [STEP.COMPANY]: 'company',
    [STEP.ADDRESS]: 'address',
    [STEP.CONTACT]: 'contact',
    [STEP.CHECK_FAILED]: 'check',
    [STEP.MATCHES]: 'check',
    [STEP.REVIEW]: 'review',
    [STEP.CREATE_ERROR]: 'review'
};

const NONE_OPTION = { label: '--None--', value: '' };

const MATCH_COLUMNS = [
    {
        label: 'Name',
        fieldName: 'recordUrl',
        type: 'url',
        sortable: true,
        typeAttributes: { label: { fieldName: 'name' }, target: '_blank', tooltip: 'Open in a new tab' },
        cellAttributes: { iconName: { fieldName: 'iconName' }, iconAlternativeText: { fieldName: 'objectType' } }
    },
    { label: 'Type', fieldName: 'objectType', sortable: true },
    { label: 'Company', fieldName: 'company', sortable: true },
    { label: 'City', fieldName: 'city', sortable: true },
    { label: 'Zip/Postal Code', fieldName: 'postalCode', sortable: true },
    { label: 'Lead Status', fieldName: 'status', sortable: true },
    { label: 'Owner', fieldName: 'owner', sortable: true },
    { label: 'Match Reason', fieldName: 'reason', sortable: true, wrapText: true }
];

export default class NewLeadWizard extends NavigationMixin(LightningElement) {
    step = STEP.LOADING;
    history = [];
    form = { ...EMPTY_FORM };

    busy = false;
    busyMessage = 'Loading';

    // init / picklists
    hasAccess = false;
    suggestedEntity;
    initLoaded = false;
    picklistsLoaded = false;
    picklists;
    recordTypeId;
    loadErrorMessage;

    // address
    showAddressError = false;
    addressMessage = '';

    // duplicate check / create
    candidate;
    dup = {};
    sortedBy;
    sortedDirection = 'asc';
    createdLeadId;
    createErrorMessage;

    scrollPending = false;

    // ---- Loading ---------------------------------------------------------------------------

    connectedCallback() {
        getInitData()
            .then((data) => {
                this.hasAccess = data && data.hasAccess === true;
                this.suggestedEntity = data ? data.suggestedEntity : null;
            })
            .catch((error) => {
                this.loadErrorMessage = reduceErrors(error);
            })
            .finally(() => {
                this.initLoaded = true;
                this.tryStart();
            });
    }

    renderedCallback() {
        if (this.scrollPending) {
            this.scrollPending = false;
            const header = this.template.querySelector('.slds-page-header');
            if (header && typeof header.scrollIntoView === 'function') {
                header.scrollIntoView({ block: 'start' });
            }
        }
    }

    @wire(getObjectInfo, { objectApiName: LEAD_OBJECT })
    wiredObjectInfo({ data, error }) {
        if (data) {
            this.recordTypeId = data.defaultRecordTypeId;
        } else if (error) {
            this.failPicklists(error);
        }
    }

    @wire(getPicklistValuesByRecordType, { objectApiName: LEAD_OBJECT, recordTypeId: '$recordTypeId' })
    wiredPicklists({ data, error }) {
        if (data) {
            this.picklists = data.picklistFieldValues;
            this.picklistsLoaded = true;
            this.tryStart();
        } else if (error) {
            this.failPicklists(error);
        }
    }

    failPicklists(error) {
        this.loadErrorMessage = this.loadErrorMessage || reduceErrors(error);
        this.picklistsLoaded = true;
        this.tryStart();
    }

    /** Access check, then the first screen once everything it needs is loaded. */
    tryStart() {
        if (this.step !== STEP.LOADING || !this.initLoaded) return;
        if (!this.loadErrorMessage && !this.hasAccess) {
            this.step = STEP.NO_ACCESS;
            return;
        }
        if (!this.picklistsLoaded) return;
        if (this.loadErrorMessage) {
            this.step = STEP.LOAD_ERROR;
            return;
        }
        this.applySuggestedEntity();
        this.goToCompany();
    }

    /** inEntity default = varSuggestedEntity, only when it is one of the offered active values. */
    applySuggestedEntity() {
        const suggestion = this.suggestedEntity;
        if (!this.form.entity && suggestion && this.entityOptions.some((o) => o.value === suggestion)) {
            this.form = { ...this.form, entity: suggestion };
        }
    }

    // ---- Step getters ----------------------------------------------------------------------

    get isLoading() { return this.step === STEP.LOADING; }
    get isLoadError() { return this.step === STEP.LOAD_ERROR; }
    get isNoAccess() { return this.step === STEP.NO_ACCESS; }
    get isCompanyStep() { return this.step === STEP.COMPANY; }
    get isAddressStep() { return this.step === STEP.ADDRESS; }
    get isContactStep() { return this.step === STEP.CONTACT; }
    get isCheckFailed() { return this.step === STEP.CHECK_FAILED; }
    get isMatches() { return this.step === STEP.MATCHES; }
    get isReview() { return this.step === STEP.REVIEW; }
    get isCreateError() { return this.step === STEP.CREATE_ERROR; }
    get isDone() { return this.step === STEP.DONE; }
    get isDoneNoAccess() { return this.step === STEP.DONE_NO_ACCESS; }
    get isStopped() { return this.step === STEP.STOPPED; }

    get showSpinner() { return this.busy || this.isLoading; }
    get progressStep() { return PROGRESS_FOR_STEP[this.step]; }
    get showProgress() { return !!this.progressStep; }
    get showRequiredLegend() { return HAS_REQUIRED_FIELDS.has(this.step); }

    get headerMeta() {
        const title = STEP_TITLES[this.step];
        const index = PROGRESS_STEPS.indexOf(this.progressStep);
        return index >= 0 ? `Step ${index + 1} of ${PROGRESS_STEPS.length} • ${title}` : title;
    }

    get showCancel() { return !this.isLoading && !TERMINAL.has(this.step); }
    get showBack() { return BACK_ALLOWED.has(this.step) && this.history.length > 0; }
    get showNext() { return !this.isLoading; }

    get nextLabel() {
        if (TERMINAL.has(this.step)) return 'Finish';
        switch (this.step) {
            case STEP.CONTACT: return 'Check and Review';
            case STEP.REVIEW: return 'Create Lead';
            case STEP.CREATE_ERROR: return 'Edit Details';
            default: return 'Next';
        }
    }

    // ---- Field visibility (visibilityRule equivalents) ---------------------------------------

    get isSourceOther() { return this.form.leadSource === SOURCE.OTHER; }
    get isSourceTradeShow() { return this.form.leadSource === SOURCE.TRADE_SHOW; }
    get isSourceReferral() { return this.form.leadSource === SOURCE.REFERRAL; }
    get isSourceLinkedIn() { return this.form.leadSource === SOURCE.LINKEDIN; }
    get isSourceZoomInfo() { return this.form.leadSource === SOURCE.ZOOMINFO; }
    get isSourceExistingCustomer() { return this.form.leadSource === SOURCE.EXISTING_CUSTOMER; }
    get hasSourceDetails() {
        return (
            this.isSourceOther ||
            this.isSourceTradeShow ||
            this.isSourceReferral ||
            this.isSourceLinkedIn ||
            this.isSourceZoomInfo ||
            this.isSourceExistingCustomer
        );
    }
    get isNameKnown() { return this.form.nameKnown === NAME_KNOWN; }
    get isNameUnknown() { return this.form.nameKnown === NAME_UNKNOWN; }
    get isCreateAnyway() { return this.form.matchAction === ACTION.CREATE_ANYWAY; }
    get placeholderLastName() { return placeholderLastName(this.form.company); }

    // ---- Options -----------------------------------------------------------------------------

    get nameOptions() { return NAME_OPTIONS; }
    get failOptions() { return FAIL_OPTIONS; }
    get matchOptions() { return MATCH_OPTIONS; }

    picklistOptions(fieldApiName) {
        const field = this.picklists && this.picklists[fieldApiName];
        return field ? field.values.map((v) => ({ label: v.label, value: v.value })) : [];
    }

    get entityOptions() { return this.picklistOptions('Belongs_To_CC__c'); }
    get leadSourceOptions() { return this.picklistOptions('LeadSource'); }
    get referrerTypeOptions() { return this.picklistOptions('Referrer_Type_CC__c'); }
    get leadTypeOptions() { return [NONE_OPTION, ...this.picklistOptions('Lead_Type_CC__c')]; }
    get countryOptions() { return this.picklistOptions('CountryCode'); }

    /** State/Province choices follow the selected Country (dependent picklist). */
    get provinceOptions() {
        return this.provinceOptionsFor(this.form.country);
    }

    provinceOptionsFor(countryCode) {
        const states = this.picklists && this.picklists.StateCode;
        if (!states || !countryCode) return [];
        const index = states.controllerValues[countryCode];
        if (index === undefined) return [];
        return states.values
            .filter((v) => v.validFor.includes(index))
            .map((v) => ({ label: v.label, value: v.value }));
    }

    labelFor(fieldApiName, value) {
        if (!value) return '';
        const option = this.picklistOptions(fieldApiName).find((o) => o.value === value);
        return option ? option.label : value;
    }

    // ---- Duplicate results -------------------------------------------------------------------

    get matchColumns() { return MATCH_COLUMNS; }

    get useMatchTable() {
        return Array.isArray(this.dup.matches) && this.dup.matches.length > 0;
    }

    get hasMatchesToShow() {
        return this.useMatchTable || !!this.dup.matchSummaryHtml;
    }

    get matchRows() {
        const rows = Array.isArray(this.dup.matches) ? [...this.dup.matches] : [];
        if (!this.sortedBy) return rows;
        const field = this.sortedBy === 'recordUrl' ? 'name' : this.sortedBy;
        const direction = this.sortedDirection === 'desc' ? -1 : 1;
        return rows.sort((a, b) => direction * String(a[field] || '').localeCompare(String(b[field] || '')));
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
    }

    get matchCount() {
        if (this.useMatchTable) return this.dup.matches.length;
        return this.dup.matchCount === null || this.dup.matchCount === undefined ? 0 : this.dup.matchCount;
    }

    get matchesSectionTitle() {
        return `Possible Matches (${this.matchCount})`;
    }

    get hiddenMatchText() {
        const hidden = this.dup.hiddenMatchCount || 0;
        return hidden > 0 ? `Plus ${hidden} more not listed. Refine the company name to narrow the results.` : '';
    }

    get checkFailedDetail() {
        return [this.dup.errorMessage, this.dup.faultMessage].filter(Boolean).join(' ');
    }

    // ---- Review / result text ----------------------------------------------------------------

    get createdCompany() {
        return this.candidate ? this.candidate.Company : '';
    }

    get reviewSections() {
        const c = this.candidate || {};
        const sourceDetail = [c.Lead_Source_Other_CC__c, c.Trade_Show_Expo_Name__c, c.Referrer_Name_CC__c]
            .filter(Boolean)
            .join(' ');
        const address = [
            c.Street,
            [c.City, this.stateLabel(c.CountryCode, c.StateCode), c.PostalCode].filter(Boolean).join(' '),
            this.labelFor('CountryCode', c.CountryCode)
        ]
            .filter(Boolean)
            .join('\n');

        const sections = [
            {
                key: 'lead',
                title: 'Lead Information',
                items: [
                    { key: 'company', label: 'Company', value: c.Company },
                    { key: 'entity', label: 'Entity (Carlton company)', value: this.labelFor('Belongs_To_CC__c', c.Belongs_To_CC__c) },
                    {
                        key: 'source',
                        label: 'Lead Source',
                        value: [this.labelFor('LeadSource', c.LeadSource), sourceDetail].filter(Boolean).join(' – ')
                    },
                    { key: 'type', label: 'Entity or Site', value: this.labelFor('Lead_Type_CC__c', c.Lead_Type_CC__c) },
                    { key: 'status', label: 'Lead Status', value: this.labelFor('Status', c.Status) }
                ]
            },
            {
                key: 'address',
                title: 'Address Information',
                items: [{ key: 'address', label: 'Address', value: address }]
            },
            {
                key: 'contact',
                title: 'Contact Information',
                items: [
                    { key: 'name', label: 'Name', value: [c.FirstName, c.LastName].filter(Boolean).join(' ') },
                    { key: 'title', label: 'Title', value: c.Title },
                    { key: 'email', label: 'Email', value: c.Email },
                    { key: 'phone', label: 'Phone', value: c.Phone },
                    { key: 'mobile', label: 'Mobile', value: c.MobilePhone }
                ]
            }
        ];
        return sections.map((section) => ({
            ...section,
            items: section.items.map((item) => ({ ...item, value: item.value || ' ' }))
        }));
    }

    stateLabel(countryCode, stateCode) {
        if (!stateCode) return '';
        const option = this.provinceOptionsFor(countryCode).find((o) => o.value === stateCode);
        return option ? option.label : stateCode;
    }

    // ---- Input handlers ----------------------------------------------------------------------

    handleFieldChange(event) {
        const target = event.target;
        const field = target.dataset.field;
        const value = target.type === 'checkbox' ? event.detail.checked : event.detail.value;
        if (typeof target.setCustomValidity === 'function') {
            target.setCustomValidity('');
        }
        this.form = { ...this.form, [field]: value };
    }

    handleAddressChange(event) {
        const { street, city, province, postalCode, country } = event.detail;
        let nextProvince = province || '';
        // Keep StateCode consistent with the selected Country (no free-text state codes).
        if (nextProvince && !this.provinceOptionsFor(country).some((o) => o.value === nextProvince)) {
            nextProvince = '';
        }
        this.form = {
            ...this.form,
            street: street || '',
            city: city || '',
            province: nextProvince,
            postalCode: postalCode || '',
            country: country || ''
        };
    }

    // ---- Navigation --------------------------------------------------------------------------

    goTo(nextStep) {
        if (!TERMINAL.has(this.step) && this.step !== STEP.LOADING && this.step !== nextStep) {
            this.history = [...this.history, this.step];
        }
        this.step = nextStep;
        this.scrollPending = true;
    }

    /** Company and Source has no Back button, so the history starts again there. */
    goToCompany() {
        this.history = [];
        this.step = STEP.COMPANY;
        this.scrollPending = true;
    }

    handleBack() {
        if (!this.history.length || this.busy) return;
        const history = [...this.history];
        this.step = history.pop();
        this.history = history;
        this.scrollPending = true;
    }

    handleCancel() {
        if (this.busy) return;
        this.resetWizard();
        this.navigateToLeadList();
    }

    handleNext() {
        if (this.busy) return;
        if (TERMINAL.has(this.step)) {
            this.finish();
            return;
        }
        switch (this.step) {
            case STEP.COMPANY:
                if (this.validateVisibleFields()) this.goTo(STEP.ADDRESS);
                break;
            case STEP.ADDRESS:
                this.submitAddress();
                break;
            case STEP.CONTACT:
                if (this.validateVisibleFields()) this.runDuplicateCheck();
                break;
            case STEP.CHECK_FAILED:
                if (this.validateVisibleFields()) this.routeFailedAction();
                break;
            case STEP.MATCHES:
                if (this.validateVisibleFields()) this.routeMatchAction();
                break;
            case STEP.REVIEW:
                this.createOrConfirm();
                break;
            case STEP.CREATE_ERROR:
                this.goToCompany();
                break;
            default:
                break;
        }
    }

    /** Decide_Address_Complete + Assign_Address_Error / Assign_Address_Ok */
    submitAddress() {
        const problem = addressProblem(this.form, this.provinceOptions.length > 0);
        if (problem) {
            this.showAddressError = true;
            this.addressMessage = problem;
            this.scrollPending = true;
            return;
        }
        this.showAddressError = false;
        this.addressMessage = '';
        this.goTo(STEP.CONTACT);
    }

    /** Decide_Failed_Action */
    routeFailedAction() {
        switch (this.form.failAction) {
            case ACTION.RETRY:
                this.runDuplicateCheck();
                break;
            case ACTION.BACK:
                this.goToCompany();
                break;
            default:
                this.goTo(STEP.STOPPED);
        }
    }

    /** Decide_Match_Action */
    routeMatchAction() {
        switch (this.form.matchAction) {
            case ACTION.BACK:
                this.goToCompany();
                break;
            case ACTION.CREATE_ANYWAY:
                this.goTo(STEP.REVIEW);
                break;
            default:
                this.goTo(STEP.STOPPED);
        }
    }

    /** Assign_Build_Candidate -> Check_Duplicates -> Decide_Check_Result */
    async runDuplicateCheck() {
        this.candidate = buildCandidate(this.form);
        this.busyMessage = 'Checking for possible duplicates';
        this.busy = true;

        let result;
        try {
            result = (await checkDuplicates({ candidate: this.candidate })) || {};
        } catch (error) {
            result = { isSuccess: false, faultMessage: reduceErrors(error) };
        }

        this.dup = result;
        this.sortedBy = undefined;
        this.sortedDirection = 'asc';
        // A new check needs a new decision on the result screens.
        this.form = { ...this.form, failAction: '', matchAction: '', ackDuplicates: false };
        this.busy = false;

        if (result.isSuccess !== true) {
            this.goTo(STEP.CHECK_FAILED);
        } else if (result.hasMatches === true) {
            this.goTo(STEP.MATCHES);
        } else {
            this.goTo(STEP.REVIEW);
        }
    }

    /** Decide_Already_Created -> Create_Lead -> Get_Created_Lead -> Decide_Access */
    async createOrConfirm() {
        this.busyMessage = 'Creating Lead';
        this.busy = true;
        let nextStep;
        try {
            let readable;
            if (this.createdLeadId) {
                readable = await isLeadReadable({ leadId: this.createdLeadId });
            } else {
                const result = await createLead({ candidate: this.candidate });
                this.createdLeadId = result.leadId;
                readable = result.readable;
            }
            nextStep = readable ? STEP.DONE : STEP.DONE_NO_ACCESS;
        } catch (error) {
            if (this.createdLeadId) {
                // Created, but the read-back failed: the flow's fault path shows the no-access screen.
                nextStep = STEP.DONE_NO_ACCESS;
            } else {
                this.createErrorMessage = reduceErrors(error);
                nextStep = STEP.CREATE_ERROR;
            }
        }
        this.busy = false;
        this.goTo(nextStep);
        if (nextStep === STEP.DONE || nextStep === STEP.DONE_NO_ACCESS) {
            this.showCreatedToast(nextStep === STEP.DONE);
        }
    }

    /** Same toast as the standard New Lead save: 'Lead "X" was created.' with a record link when readable. */
    async showCreatedToast(readable) {
        const company = this.createdCompany;
        let toast = { title: 'Success', message: `Lead "${company}" was created.`, variant: 'success' };
        if (readable) {
            try {
                const url = await this[NavigationMixin.GenerateUrl](this.leadRecordPageRef);
                toast = { ...toast, message: 'Lead {0} was created.', messageData: [{ url, label: `"${company}"` }] };
            } catch (e) {
                // keep the plain message
            }
        }
        this.dispatchEvent(new ShowToastEvent(toast));
    }

    get leadRecordPageRef() {
        return {
            type: 'standard__recordPage',
            attributes: { recordId: this.createdLeadId, objectApiName: 'Lead', actionName: 'view' }
        };
    }

    handleOpenLead() {
        this[NavigationMixin.Navigate](this.leadRecordPageRef);
    }

    finish() {
        this.dispatchEvent(new CustomEvent('finish', { detail: { leadId: this.createdLeadId || null } }));
        this.resetWizard();
        this.navigateToLeadList();
    }

    navigateToLeadList() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Lead', actionName: 'home' }
        });
    }

    resetWizard() {
        this.form = { ...EMPTY_FORM };
        this.candidate = undefined;
        this.dup = {};
        this.createdLeadId = undefined;
        this.createErrorMessage = undefined;
        this.showAddressError = false;
        this.addressMessage = '';
        if (this.hasAccess && !this.loadErrorMessage) {
            this.applySuggestedEntity();
            this.goToCompany();
        }
    }

    // ---- Validation --------------------------------------------------------------------------

    /** Required checks plus the flow's validation-rule formulas, on the fields currently rendered. */
    validateVisibleFields() {
        let valid = true;
        this.template.querySelectorAll('[data-field]').forEach((element) => {
            const rule = FIELD_RULES[element.dataset.field];
            if (rule && typeof element.setCustomValidity === 'function') {
                element.setCustomValidity(rule(this.form[element.dataset.field]));
            }
            if (typeof element.reportValidity === 'function' && !element.reportValidity()) {
                valid = false;
            }
        });
        return valid;
    }
}