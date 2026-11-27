/**
 * Pure logic for newLeadWizard: the flow's formulas, validation rules and the
 * "Build Candidate Lead" assignment. No DOM or Apex here, so it is easy to unit test.
 */

export const SOURCE = Object.freeze({
    OTHER: 'Other',
    TRADE_SHOW: 'Trade Show / Expo',
    REFERRAL: 'Referral',
    LINKEDIN: 'LinkedIn Sales Navigator',
    ZOOMINFO: 'ZoomInfo',
    EXISTING_CUSTOMER: 'Existing Customer Enquiry'
});

export const NAME_KNOWN = 'Known';
export const NAME_UNKNOWN = 'Unknown';

export const ACTION = Object.freeze({
    BACK: 'Back',
    STOP: 'Stop',
    RETRY: 'Retry',
    CREATE_ANYWAY: 'CreateAnyway'
});

export const INITIAL_STATUS = 'Identify';
export const DEFAULT_COUNTRY = 'US';

// Flow choices (chNameKnown, chNameUnknown, chRetry, chBack, chStop, chCreateAnyway)
const CH_BACK = { label: 'Go back and correct the details', value: ACTION.BACK };
const CH_STOP = { label: 'Stop - nothing is created (use an existing record instead)', value: ACTION.STOP };
const CH_RETRY = { label: 'Try the duplicate check again', value: ACTION.RETRY };
const CH_CREATE_ANYWAY = { label: 'Create the new Lead anyway', value: ACTION.CREATE_ANYWAY };

export const NAME_OPTIONS = [
    { label: "I know the contact's name", value: NAME_KNOWN },
    { label: 'Contact not yet identified', value: NAME_UNKNOWN }
];
export const FAIL_OPTIONS = [CH_RETRY, CH_BACK, CH_STOP];
export const MATCH_OPTIONS = [CH_BACK, CH_STOP, CH_CREATE_ANYWAY];

export const EMPTY_FORM = Object.freeze({
    // Company and Source
    company: '',
    entity: '',
    leadSource: '',
    leadSourceOther: '',
    tradeShowName: '',
    referrerName: '',
    referrerType: '',
    referrerCompany: '',
    referrerEmail: '',
    linkedInUrl: '',
    zoomInfoUrl: '',
    leadType: '',
    // Address
    street: '',
    city: '',
    province: '',
    postalCode: '',
    country: DEFAULT_COUNTRY,
    // Contact
    nameKnown: '',
    firstName: '',
    lastName: '',
    title: '',
    email: '',
    phone: '',
    mobile: '',
    // Decision screens
    failAction: '',
    matchAction: '',
    ackDuplicates: false
});

export function trim(value) {
    return value === null || value === undefined ? '' : String(value).trim();
}

export function isBlank(value) {
    return trim(value) === '';
}

/** fPlaceholderLastName */
export function placeholderLastName(company) {
    return ('Needs to Identify - ' + trim(company)).substring(0, 80);
}

/**
 * fAddressProblem - empty string when the address is complete.
 * State/Province is required only when the selected Country has states to choose from
 * (countryHasStates), so countries without a state list can still be saved.
 */
export function addressProblem(form, countryHasStates = false) {
    const street = trim(form.street);
    const city = trim(form.city);
    const postal = trim(form.postalCode);
    let message = '';
    if (!city) message += 'City is required. ';
    if (countryHasStates && isBlank(form.province)) message += 'State/Province is required. ';
    if (!postal) message += 'Postal Code is required. ';
    if (isBlank(form.country)) message += 'Country is required. ';
    if (street.length > 255) message += 'Street (both lines together) must be 255 characters or fewer. ';
    if (city.length > 40) message += 'City must be 40 characters or fewer. ';
    if (postal.length > 20) message += 'Postal Code must be 20 characters or fewer. ';
    return message.trim();
}

// ---- Field validation rules (screen field <validationRule> equivalents) -----------------------

const EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const RESERVED_LAST_NAME = 'NEEDSTOIDENTIFY';

const maxLength = (limit) => (value) =>
    isBlank(value) || String(value).length <= limit ? '' : `Maximum ${limit} characters.`;

const emailRule = (value) =>
    isBlank(value) || (String(value).length <= 80 && EMAIL_PATTERN.test(trim(value)))
        ? ''
        : 'Enter a valid email address (max 80 characters).';

const lastNameRule = (value) => {
    const raw = value === null || value === undefined ? '' : String(value);
    const reserved = trim(raw).toUpperCase().replace(/ /g, '').startsWith(RESERVED_LAST_NAME);
    return raw.length <= 80 && !reserved
        ? ''
        : 'Enter a real last name (max 80 characters). "Needs to Identify" is reserved for unknown contacts.';
};

/** Keyed by the data-field attribute used in the template. Returns '' when valid. */
export const FIELD_RULES = Object.freeze({
    company: maxLength(255),
    leadSourceOther: maxLength(255),
    tradeShowName: maxLength(255),
    referrerName: maxLength(255),
    referrerCompany: maxLength(255),
    referrerEmail: emailRule,
    linkedInUrl: maxLength(255),
    zoomInfoUrl: maxLength(255),
    firstName: maxLength(40),
    lastName: lastNameRule,
    title: maxLength(128),
    email: emailRule,
    phone: maxLength(15),
    mobile: maxLength(15),
    ackDuplicates: (value) => (value === true ? '' : 'Confirm that you reviewed the possible matches.')
});

/** Assign_Build_Candidate: wizard inputs -> Lead record (fields hidden by the answers are blanked). */
export function buildCandidate(form) {
    const known = form.nameKnown === NAME_KNOWN;
    const source = form.leadSource || '';
    const referral = source === SOURCE.REFERRAL;
    const onlyIf = (condition, value) => (condition ? trim(value) : '');

    return {
        sobjectType: 'Lead',
        Company: trim(form.company),
        Belongs_To_CC__c: form.entity || '',
        LeadSource: source,
        Lead_Source_Other_CC__c: onlyIf(source === SOURCE.OTHER, form.leadSourceOther),
        Trade_Show_Expo_Name__c: onlyIf(source === SOURCE.TRADE_SHOW, form.tradeShowName),
        Referrer_Name_CC__c: onlyIf(referral, form.referrerName),
        Referrer_Type_CC__c: referral ? form.referrerType || '' : '',
        Referrer_Company_CC__c: onlyIf(referral, form.referrerCompany),
        Referrer_Email_CC__c: onlyIf(referral, form.referrerEmail),
        LinkedIn_Profile_URL_CC__c: onlyIf(source === SOURCE.LINKEDIN, form.linkedInUrl),
        ZoomInfo_Profile_URL_CC__c: onlyIf(source === SOURCE.ZOOMINFO, form.zoomInfoUrl),
        Lead_Type_CC__c: form.leadType || '',
        Street: trim(form.street),
        City: trim(form.city),
        PostalCode: trim(form.postalCode),
        CountryCode: form.country || '',
        StateCode: form.province || '',
        FirstName: onlyIf(known, form.firstName),
        LastName: known ? trim(form.lastName) : placeholderLastName(form.company),
        Title: onlyIf(known, form.title),
        Email: onlyIf(known, form.email),
        Phone: trim(form.phone),
        MobilePhone: onlyIf(known, form.mobile),
        Status: INITIAL_STATUS
    };
}

/** Normalises Apex / UI API errors into one readable string. */
export function reduceErrors(error) {
    if (!error) return 'Unknown error.';
    const body = error.body;
    if (Array.isArray(body)) return body.map((e) => e.message).filter(Boolean).join(' ');
    if (body) {
        if (typeof body.message === 'string' && body.message) return body.message;
        const pageErrors = (body.output && body.output.errors) || body.pageErrors || [];
        if (pageErrors.length) return pageErrors.map((e) => e.message).join(' ');
    }
    return error.message || String(error);
}