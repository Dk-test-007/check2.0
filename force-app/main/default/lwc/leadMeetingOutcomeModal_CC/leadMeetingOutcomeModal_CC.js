import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import { updateRecord } from 'lightning/uiRecordApi';
import getOutcomeForm from '@salesforce/apex/LeadMeetingOutcomeController_CC.getOutcomeForm';
import getDuplicateCheck from '@salesforce/apex/LeadMeetingOutcomeController_CC.getDuplicateCheck';

const STAGE_QUALIFIED = 'Qualified';
const STAGE_DISQUALIFIED = 'Disqualified';
const STAGE_RE_NURTURE = 'Re_Nurture';
const REENGAGEMENT_DATE_FIELD = 'Reengagement_Date_CC__c';
const BYPASS_DUPLICATES_FIELD = 'Bypass_Duplicate_Rules_on_Qualification__c';

/**
 * Column ('left' / 'right') and position of each popup field, following Lead_Lightning_Page_v2_CC (Work tab: the
 * "Engage: meeting and outcome", "Re-Nurture" and "Disqualified" sections).
 * Number of Locations (Entity Leads) and Entity Associated (Site Leads) follow the Engage fields in the right column,
 * shown only when the Lead's saved Lead Type calls for them. Lead Type itself is not asked here: it is already
 * required at an earlier stage.
 */
/**
 * Fields never rendered in the popup, even when a requirement lists them. Lead Type is set and validated at earlier
 * stages; here it only decides whether Number of Locations / Entity Associated apply. The Lead trigger still
 * enforces it on save.
 */
const NOT_ASKED_FIELDS = new Set(['Lead_Type_CC__c']);

const FIELD_LAYOUT = {
    Sales_Appointment_Booked_CC__c: ['left', 1],
    First_Sales_Appointment_Date_CC__c: ['left', 2],
    Product_Category_CC__c: ['left', 3],
    Core_Category_Min_Qty_CC__c: ['left', 4],
    Tender_Exculsive_Pricing_CC__c: ['left', 5],
    Company_Registration_No_CC__c: ['right', 1],
    Actual_Annual_Spend_CC__c: ['right', 2],
    Opportunity_Value_CC__c: ['right', 3],
    Bespoke_Over_20_Percent_CC__c: ['right', 4],
    Number_of_Locations_CC__c: ['right', 5],
    Entity_Associated_CC__c: ['right', 6],
    Re_Nurture_Reason_CC__c: ['left', 1],
    Reengagement_Date_CC__c: ['left', 2],
    Re_Nurture_Comments_CC__c: ['right', 1],
    Disqualified_Reason_CC__c: ['left', 1],
    Disqualification_Comments_CC__c: ['right', 1]
};

/** Text per target stage (Lead_Stage_CC__mdt record name). */
const STAGE_TEXT = {
    [STAGE_QUALIFIED]: {
        title: 'Move to Qualified',
        saveLabel: 'Move to Qualified',
        saveVariant: 'brand',
        intro: 'Complete the fields required to qualify this Lead.',
        note: 'Once saved, the Lead is Qualified and ready to convert.'
    },
    [STAGE_DISQUALIFIED]: {
        title: 'Disqualify Lead',
        saveLabel: 'Disqualify Lead',
        saveVariant: 'destructive',
        intro: 'Give the reason this Lead will not go forward.',
        note: 'After this the Lead is locked at Disqualified. Only an administrator can change its status.'
    },
    [STAGE_RE_NURTURE]: {
        title: 'Move to Re-Nurture',
        saveLabel: 'Move to Re-Nurture',
        saveVariant: 'brand',
        intro: 'Give the reason and the date to re-engage this Lead.',
        note: 'Ownership is reassigned under the existing Re-Nurture assignment rules, which may take a few moments to appear.'
    }
};

/**
 * Popup of the Record Meeting Outcome card (leadMeetingOutcome_CC).
 *
 * Shows the fields the Lead needs to enter the target stage, read from the Lead stage metadata by
 * LeadMeetingOutcomeController_CC: the stage's own requirements only (earlier stages are enforced by the Lead trigger on
 * save, not asked here). A requirement with a condition (for example comments when the reason is Other, or Number of
 * Locations when the Lead is an Entity) is shown, and required, only while its condition is met. A condition field asked
 * for in the popup (such as the reason) follows the user's edits; one that is not (Lead Type) is read from the Lead.
 *
 * Duplicates: the Lead trigger blocks a move into Qualified when the Lead matches another record, unless
 * Bypass_Duplicate_Rules_on_Qualification__c is ticked. For Qualified the popup checks for matches when it opens, lists
 * them with the bypass box, and turns a duplicate block on save into the same panel instead of a raw error.
 *
 * Save sets Status, the Meeting Outcome and its Sub Reason (when recorded at Engage) and every field changed here, in
 * one Lightning Data Service update, so the Lead trigger validates the whole move at once. Cancel writes nothing.
 * Closes with 'saved' after a successful save.
 */
export default class LeadMeetingOutcomeModal_CC extends LightningModal {
    @api recordId;
    /** Lead_Stage_CC__mdt record name: Qualified, Disqualified or Re_Nurture. */
    @api targetStage;
    /** Meeting Outcome and Sub Reason recorded on the card; both blank when disqualifying from Qualify. */
    @api meetingOutcome;
    @api subReason;
    @api companyName;

    form;
    values = {};
    changed = new Set();
    loading = true;
    saving = false;
    error;
    /** LeadMeetingOutcomeController_CC.DuplicateCheck, for Qualified only. */
    duplicates;
    /** The last save was blocked by the duplicate checkpoint. */
    duplicateBlocked = false;

    connectedCallback() {
        this.load();
    }

    async load() {
        try {
            const [form] = await Promise.all([
                getOutcomeForm({ leadId: this.recordId, targetStage: this.targetStage }),
                this.loadDuplicates()
            ]);
            this.form = form;
            this.values = { ...(this.form.values || {}) };
        } catch (e) {
            this.error = messageOf(e);
        } finally {
            this.loading = false;
        }
    }

    /** Looks for duplicates before the move to Qualified; a failed lookup only means no warning up front. */
    async loadDuplicates() {
        if (this.targetStage !== STAGE_QUALIFIED) {
            return;
        }
        try {
            this.duplicates = await getDuplicateCheck({ leadId: this.recordId });
        } catch (e) {
            this.duplicates = undefined;
        }
    }

    // ---------------------------------------------------------------- view

    get text() {
        return STAGE_TEXT[this.targetStage] || STAGE_TEXT[STAGE_DISQUALIFIED];
    }
    get title() {
        return this.text.title;
    }
    get saveLabel() {
        return this.text.saveLabel;
    }
    get saveVariant() {
        return this.text.saveVariant;
    }
    get intro() {
        return this.text.intro;
    }
    get note() {
        return this.text.note;
    }
    get hasOutcome() {
        return Boolean(this.meetingOutcome);
    }
    get ready() {
        return !this.loading && Boolean(this.form);
    }
    get saveDisabled() {
        return !this.ready || this.saving;
    }

    // ---------------------------------------------------------------- duplicates

    get duplicateMatches() {
        return (this.duplicates?.matches || []).map((match) => ({
            ...match,
            url: `/lightning/r/${match.recordId}/view`,
            label: `${match.name} (${match.objectLabel})`
        }));
    }
    get hasDuplicateMatches() {
        return this.duplicateMatches.length > 0;
    }
    get moreDuplicateMatches() {
        return Boolean(this.duplicates?.moreMatches);
    }
    get showDuplicatePanel() {
        return this.ready && (this.duplicateBlocked || this.hasDuplicateMatches);
    }
    get canBypassDuplicates() {
        return Boolean(this.duplicates?.canBypass);
    }
    get bypassTicked() {
        return BYPASS_DUPLICATES_FIELD in this.values
            ? this.values[BYPASS_DUPLICATES_FIELD] === true
            : Boolean(this.duplicates?.bypassed);
    }
    get duplicatePanelClass() {
        const theme = this.bypassTicked ? 'slds-theme_info' : 'slds-theme_warning';
        return `slds-box slds-box_x-small slds-var-m-bottom_small ${theme}`;
    }
    get duplicateHeading() {
        if (this.bypassTicked) {
            return 'Duplicate check will be bypassed';
        }
        return this.duplicateBlocked ? 'Not moved to Qualified: possible duplicate' : 'Possible duplicate found';
    }
    get duplicateMessage() {
        if (this.bypassTicked) {
            return 'The Lead will move to Qualified even though it matches the records below. Untick the box if it is a duplicate.';
        }
        const intro = this.hasDuplicateMatches
            ? 'This Lead matches the records below, so the move to Qualified will be blocked.'
            : 'This Lead matches an existing record you may not have access to, so the move to Qualified is blocked.';
        const next = this.canBypassDuplicates
            ? 'Review them and correct or merge the Lead, or, if it is not a duplicate, tick the box below and save again.'
            : 'Review them and correct or merge the Lead, or ask an administrator to confirm it is not a duplicate.';
        return `${intro} ${next}`;
    }

    /** Every field asked for in the popup, so a condition on one of them can follow the user's edits. */
    get formFieldNames() {
        const names = new Set();
        (this.form?.requirements || []).forEach((requirement) => requirement.fieldNames.forEach((name) => names.add(name)));
        return names;
    }

    get ownSections() {
        return this.sections();
    }
    get hasOwnSections() {
        return this.ownSections.length > 0;
    }
    get nothingToAsk() {
        return this.ready && !this.hasOwnSections;
    }
    get ownHeading() {
        return `Required for ${this.form?.targetStatus || ''}`;
    }

    /**
     * Sections to render, each split into the record page's two columns: one section for all single-field
     * requirements, plus one per group. Requirements whose condition is not met are hidden. A field listed by two
     * requirements is rendered once, under the first.
     * Single-field requirements are marked required while their condition is met; groups ("at least N of") are checked
     * on save instead, because no single field in them is required on its own.
     */
    sections() {
        // Only the target stage's own requirements are returned by the controller.
        const requirements = this.form?.requirements || [];
        const rendered = new Set();
        const sections = [];
        // Single-field requirements share one section, so their fields fill both columns like the record page.
        let singles;
        for (const requirement of requirements) {
            if (!this.conditionMet(requirement)) {
                continue;
            }
            const fields = requirement.fieldNames.filter((name) => !rendered.has(name) && !NOT_ASKED_FIELDS.has(name));
            fields.forEach((name) => rendered.add(name));
            if (!fields.length) {
                continue;
            }
            const active = this.conditionMet(requirement);
            const isGroup = requirement.fieldNames.length > 1;
            const items = fields.map((name) => ({
                key: `${requirement.key}-${name}`,
                name,
                required: active && !isGroup
            }));
            if (isGroup) {
                sections.push({
                    key: requirement.key,
                    isGroup,
                    heading: groupHeading(requirement.minimumRequired, requirement.fieldNames.length),
                    fields: items
                });
            } else if (singles) {
                singles.fields.push(...items);
            } else {
                singles = { key: 'fields-own', isGroup: false, heading: null, fields: items };
                sections.push(singles);
            }
        }
        return sections.map((section) => ({ ...section, ...toColumns(section.fields) }));
    }

    /** Mirrors LeadStageTransitionService_CC.isRequirementMet step 1, on the values in the popup. */
    conditionMet(requirement) {
        if (!requirement.conditionField) {
            return true;
        }
        return asText(this.values[requirement.conditionField]) === asText(requirement.conditionValue);
    }

    // ---------------------------------------------------------------- handlers

    handleChange(event) {
        const name = event.target.fieldName;
        this.values = { ...this.values, [name]: event.target.value };
        this.changed.add(name);
    }

    handleCancel() {
        this.close();
    }

    async handleSave() {
        const inputs = [...this.template.querySelectorAll('lightning-input-field')];
        const inputsValid = inputs.reduce((valid, input) => input.reportValidity() && valid, true);
        const problem = this.firstProblem();
        if (problem || !inputsValid) {
            this.error = problem || 'Complete the highlighted fields.';
            return;
        }

        const fields = { Id: this.recordId, Status: this.form.targetStatus };
        if (this.hasOutcome) {
            fields.Meeting_Outcome_CC__c = this.meetingOutcome;
            fields.Meeting_Outcome_Sub_Reason_CC__c = this.subReason;
        }
        inputs.forEach((input) => {
            if (this.changed.has(input.fieldName)) {
                fields[input.fieldName] = normalise(input.value);
            }
        });

        this.saving = true;
        this.disableClose = true;
        this.error = undefined;
        try {
            await updateRecord({ fields });
            this.disableClose = false;
            this.close('saved');
        } catch (e) {
            if (this.targetStage === STAGE_QUALIFIED && isDuplicateBlock(e, this.form.duplicateError)) {
                // Shown as the duplicate panel (matches and the bypass box) rather than a raw error.
                this.duplicateBlocked = true;
                await this.loadDuplicates();
                this.scrollToDuplicates();
            } else {
                this.error = messageOf(e);
            }
        } finally {
            this.saving = false;
            this.disableClose = false;
        }
    }

    scrollToDuplicates() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const panel = this.template.querySelector('[data-id="duplicates"]');
            if (panel) {
                panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        });
    }

    /**
     * Checks the browser cannot leave to the field inputs: groups ("at least N of"), whitespace-only text (the
     * trigger counts it as filled) and a Re-engagement Date in the past. Returns the first message, or undefined.
     */
    firstProblem() {
        const formFields = this.formFieldNames;
        for (const requirement of this.form.requirements) {
            if (!this.conditionMet(requirement)) {
                continue;
            }
            // Fields the user cannot read are not returned; the Lead trigger still checks those on save.
            const known = requirement.fieldNames.filter((name) => name in this.values);
            if (!known.length) {
                continue;
            }
            const filled = known.filter((name) => isFilled(this.values[name])).length;
            if (filled < requirement.minimumRequired) {
                return requirement.message || 'Complete the required fields.';
            }
        }
        const reengagement = this.values[REENGAGEMENT_DATE_FIELD];
        if (this.targetStage === STAGE_RE_NURTURE && formFields.has(REENGAGEMENT_DATE_FIELD) && reengagement
            && reengagement < today()) {
            return 'Choose today or a later date for the Re-engagement Date.';
        }
        return undefined;
    }
}

/**
 * Splits fields into the record page's two columns: fields placed in FIELD_LAYOUT keep their column and order; any
 * other field goes, in metadata order, to whichever column is shorter at that point.
 */
function toColumns(fields) {
    const placed = { left: [], right: [] };
    const unplaced = [];
    fields.forEach((field) => {
        const slot = FIELD_LAYOUT[field.name];
        if (slot) {
            placed[slot[0]].push({ field, order: slot[1] });
        } else {
            unplaced.push(field);
        }
    });
    const byOrder = (a, b) => a.order - b.order;
    const leftFields = placed.left.sort(byOrder).map((item) => item.field);
    const rightFields = placed.right.sort(byOrder).map((item) => item.field);
    unplaced.forEach((field) => (leftFields.length <= rightFields.length ? leftFields : rightFields).push(field));
    return { leftFields, rightFields };
}

function groupHeading(minimum, total) {
    return minimum >= total ? 'Complete all of these' : `Complete at least ${minimum} of these`;
}

function asText(value) {
    return value === null || value === undefined ? '' : String(value);
}

function isFilled(value) {
    return asText(value).trim() !== '';
}

function normalise(value) {
    if (typeof value === 'string') {
        const trimmed = value.trim();
        return trimmed === '' ? null : trimmed;
    }
    return value === undefined ? null : value;
}

function today() {
    const now = new Date();
    const pad = (value) => String(value).padStart(2, '0');
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

/**
 * True when a save failed on duplicates: the Lead trigger's checkpoint message (from the controller, so the text is
 * not repeated here) or a standard duplicate rule set to Block (DUPLICATES_DETECTED).
 */
export function isDuplicateBlock(error, duplicateMessage) {
    const errors = error?.body?.output?.errors || [];
    if (errors.some((item) => item.errorCode === 'DUPLICATES_DETECTED' || item.duplicateRecordError)) {
        return true;
    }
    return Boolean(duplicateMessage) && messageOf(error).includes(duplicateMessage);
}

/** Flattens LDS / UI API / Apex errors (record errors, field errors, trigger addError messages) into one line. */
export function messageOf(error) {
    const messages = [];
    const body = error?.body;
    (body?.output?.errors || []).forEach((item) => messages.push(item.message));
    Object.values(body?.output?.fieldErrors || {}).forEach((list) =>
        (list || []).forEach((item) => messages.push(item.message))
    );
    if (!messages.length && Array.isArray(body)) {
        body.forEach((item) => messages.push(item.message));
    }
    if (!messages.length && body?.message) {
        messages.push(body.message);
    }
    if (!messages.length && error?.message) {
        messages.push(error.message);
    }
    const unique = [...new Set(messages.filter(Boolean))];
    return unique.length ? unique.join(' ') : 'The Lead could not be saved.';
}