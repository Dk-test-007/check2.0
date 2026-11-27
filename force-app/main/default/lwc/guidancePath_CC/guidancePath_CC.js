import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';
import getGuidanceData from '@salesforce/apex/GuidancePathController_CC.getGuidanceData';

const CHANNEL_NAME = '/event/Guidance_Refresh_CC__e';
const DEFAULT_ERROR = 'Guidance could not be loaded. Check access or contact your Salesforce administrator.';

export default class GuidancePath_CC extends LightningElement {
    _recordId;
    initializedRecordId;
    objectApiName;
    isConfigured = false;
    guidanceSectionsData;
    guidanceRequestId = 0;
    subscription;
    subscriptionPromise;
    subscriptionAttemptId = 0;
    errorListenerRegistered = false;
    subscriptionErrorShown = false;
    guidanceLoadError;
    isGuidanceRefreshing = false;
    activeSectionName = ['guidance'];

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        if (value === this._recordId) return;
        this._recordId = value;
        this.initializedRecordId = undefined;
        this.guidanceRequestId += 1;
        this.objectApiName = undefined;
        this.isConfigured = false;
        this.guidanceSectionsData = undefined;
        this.guidanceLoadError = undefined;
        this.isGuidanceRefreshing = false;
        this.activeSectionName = ['guidance'];
        this.startInitialization();
    }

    connectedCallback() {
        if (!this.errorListenerRegistered) {
            onError((error) => console.warn('Guidance Platform Event streaming error:', error));
            this.errorListenerRegistered = true;
        }
        this.startInitialization();
    }

    disconnectedCallback() {
        this.initializedRecordId = undefined;
        this.guidanceRequestId += 1;
        this.isGuidanceRefreshing = false;
        void this.stopSubscription();
    }

    get isLoading() {
        return Boolean(this.recordId) && !this.hasError && this.guidanceSectionsData === undefined;
    }

    get isRefreshing() {
        return this.isGuidanceRefreshing && this.guidanceSectionsData !== undefined;
    }

    get guidanceSections() {
        return [...(this.guidanceSectionsData || [])].sort(
            (first, second) => (first.orderNumber || 0) - (second.orderNumber || 0)
        );
    }

    get hasGuidance() {
        return this.guidanceSections.length > 0;
    }

    get showGuidance() {
        return this.isConfigured && !this.isLoading && !this.hasError && this.hasGuidance;
    }

    get hasError() {
        return Boolean(this.guidanceLoadError);
    }

    get errorMessage() {
        return this.guidanceLoadError || '';
    }

    handleSectionToggle(event) {
        this.activeSectionName = event.detail.openSections;
    }

    startInitialization() {
        const recordId = this.recordId;
        if (!recordId || !this.isConnected || this.initializedRecordId === recordId) return;
        this.initializedRecordId = recordId;
        void this.initializeGuidance(recordId);
    }

    async initializeGuidance(recordId) {
        await this.ensureSubscription();
        if (!this.isConnected || recordId !== this.recordId) return;
        await this.loadGuidance(recordId);
    }

    async ensureSubscription() {
        if (this.subscription) return;
        if (this.subscriptionPromise) {
            await this.subscriptionPromise;
            return;
        }

        const attemptId = ++this.subscriptionAttemptId;
        const operation = (async () => {
            try {
                if (!(await isEmpEnabled())) {
                    throw new Error('Platform Event streaming is unavailable in this browser context.');
                }

                const newSubscription = await subscribe(
                    CHANNEL_NAME,
                    -1,
                    (message) => this.handlePlatformEvent(message)
                );

                if (!this.isConnected || attemptId !== this.subscriptionAttemptId) {
                    await unsubscribe(newSubscription, () => {});
                    return;
                }

                this.subscription = newSubscription;
                this.subscriptionErrorShown = false;
            } catch (error) {
                if (attemptId === this.subscriptionAttemptId && !this.subscriptionErrorShown) {
                    this.subscriptionErrorShown = true;
                    this.showToast(
                        'Live guidance updates unavailable',
                        'Check the Platform Event configuration and subscriber permissions. Guidance can still be loaded when the page is refreshed.',
                        'warning'
                    );
                    console.error('Unable to subscribe to Guidance Refresh:', error);
                }
            } finally {
                if (attemptId === this.subscriptionAttemptId) this.subscriptionPromise = undefined;
            }
        })();

        this.subscriptionPromise = operation;
        await operation;
    }

    async stopSubscription() {
        this.subscriptionAttemptId += 1;
        this.subscriptionPromise = undefined;
        const currentSubscription = this.subscription;
        this.subscription = undefined;

        if (!currentSubscription) return;
        try {
            await unsubscribe(currentSubscription, () => {});
        } catch (error) {
            console.warn('Unable to unsubscribe from Guidance Refresh:', error);
        }
    }

    handlePlatformEvent(message) {
        if (!this.isConnected || !this.recordId) return;
        const payload = message?.data?.payload;
        const eventRecordId = payload?.Record_ID_CC__c;
        const eventObjectApiName = payload?.Object_API_Name_CC__c;
        if (!eventRecordId) return;

        if (
            eventObjectApiName && this.objectApiName &&
            eventObjectApiName.toLowerCase() !== this.objectApiName.toLowerCase()
        ) return;

        if (this.normalizeRecordId(eventRecordId) !== this.normalizeRecordId(this.recordId)) return;
        void this.loadGuidance(this.recordId);
    }

    normalizeRecordId(recordId) {
        return recordId ? String(recordId).substring(0, 15) : '';
    }

    async loadGuidance(recordId) {
        if (!recordId || !this.isConnected) return;
        const requestId = ++this.guidanceRequestId;
        const hasExistingData = this.guidanceSectionsData !== undefined;
        this.isGuidanceRefreshing = hasExistingData;
        this.guidanceLoadError = undefined;

        try {
            const response = await getGuidanceData({ recordId });
            if (requestId !== this.guidanceRequestId || recordId !== this.recordId) return;
            this.objectApiName = response?.objectApiName;
            this.isConfigured = Boolean(response?.isConfigured);
            this.guidanceSectionsData = response?.sections || [];
            if (!this.isConfigured) void this.stopSubscription();
        } catch (error) {
            if (requestId === this.guidanceRequestId) {
                this.guidanceLoadError = error?.body?.message || error?.message || DEFAULT_ERROR;
            }
        } finally {
            if (requestId === this.guidanceRequestId) {
                this.isGuidanceRefreshing = false;
            }
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}